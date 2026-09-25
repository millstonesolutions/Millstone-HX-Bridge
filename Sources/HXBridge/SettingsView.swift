import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var app: AppController
    @StateObject private var macSendGroup = Box<String>("")
    @StateObject private var currentMacSendGroup = Box<String>(NDIConfigFile.sendGroups)
    @StateObject private var message = Box<String>("")

    var body: some View {
        Form {
            Section("Source discovery") {
                TextField("Input group(s)", text: $app.settings.inputGroups, prompt: Text("public"))
                Text("Comma-separated NDI groups searched for input sources, e.g. \"propres-local\". Found now: \(app.finder.sources.count) source(s).")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Apply & Rescan") { app.restartFinder() }
                }
            }

            Section("Keep ProPresenter's High Bandwidth feed off the network") {
                LabeledContent("This Mac's default send group", value: currentMacSendGroup.value)
                TextField("New send group", text: $macSendGroup.value, prompt: Text("propres-local"))
                Text("Moves every NDI sender on this Mac that uses the default group (ProPresenter, Scan Converter, Test Patterns…) into this group so other computers don't see it. The bridge's HX outputs are unaffected because they set their own groups. Restart ProPresenter afterwards, then add the same group to Input group(s) above. A backup of the config file is kept.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open NDI Access Manager") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/NDI Access Manager.app"))
                    }
                    Spacer()
                    Button("Reset to public") { applyMacGroup("public") }
                    Button("Apply") { applyMacGroup(macSendGroup.value.isEmpty ? "propres-local" : macSendGroup.value) }
                }
                if !message.value.isEmpty { Text(message.value).font(.caption).foregroundStyle(.orange) }
            }

            Section("NDI Advanced SDK license") {
                TextField("Company / vendor name", text: $app.settings.vendorName)
                TextField("License ID (formerly Vendor ID)", text: $app.settings.vendorID, prompt: Text("00000000-0000-0000-0000-000000000000"))
                Text("NDI issues a License ID for using the Advanced SDK beyond the trial. Leave blank while testing. Restart bridges after changing.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Start bridges when the app launches", isOn: $app.settings.startBridgesOnLaunch)
                Toggle("Open at login", isOn: Binding(get: { app.launchAtLogin }, set: { app.launchAtLogin = $0 }))
                Text("Works best when the app is in /Applications (run ./build.sh --install).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("NDI runtime", value: NDIRuntime.version)
                HStack {
                    Button("Reveal Config File") { NSWorkspace.shared.activateFileViewerSelecting([AppSettings.fileURL]) }
                    Button("Reveal Log File") { NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL]) }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func applyMacGroup(_ g: String) {
        do {
            try NDIConfigFile.setSendGroups(g)
            currentMacSendGroup.value = NDIConfigFile.sendGroups
            message.value = "Saved. Restart ProPresenter so it picks up the new group."
        } catch {
            message.value = "Could not write \(NDIConfigFile.url.path): \(error.localizedDescription)"
        }
    }
}
