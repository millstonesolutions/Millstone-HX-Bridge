import SwiftUI
import AppKit

struct LogView: View {
    @EnvironmentObject var log: Log
    @StateObject private var filter = Box<String>("")
    @StateObject private var follow = Box<Bool>(true)

    private var visible: [LogLine] {
        filter.value.isEmpty ? log.lines : log.lines.filter { $0.text.localizedCaseInsensitiveContains(filter.value) || $0.level == filter.value.uppercased() }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $filter.value).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Toggle("Follow", isOn: $follow.value)
                Spacer()
                Button("Copy") {
                    let text = visible.map { "\(Self.fmt.string(from: $0.date)) \($0.level) \($0.text)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Clear") { log.clear() }
                Button("Reveal File") { NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL]) }
            }
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                List(visible) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Self.fmt.string(from: line.date)).foregroundStyle(.secondary)
                        Text(line.level).foregroundStyle(color(line.level)).frame(width: 44, alignment: .leading)
                        Text(line.text).textSelection(.enabled)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .id(line.id)
                }
                .onChange(of: log.lines.count) { _ in
                    if follow.value, let last = visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "ERROR": return .red
        case "WARN": return .orange
        case "SDK": return .purple
        default: return .secondary
        }
    }

    static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
