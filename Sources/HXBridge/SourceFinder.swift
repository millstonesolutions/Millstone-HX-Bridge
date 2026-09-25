import Foundation
import CNDI

struct NDISource: Hashable, Identifiable {
    let name: String
    let url: String
    var id: String { name }
}

/// Background NDI discovery for the configured input groups.
final class SourceFinder: ObservableObject {
    @Published private(set) var sources: [NDISource] = []
    private let lock = NSLock()
    private var snapshot: [String: String] = [:]
    private var thread: Thread?
    private var generation = 0

    func restart(groups: String, configJSON: String) {
        lock.lock(); generation += 1; let gen = generation; lock.unlock()
        let t = Thread { [weak self] in self?.loop(gen: gen, groups: groups, configJSON: configJSON) }
        t.name = "ndi finder"
        t.start()
        thread = t
    }

    func stop() { lock.lock(); generation += 1; lock.unlock() }

    func url(for name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return snapshot[name]
    }

    private func current(_ gen: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return gen == generation }

    private func loop(gen: Int, groups: String, configJSON: String) {
        guard NDIRuntime.initialize() else { Log.error("NDI failed to initialize"); return }
        let box = CStringBox()
        var fc = NDIlib_find_create_t()
        fc.show_local_sources = true
        fc.p_groups = box.make(groups)
        fc.p_extra_ips = nil
        guard let finder = NDIlib_find_create_v3(&fc, configJSON) else { Log.error("Could not create NDI finder"); return }
        defer { NDIlib_find_destroy(finder) }
        Log.info("Searching for NDI sources in group(s) \"\(groups)\"")
        var first = true
        while current(gen) {
            if NDIlib_find_wait_for_sources(finder, 1000) || first {
                first = false
                var count: UInt32 = 0
                var list: [NDISource] = []
                if let p = NDIlib_find_get_current_sources(finder, &count) {
                    for i in 0..<Int(count) {
                        let s = p[i]
                        guard let n = s.p_ndi_name else { continue }
                        let u = s.p_url_address.map { String(cString: $0) } ?? ""
                        list.append(NDISource(name: String(cString: n), url: u))
                    }
                }
                list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                lock.lock()
                snapshot = Dictionary(list.map { ($0.name, $0.url) }, uniquingKeysWith: { a, _ in a })
                lock.unlock()
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.current(gen) else { return }
                    if self.sources != list { self.sources = list }
                }
            }
        }
    }
}
