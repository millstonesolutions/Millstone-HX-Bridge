import Foundation
import Combine

struct LogLine: Identifiable {
    let id = UUID()
    let date: Date
    let level: String
    let text: String
}

/// App log. Also captures stdout/stderr because the NDI SDK prints stream-validation errors there.
final class Log: ObservableObject {
    static let shared = Log()
    @Published private(set) var lines: [LogLine] = []
    private let queue = DispatchQueue(label: "log")
    private var fileHandle: FileHandle?
    private var pipe: Pipe?
    private var originalStdout: Int32 = -1
    private var partialLine = ""

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("MillstoneHXBridge.log")
    }

    private init() {
        let url = Log.fileURL
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 5_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
    }

    static func info(_ s: String) { shared.add("INFO", s) }
    static func warn(_ s: String) { shared.add("WARN", s) }
    static func error(_ s: String) { shared.add("ERROR", s) }

    private static let licensePattern = try! NSRegularExpression(
        pattern: "licen[cs]|trial|expir|vendor|evaluation|time.?limit", options: [.caseInsensitive])

    func add(_ level: String, _ text: String) {
        let line = LogLine(date: Date(), level: level, text: text)
        if level == "SDK", Log.licensePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            DispatchQueue.main.async { AppController.shared.noteLicenseMessage(text) }
        }
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: line.date)
            self.fileHandle?.write(Data("\(stamp) \(level) \(text)\n".utf8))
        }
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > 3000 { self.lines.removeFirst(self.lines.count - 3000) }
        }
    }

    func clear() { lines.removeAll() }

    private func consume(_ data: Data) {
        partialLine += String(decoding: data, as: UTF8.self)
        while let nl = partialLine.firstIndex(of: "\n") {
            let line = String(partialLine[..<nl]).trimmingCharacters(in: .whitespaces)
            partialLine = String(partialLine[partialLine.index(after: nl)...])
            if !line.isEmpty { add("SDK", line) }
        }
    }

    /// Redirect stdout + stderr into the log (still echoed to the original stdout).
    func captureStandardOutput() {
        guard pipe == nil else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        let p = Pipe()
        pipe = p
        originalStdout = dup(STDOUT_FILENO)
        dup2(p.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(p.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        let echo = originalStdout
        p.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let self = self else { return }
            if echo >= 0 { data.withUnsafeBytes { _ = write(echo, $0.baseAddress, data.count) } }
            self.consume(data)
        }
    }
}
