import Foundation

/// What the app has done, kept on disk.
///
/// The log used to live only in memory, so an app left running silently had
/// nothing to show for itself when opened later — and one restarted by the
/// login item had forgotten everything before. Every line is appended here as
/// it happens and read back at launch, so what ran while nobody was looking
/// is still there to be looked at.
final class RunJournal: @unchecked Sendable {
    static let shared = RunJournal()

    private let lock = NSLock()
    private let file: URL
    /// Enough for weeks of daily runs; trimmed at launch rather than per line.
    private let keep = 3000

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "IPSW Sync", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        file = support.appending(path: "journal.jsonl")
    }

    private struct Line: Codable {
        let at: Date
        let kind: String
        let message: String
    }

    func append(_ entry: LogEntry) {
        let line = Line(at: entry.at, kind: entry.kind.name, message: entry.message)
        guard var data = try? JSONEncoder().encode(line) else { return }
        data.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }

    /// The most recent lines, oldest first, and the file trimmed to size.
    func recent(_ count: Int) -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if lines.count > keep {
            lines = Array(lines.suffix(keep))
            try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
        let decoder = JSONDecoder()
        return lines.suffix(count).compactMap { raw in
            guard let line = try? decoder.decode(Line.self, from: Data(raw.utf8)) else { return nil }
            return LogEntry(kind: LogEntry.Kind(name: line.kind), message: line.message, at: line.at)
        }
    }
}

extension LogEntry.Kind {
    var name: String {
        switch self {
        case .info: "info"
        case .good: "good"
        case .warning: "warning"
        case .bad: "bad"
        }
    }

    init(name: String) {
        switch name {
        case "good": self = .good
        case "warning": self = .warning
        case "bad": self = .bad
        default: self = .info
        }
    }
}
