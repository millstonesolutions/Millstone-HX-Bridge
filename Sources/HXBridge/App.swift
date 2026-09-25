import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--opus-selftest") {
            Thread {
                OpusSelfTest.run()
                DispatchQueue.main.async { exit(0) }
            }.start()
            return
        }
        Log.shared.captureStandardOutput()
        AppController.shared.launch()
    }
    // Keep bridging when the window is closed; the menu bar item stays available.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        AppController.shared.shutdown()
    }
}

@main
struct HXBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppController.shared
    @StateObject private var log = Log.shared

    var body: some Scene {
        Window("Millstone Solutions HX Bridge", id: "main") {
            ContentView()
                .environmentObject(app)
                .environmentObject(log)
                .frame(minWidth: 860, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .windowArrangement) {
                OpenWindowButton(id: "log", title: "Show Log").keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        Window("HX Bridge Log", id: "log") {
            LogView().environmentObject(log).frame(minWidth: 700, minHeight: 400)
        }

        Settings {
            SettingsView().environmentObject(app).frame(width: 560)
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(app)
        } label: {
            Image(systemName: app.anyRunning ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
        }
    }
}

struct OpenWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    let id: String
    let title: String
    var body: some View {
        Button(title) {
            openWindow(id: id)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var app: AppController
    var body: some View {
        ForEach(app.settings.bridges) { b in
            let s = app.stats(for: b.id)
            Text("\(b.outputName): \(s.state.rawValue)\(s.receivers > 0 ? " · \(s.receivers) rx" : "")")
        }
        Divider()
        Button("Start All") { app.startAll() }
        Button("Stop All") { app.stopAll() }
        Divider()
        OpenWindowButton(id: "main", title: "Open HX Bridge…")
        OpenWindowButton(id: "log", title: "Show Log…")
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct OpenSettingsButton: View {
    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink { Label("Settings", systemImage: "gear") }
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            } label: { Label("Settings", systemImage: "gear") }
        }
    }
}
