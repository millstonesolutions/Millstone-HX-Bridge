import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppController
    @StateObject private var selection = Box<UUID?>(nil)

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.value) {
                Section("Bridges") {
                    ForEach(app.settings.bridges) { b in
                        BridgeRow(config: b, stats: app.stats(for: b.id), running: app.isRunning(b.id)).tag(b.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 250)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button { selection.value = app.addBridge() } label: { Label("Add Bridge", systemImage: "plus") }
                        Spacer()
                    }
                    HStack {
                        Button("Start All") { app.startAll() }
                        Button("Stop All") { app.stopAll() }
                    }
                    Text("NDI \(NDIRuntime.version)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(10)
            }
        } detail: {
            if let id = selection.value, let idx = app.settings.bridges.firstIndex(where: { $0.id == id }) {
                BridgeDetailView(config: $app.settings.bridges[idx], onDelete: {
                    selection.value = nil
                    app.deleteBridge(id)
                    selection.value = app.settings.bridges.first?.id
                })
                .id(id)
            } else {
                Text("Add a bridge to get started").foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItem {
                OpenWindowButton(id: "log", title: "Log")
            }
            ToolbarItem {
                OpenSettingsButton()
            }
        }
        .onAppear { if selection.value == nil { selection.value = app.settings.bridges.first?.id } }
    }
}

struct StatusDot: View {
    let state: BridgeState
    var color: Color {
        switch state {
        case .running: return .green
        case .idle: return .mint
        case .waitingForSource, .noVideo: return .orange
        case .error: return .red
        case .stopped: return .gray
        }
    }
    var body: some View { Circle().fill(color).frame(width: 9, height: 9) }
}

struct BridgeRow: View {
    let config: BridgeConfig
    let stats: BridgeStats
    let running: Bool
    var body: some View {
        HStack(spacing: 8) {
            StatusDot(state: stats.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.outputName).fontWeight(.medium)
                Text(running ? stats.state.rawValue : (config.sourceName.isEmpty ? "No source" : config.sourceName))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if stats.onProgram { Text("PGM").font(.caption2.bold()).padding(3).background(.red.opacity(0.8)).cornerRadius(3) }
            else if stats.onPreview { Text("PVW").font(.caption2.bold()).padding(3).background(.green.opacity(0.7)).cornerRadius(3) }
        }
        .padding(.vertical, 2)
    }
}
