import SwiftUI

struct BridgeDetailView: View {
    @EnvironmentObject var app: AppController
    @Binding var config: BridgeConfig
    var onDelete: () -> Void
    @StateObject private var confirmDelete = Box<Bool>(false)

    private var stats: BridgeStats { app.stats(for: config.id) }
    private var running: Bool { app.isRunning(config.id) }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    StatusDot(state: stats.state).scaleEffect(1.5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(running ? stats.state.rawValue : "Stopped").font(.headline)
                        if !stats.message.isEmpty {
                            Text(stats.message).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if running && app.hasUnappliedChanges(config.id) {
                        Button("Apply Changes") { app.restart(config.id) }
                    }
                    if running {
                        Button("Stop") { app.stop(config.id) }.controlSize(.large)
                    } else {
                        Button("Start") { app.start(config.id) }
                            .controlSize(.large).keyboardShortcut(.defaultAction)
                            .disabled(config.sourceName.isEmpty)
                    }
                }
                if running { StatsGrid(stats: stats) }
            }

            LicenseBanner(stats: stats, running: running)

            Section("Input (High Bandwidth NDI)") {
                SourcePicker(finder: app.finder, selection: $config.sourceName, excluding: config.outputName)
                Text("Searching NDI group(s): \(app.finderGroupsInUse). Change this in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Output (NDI HX)") {
                TextField("Output name", text: $config.outputName)
                TextField("Output group(s)", text: $config.outputGroups, prompt: Text("public"))
                Picker("Codec", selection: $config.codec) {
                    ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                Picker("Preset", selection: $config.preset) {
                    ForEach(HXPreset.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                .onChange(of: config.preset) { p in config.keyframeIntervalSec = p.defaultKeyframeSeconds }
                if config.preset == .custom {
                    HStack {
                        Slider(value: $config.customBitrateMbps, in: 2...100, step: 1) { Text("Bit-rate") }
                        Text("\(Int(config.customBitrateMbps)) Mbps").monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                } else {
                    LabeledContent("Bit-rate") {
                        Text(config.preset == .hx3
                             ? "2.0× NDI's recommended HX rate for the input format"
                             : "1.0× NDI's recommended HX rate for the input format")
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $config.keyframeIntervalSec, in: 0.5...4, step: 0.5) {
                    LabeledContent("Keyframe interval", value: String(format: "%.1f s", config.keyframeIntervalSec))
                }
                Toggle("Send 640-wide preview stream (for multiviewers)", isOn: $config.sendPreviewStream)
                Toggle("Pause encoding when nobody is receiving", isOn: $config.skipEncodeWithoutReceivers)
            }

            Section("Audio") {
                Picker("Audio", selection: $config.audioMode) {
                    ForEach(AudioMode.allCases) { Text($0.label).tag($0) }
                }
                if config.audioMode == .opus {
                    Picker("Opus bit-rate per channel", selection: $config.opusKbpsPerChannel) {
                        ForEach([48, 64, 96, 128, 160], id: \.self) { Text("\($0) kbps").tag($0) }
                    }
                    Text("Each channel is kept separate. 8 channels at 96 kbps ≈ 0.8 Mbps. Receivers need NDI 5 or newer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if config.audioMode == .aac {
                    Picker("AAC bit-rate", selection: $config.aacBitrateKbps) {
                        ForEach([128, 160, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                    }
                }
            }

            Section("Compatibility") {
                Toggle("Low-latency encoder mode", isOn: $config.lowLatencyEncoder)
                Toggle("Repeat SPS/PPS inside every keyframe", isOn: $config.inlineParameterSets)
                Text("Try changing these if a receiver on another computer shows the source but no picture.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Options") {
                Toggle("Forward tally from HX receivers back to the source", isOn: $config.forwardTally)
                Toggle("Start this bridge when the app launches", isOn: $config.autoStart)
                HStack {
                    Spacer()
                    Button("Delete Bridge…", role: .destructive) { confirmDelete.value = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(config.outputName)
        .confirmationDialog("Delete \"\(config.outputName)\"?", isPresented: $confirmDelete.value) {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

struct SourcePicker: View {
    @ObservedObject var finder: SourceFinder
    @Binding var selection: String
    var excluding: String

    var body: some View {
        let names = finder.sources.map(\.name).filter { !$0.hasSuffix("(\(excluding))") }
        Picker("Source", selection: $selection) {
            Text("Choose a source…").tag("")
            ForEach(names, id: \.self) { Text($0).tag($0) }
            if !selection.isEmpty && !names.contains(selection) {
                Text("\(selection) (not found right now)").tag(selection)
            }
        }
        if finder.sources.isEmpty {
            Text("No NDI sources found yet. Make sure ProPresenter's NDI output is on and in a group listed in Settings.")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

struct LicenseBanner: View {
    @EnvironmentObject var app: AppController
    let stats: BridgeStats
    let running: Bool

    var body: some View {
        if let notice = app.licenseNotice {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("NDI reported a licensing problem", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.headline)
                    Text("At \(notice.date.formatted(date: .omitted, time: .standard))\(elapsedText(at: notice.date)): \"\(notice.text)\"")
                        .font(.callout).textSelection(.enabled)
                    Text("HX output needs the NDI Advanced SDK; there is no free HX setting. Enter your NDI License ID in Settings, or send ProPresenter's own High Bandwidth NDI instead.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack { Spacer(); OpenSettingsButton(); Button("Dismiss") { app.clearLicenseNotice() } }
                }
            }
        } else if !app.hasLicenseID {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Trial mode — no NDI License ID set", systemImage: "info.circle")
                        .font(.subheadline.weight(.semibold))
                    Text("NDI documents one trial limit: HDR streams stop after 30 minutes. This bridge sends SDR, so that limit shouldn't apply. If NDI stops the stream for any licensing reason, a warning will appear here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func elapsedText(at date: Date) -> String {
        guard let start = stats.startedAt, date > start else { return "" }
        return " (after \(formatDuration(date.timeIntervalSince(start))) of sending)"
    }
}

func formatDuration(_ t: TimeInterval) -> String {
    let s = Int(t)
    return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}

struct StatsGrid: View {
    let stats: BridgeStats
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            if let start = stats.startedAt {
                GridRow {
                    Text("Running for").foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(formatDuration(ctx.date.timeIntervalSince(start))).monospacedDigit()
                    }
                }
            }
            row("Input", stats.inputDescription + String(format: "  (%.1f fps received)", stats.inputFPS))
            row("Encoder", stats.encoderInfo.isEmpty ? "—" : stats.encoderInfo)
            row("Output", String(format: "%.1f Mbps", stats.outputMbps)
                + (stats.previewMbps > 0 ? String(format: " + %.2f Mbps preview", stats.previewMbps) : ""))
            row("Receivers", "\(stats.receivers)")
            row("Frames / keyframes", "\(stats.framesEncoded) / \(stats.keyframes)")
            row("Dropped input frames", "\(stats.droppedInput)")
            row("Audio", stats.audioInfo.isEmpty ? "—" : stats.audioInfo)
            row("Tally", stats.onProgram ? "Program" : (stats.onPreview ? "Preview" : "—"))
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    @ViewBuilder private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).monospacedDigit()
        }
    }
}
