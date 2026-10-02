import Foundation
import os

/// Persistent, line-oriented diagnostics. Each event is written immediately so
/// a crash or a silent scheduled run still leaves evidence for the next fix.
final class RunJournal: @unchecked Sendable {
    static let shared = RunJournal()

    private let lock = NSLock()
    private let file: URL
    private let logger = Logger(subsystem: "com.github.4ge6n.IPSWSync", category: "journal")
    private let maxBytes = 10 * 1024 * 1024
    private let retainedBytes = 6 * 1024 * 1024

    private convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "IPSW Sync", directoryHint: .isDirectory)
        self.init(file: support.appending(path: "journal.jsonl"))
    }

    /// An explicit destination makes persistence and rotation testable.
    init(file: URL) {
        self.file = file
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            logger.error("Could not create journal directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    private struct Line: Codable {
        let at: Date
        let kind: String
        let message: String
        let platform: String?
        let runID: UUID?
    }

    var location: URL { file }

    func append(_ entry: LogEntry) {
        let line = Line(at: entry.at, kind: entry.kind.name, message: entry.message,
                        platform: entry.platform?.rawValue, runID: entry.runID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            var data = try encoder.encode(line)
            data.append(0x0A)
            lock.lock(); defer { lock.unlock() }
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: file, options: .atomic)
            }
            try trimIfNeeded()
        } catch {
            logger.error("Could not write journal: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// All retained lines can be exported for a later debugging session.
    func export(to destination: URL) throws {
        lock.lock(); defer { lock.unlock() }
        try Data(contentsOf: file).write(to: destination, options: .atomic)
    }

    /// The latest lines for the UI. Older numeric dates remain readable.
    func recent(_ count: Int) -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file),
              let contents = String(data: data, encoding: .utf8) else { return [] }
        let iso = JSONDecoder()
        iso.dateDecodingStrategy = .iso8601
        let legacy = JSONDecoder()
        return contents.split(separator: "\n").suffix(max(0, count)).compactMap { raw in
            let data = Data(raw.utf8)
            guard let line = (try? iso.decode(Line.self, from: data))
                    ?? (try? legacy.decode(Line.self, from: data)) else { return nil }
            var entry = LogEntry(kind: LogEntry.Kind(name: line.kind), message: line.message,
                                 at: line.at, platform: line.platform.flatMap(Platform.init(rawValue:)))
            entry.runID = line.runID
            return entry
        }
    }

    /// Bound storage while preserving whole JSON lines. Called after writes,
    /// not just at launch, so a long-running menu-bar app cannot grow forever.
    private func trimIfNeeded() throws {
        // URLResourceValues may cache the size from an earlier append.
        let size = (try FileManager.default.attributesOfItem(atPath: file.path())[.size] as? NSNumber)?.intValue ?? 0
        guard size > maxBytes else { return }
        let contents = try Data(contentsOf: file)
        let start = max(0, contents.count - retainedBytes)
        guard let newline = contents[start...].firstIndex(of: 0x0A) else { return }
        try Data(contents[(newline + 1)...]).write(to: file, options: .atomic)
    }
}

extension LogEntry.Kind {
    var name: String {
        switch self {
        case .start: "start"
        case .detail: "detail"
        case .info: "info"
        case .good: "good"
        case .warning: "warning"
        case .bad: "bad"
        }
    }

    init(name: String) {
        switch name {
        case "start": self = .start
        case "detail": self = .detail
        case "good": self = .good
        case "warning": self = .warning
        case "bad": self = .bad
        default: self = .info
        }
    }
}
