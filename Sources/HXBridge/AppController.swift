import Foundation
import SwiftUI
import ServiceManagement

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    @Published var settings: AppSettings { didSet { if settings != oldValue { settings.save() } } }
    @Published private(set) var stats: [UUID: BridgeStats] = [:]
    /// Config each running bridge was started with (to detect unapplied edits).
    @Published private(set) var runningConfigs: [UUID: BridgeConfig] = [:]
    let finder = SourceFinder()
    /// Set when the NDI library prints something about licensing / trial limits.
    @Published private(set) var licenseNotice: (date: Date, text: String)?
    var hasLicenseID: Bool { !settings.vendorID.trimmingCharacters(in: .whitespaces).isEmpty }

    func noteLicenseMessage(_ text: String) {
        licenseNotice = (Date(), text)
        Log.warn("NDI reported a licensing message: \(text)")
    }
    func clearLicenseNotice() { licenseNotice = nil }

    private var engines: [UUID: BridgeEngine] = [:]
    private var tokens: [UUID: UUID] = [:]
    private var wantRunning: Set<UUID> = []
    private let lifecycle = DispatchQueue(label: "bridge lifecycle")
    private var finderGroups = ""

    private init() {
        settings = AppSettings.load()
    }

    func launch() {
        Log.info("Millstone Solutions HX Bridge starting — NDI \(NDIRuntime.initialize() ? NDIRuntime.version : "failed to initialize")")
        restartFinder()
        if settings.startBridgesOnLaunch {
            for b in settings.bridges where b.autoStart && !b.sourceName.isEmpty { start(b.id) }
        }
    }

    func restartFinder() {
        finderGroups = settings.inputGroups
        finder.restart(groups: settings.inputGroups, configJSON: settings.ndiConfigJSON(recvGroups: settings.inputGroups))
    }

    var finderGroupsInUse: String { finderGroups }
    var anyRunning: Bool { !engines.isEmpty }
    func isRunning(_ id: UUID) -> Bool { engines[id] != nil }
    func stats(for id: UUID) -> BridgeStats { stats[id] ?? BridgeStats() }
    func hasUnappliedChanges(_ id: UUID) -> Bool {
        guard let running = runningConfigs[id], let current = settings.bridges.first(where: { $0.id == id }) else { return false }
        return running != current
    }

    func start(_ id: UUID) {
        guard let cfg = settings.bridges.first(where: { $0.id == id }) else { return }
        let old = engines[id]
        let finder = self.finder
        let token = UUID()
        tokens[id] = token
        let engine = BridgeEngine(
            config: cfg, settings: settings,
            resolveURL: { name in finder.url(for: name) },
            onStats: { s in
                Task { @MainActor in AppController.shared.received(s, for: id, token: token) }
            })
        engines[id] = engine
        runningConfigs[id] = cfg
        wantRunning.insert(id)
        lifecycle.async {
            old?.stop()
            engine.start()
        }
    }

    func stop(_ id: UUID) {
        wantRunning.remove(id)
        let e = engines.removeValue(forKey: id)
        tokens[id] = nil
        runningConfigs[id] = nil
        stats[id] = BridgeStats()
        lifecycle.async { e?.stop() }
    }

    func restart(_ id: UUID) { start(id) }
    func startAll() { for b in settings.bridges where !b.sourceName.isEmpty { start(b.id) } }
    func stopAll() { for id in Array(engines.keys) { stop(id) } }

    /// Synchronous shutdown for app termination.
    func shutdown() {
        let all = Array(engines.values)
        engines.removeAll()
        wantRunning.removeAll()
        lifecycle.sync { all.forEach { $0.stop() } }
    }

    private func received(_ s: BridgeStats, for id: UUID, token: UUID) {
        guard engines[id] != nil, tokens[id] == token else { return }
        stats[id] = s
        // Unattended use: retry failed bridges after a short delay.
        if s.state == .error, wantRunning.contains(id) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let app = AppController.shared
                guard app.wantRunning.contains(id), app.stats[id]?.state == .error else { return }
                Log.info("Retrying bridge after error")
                app.start(id)
            }
        }
    }

    func addBridge() -> UUID {
        var b = BridgeConfig()
        b.outputName = "HX Bridge \(settings.bridges.count + 1)"
        b.sourceName = ""
        settings.bridges.append(b)
        return b.id
    }

    func deleteBridge(_ id: UUID) {
        stop(id)
        settings.bridges.removeAll { $0.id == id }
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { Log.error("Launch at login: \(error.localizedDescription)") }
            objectWillChange.send()
        }
    }
}

/// Reads/writes this Mac's NDI config file (~/.ndi/ndi-config.v1.json) — used to move ProPresenter
/// (and other local NDI senders) into a private group.
enum NDIConfigFile {
    static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ndi/ndi-config.v1.json") }

    static func read() -> [String: Any] {
        guard let d = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    static var sendGroups: String {
        let ndi = read()["ndi"] as? [String: Any]
        let groups = ndi?["groups"] as? [String: Any]
        return (groups?["send"] as? String) ?? "public (default)"
    }

    static func setSendGroups(_ value: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            try? fm.copyItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent("ndi-config.v1.json.bak-\(stamp)"))
        }
        var root = read()
        var ndi = root["ndi"] as? [String: Any] ?? [:]
        var groups = ndi["groups"] as? [String: Any] ?? [:]
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.lowercased() == "public" { groups.removeValue(forKey: "send") } else { groups["send"] = trimmed }
        if groups.isEmpty { ndi.removeValue(forKey: "groups") } else { ndi["groups"] = groups }
        root["ndi"] = ndi
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        Log.info("Set this Mac's default NDI send group to \"\(trimmed.isEmpty ? "public" : trimmed)\" in \(url.path)")
    }
}
