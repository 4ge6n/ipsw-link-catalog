import Foundation

/// Remembers which files have already been checked against Apple's SHA-1, so a
/// daily run does not re-read every byte it holds.
final class VerifiedStore: @unchecked Sendable {
    static let shared = VerifiedStore()

    private struct Record: Codable {
        let size: Int64
        let modified: Date
        let sha1: String
    }

    private let lock = NSLock()
    private var cache: [String: [String: Record]] = [:]

    private func path(for folder: URL) -> URL {
        folder.appending(path: ".ipsw-sync-state.json")
    }

    private func records(_ folder: URL) -> [String: Record] {
        let key = folder.path(percentEncoded: false)
        if let known = cache[key] { return known }
        let loaded = (try? JSONDecoder().decode([String: Record].self, from: Data(contentsOf: path(for: folder)))) ?? [:]
        cache[key] = loaded
        return loaded
    }

    private func save(_ records: [String: Record], to folder: URL) {
        cache[folder.path(percentEncoded: false)] = records
        try? JSONEncoder().encode(records).write(to: path(for: folder), options: .atomic)
    }

    private func stamp(_ url: URL) -> (Int64, Date)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        return (Int64(size), modified)
    }

    func matches(_ url: URL, sha1: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let folder = url.deletingLastPathComponent()
        guard let record = records(folder)[url.lastPathComponent], let now = stamp(url) else { return false }
        // The stamp is compared exactly: a second of slack is enough for a file
        // to be replaced within it and still be taken for the one that was verified.
        return record.sha1 == sha1.lowercased() && record.size == now.0
            && record.modified.timeIntervalSince1970 == now.1.timeIntervalSince1970
    }

    func remember(_ url: URL, sha1: String) {
        lock.lock(); defer { lock.unlock() }
        guard let now = stamp(url) else { return }
        let folder = url.deletingLastPathComponent()
        var known = records(folder)
        known[url.lastPathComponent] = Record(size: now.0, modified: now.1, sha1: sha1.lowercased())
        save(known, to: folder)
    }

    func forget(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        let folder = url.deletingLastPathComponent()
        var known = records(folder)
        known.removeValue(forKey: url.lastPathComponent)
        save(known, to: folder)
    }
}
