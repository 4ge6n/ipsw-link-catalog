import Foundation
import os

/// Events from the browser and URLSession delegate survive an app relaunch.
/// The delegate writes directly here because it can run before a view exists.
final class DiagnosticJournal: @unchecked Sendable {
    static let shared = DiagnosticJournal()

    private struct Event: Encodable {
        let at: Date
        let level: String
        let area: String
        let event: String
        let message: String
        let sessionID: UUID
        let transferID: String?
        let platform: String?
    }

    private let lock = NSLock()
    private let fallback = Logger(subsystem: "com.github.4ge6n.ipsw-link-catalog.IPSWBrowser",
                                  category: "diagnostics")
    private let maxBytes = 10 * 1024 * 1024
    private let keepBytes = 6 * 1024 * 1024
    let sessionID = UUID()
    let location: URL

    private init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Diagnostics", directoryHint: .isDirectory)
        location = folder.appending(path: "ipsw-browser.jsonl")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // The path as the file system spells it: path() alone is
            // percent-encoded, so "Application Support" read as
            // "Application%20Support" and the file was never found.
            if !FileManager.default.fileExists(atPath: location.path(percentEncoded: false)) {
                FileManager.default.createFile(atPath: location.path(percentEncoded: false), contents: nil)
            }
        } catch {
            fallback.error("Cannot create diagnostic journal: \(error.localizedDescription, privacy: .public)")
        }
    }

    func record(_ level: String, area: String, event: String, _ message: String,
                transferID: String? = nil, platform: String? = nil) {
        let item = Event(at: .now, level: level, area: area, event: event,
                         message: message, sessionID: sessionID,
                         transferID: transferID, platform: platform)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            var data = try encoder.encode(item)
            data.append(0x0A)
            lock.lock(); defer { lock.unlock() }
            // Created here if it is missing, rather than once at launch and
            // hoped for: no journal line was ever written on the Simulator
            // because the file the launch meant to make was not there.
            let path = location.path(percentEncoded: false)
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: location)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
            if size > maxBytes {
                let contents = try Data(contentsOf: location)
                let start = max(0, contents.count - keepBytes)
                if let newline = contents[start...].firstIndex(of: 0x0A) {
                    try Data(contents[(newline + 1)...]).write(to: location, options: .atomic)
                }
            }
        } catch {
            fallback.error("Cannot write diagnostic journal: \(error.localizedDescription, privacy: .public)")
        }
    }

    func recordError(_ error: Error, area: String, event: String, _ message: String,
                     transferID: String? = nil, platform: String? = nil) {
        let detail = error as NSError
        record("error", area: area, event: event,
               "\(message): \(detail.localizedDescription) [\(detail.domain):\(detail.code)]",
               transferID: transferID, platform: platform)
    }
}
