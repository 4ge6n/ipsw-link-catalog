import CryptoKit
import Foundation

/// What one file is doing right now, for the progress list.
struct Transfer: Identifiable, Sendable {
    enum State: Sendable, Equatable {
        case waiting, checking, downloading, verifying
        case done(alreadyHad: Bool)
        case failed(String)
    }
    let id: String
    let name: String
    let device: String
    var received: Int64 = 0
    var total: Int64 = 0
    var state: State = .waiting
    var startedAt: Date = .now
    var resumedFrom: Int64 = 0

    var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    /// Measured from where the transfer resumed, so a resumed file reports its real rate.
    var bytesPerSecond: Double {
        let elapsed = Date.now.timeIntervalSince(startedAt)
        return elapsed > 0 ? Double(received - resumedFrom) / elapsed : 0
    }
    var eta: TimeInterval? {
        let rate = bytesPerSecond
        guard rate > 0, total > received else { return nil }
        return Double(total - received) / rate
    }
}

/// A line in the run log.
struct LogEntry: Identifiable, Sendable {
    enum Kind: Sendable { case info, good, warning, bad }
    let id = UUID()
    let at = Date.now
    let kind: Kind
    let message: String
}

actor SyncEngine {
    private let catalog: CatalogClient
    let session: URLSession
    private var cancelled = false

    init(catalog: CatalogClient = CatalogClient()) {
        self.catalog = catalog
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        // A ten-gigabyte transfer over a slow line must not be cut short.
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        self.session = URLSession(configuration: configuration)
    }

    func cancel() { cancelled = true }

    /// Readable from the transfer itself, which runs outside the actor.
    var isCancelled: Bool { cancelled }

    /// Bring one folder in step with the newest signed builds for a platform.
    func sync(
        platform: Platform,
        into folder: URL,
        devices: Set<String>,
        prune: Bool,
        concurrently limit: Int,
        report: @escaping @Sendable @MainActor (Transfer) -> Void,
        log: @escaping @Sendable @MainActor (LogEntry) -> Void
    ) async throws {
        cancelled = false
        await log(LogEntry(kind: .info, message: "\(platform.title) → \(folder.path(percentEncoded: false))"))
        try checkVolume(folder)
        let wanted = try await wantedFirmwares(platform, devices: devices)
        guard !wanted.isEmpty else {
            await log(LogEntry(kind: .warning, message: String(localized: "No signed builds match the selected devices.")))
            return
        }
        // The actor only coordinates; the transfers themselves are nonisolated
        // so the chosen number of them genuinely run at once.
        var pending = wanted[...]
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            while !cancelled, let firmware = pending.first {
                pending = pending.dropFirst()
                group.addTask { [self] in
                    await fetch(firmware, into: folder, report: report, log: log)
                }
                running += 1
                if running >= max(1, limit) {
                    await group.next()
                    running -= 1
                }
            }
            await group.waitForAll()
        }
        if prune, !cancelled {
            await removeReplacedBuilds(in: folder, keeping: wanted, log: log)
        }
    }

    func everyBuild(_ platform: Platform, channel: Channel) async throws -> [Release] {
        try await catalog.everyBuild(platform, channel: channel).releases
    }

    /// Fetch exactly what was asked for, leaving everything else alone.
    func fetchChosen(
        _ firmwares: [Firmware],
        into folder: URL,
        concurrently limit: Int,
        report: @escaping @Sendable @MainActor (Transfer) -> Void,
        log: @escaping @Sendable @MainActor (LogEntry) -> Void
    ) async {
        cancelled = false
        do { try checkVolume(folder) } catch {
            await log(LogEntry(kind: .bad, message: error.localizedDescription))
            return
        }
        var pending = firmwares[...]
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            while !cancelled, let firmware = pending.first {
                pending = pending.dropFirst()
                group.addTask { [self] in
                    await fetch(firmware, into: folder, report: report, log: log)
                }
                running += 1
                if running >= max(1, limit) {
                    await group.next()
                    running -= 1
                }
            }
            await group.waitForAll()
        }
    }

    func wantedFirmwares(_ platform: Platform, devices: Set<String>) async throws -> [Firmware] {
        let document = try await catalog.latest(platform)
        return document.releases.flatMap(\.firmwares).filter { firmware in
            firmware.signed && (devices.isEmpty || !devices.isDisjoint(with: firmware.devices))
        }
    }

    /// An unmounted drive would otherwise be recreated as an empty folder on the
    /// boot disk and quietly filled with what belongs on the external one.
    func checkVolume(_ folder: URL) throws {
        let parts = folder.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: true)
        guard parts.first == "Volumes", parts.count > 1 else { return }
        let volume = "/Volumes/\(parts[1])"
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil) ?? []
        // These come back as directories, so they carry a trailing slash that the
        // path being checked does not. Comparing the two as they arrive called
        // every drive unmounted, mounted or not.
        guard mounted.contains(where: { trimmed($0.standardizedFileURL) == volume }) else {
            throw SyncError.volumeNotMounted(volume)
        }
    }

    private func trimmed(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
