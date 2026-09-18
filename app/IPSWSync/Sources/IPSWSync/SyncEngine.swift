import CryptoKit
import Foundation

/// What one file is doing right now, for the progress list.
struct Transfer: Identifiable, Sendable {
    enum State: Sendable, Equatable {
        /// Not started. `queued` is narrower: it is in the line for a place
        /// on the wire, with everything before the transfer already done.
        case waiting, checking, queued, downloading, verifying
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
    /// The same answer, readable from the transfer's delegate, which is handed
    /// chunks on a queue of URLSession's choosing and cannot await an actor.
    private let stopped = Flag()
    /// How many downloads may run at once. Held by the engine rather than by
    /// one platform's run, so seven folders syncing at the same time still add
    /// up to the number that was asked for.
    let downloads = Gate()

    init(catalog: CatalogClient = CatalogClient()) {
        self.catalog = catalog
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        // A ten-gigabyte transfer over a slow line must not be cut short.
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        self.session = URLSession(configuration: configuration)
    }

    func cancel() { cancelled = true; stopped.set(true) }

    /// Readable from the transfer itself, which runs outside the actor.
    var isCancelled: Bool { cancelled }

    func resetCancellation() { cancelled = false; stopped.set(false) }

    /// Start a run: clear any earlier Stop and set how many transfers may share
    /// the line. Called once for the whole run, because the platforms are
    /// synced together and a limit each would be seven times the limit.
    func beginRun(concurrently limit: Int) async {
        resetCancellation()
        await downloads.setLimit(limit)
    }

    /// Read by the delegate between chunks, so Stop reaches the transfer that
    /// is actually running rather than only the gap before the next file.
    nonisolated var stopRequested: @Sendable () -> Bool {
        let flag = stopped
        return { flag.value }
    }

    /// Bring one folder in step with the newest signed builds for a platform.
    func sync(
        platform: Platform,
        into folder: URL,
        devices: Set<String>?,
        /// Builds from Apple's own page, which the catalog may not carry yet.
        alongside extra: [Firmware] = [],
        prune: Bool,
        concurrently limit: Int,
        report: @escaping @Sendable @MainActor (Transfer) -> Void,
        log: @escaping @Sendable @MainActor (LogEntry) -> Void
    ) async throws {
        await log(LogEntry(kind: .info, message: "\(platform.title) → \(folder.path(percentEncoded: false))"))
        try checkVolume(folder)
        var wanted = try await wantedFirmwares(platform, devices: devices)
        // The same image can be in both; the catalog's copy carries a checksum,
        // so that is the one kept.
        let known = Set(wanted.map(\.filename))
        wanted += extra.filter { firmware in
            !known.contains(firmware.filename)
            && (devices.map { !$0.isDisjoint(with: firmware.devices) } ?? true)
        }
        guard !wanted.isEmpty else {
            await log(LogEntry(kind: .warning, message: String(localized: "No signed builds match the selected devices.")))
            return
        }
        // The actor only coordinates; the transfers themselves are nonisolated
        // so the chosen number of them genuinely run at once.
        // Read once, and used twice: to decide what a new build replaces, and
        // to count the room those will give back when it does.
        let index = prune ? ((try? await deviceIndex(platform)) ?? DeviceIndex()) : nil
        var pending = wanted[...]
        // The cap here is not the download limit — the gate is. It is a few
        // more than that, so a file that has finished downloading can be
        // hashed while the slot it gave up is already carrying the next one.
        let atOnce = max(1, limit) + 4
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            while !cancelled, let firmware = pending.first {
                pending = pending.dropFirst()
                group.addTask { [self] in
                    await fetch(firmware, into: folder, reclaiming: index, report: report, log: log)
                }
                running += 1
                if running >= atOnce {
                    await group.next()
                    running -= 1
                }
            }
            await group.waitForAll()
        }
        if prune, !cancelled {
            // What each image on the drive is for, so a build is replaced by
            // devices rather than by the name Apple happened to give the file.
            await removeReplacedBuilds(in: folder, keeping: wanted, using: index ?? DeviceIndex(), log: log)
        }
    }

    /// What each model-named image has covered before, for reading a page that
    /// names images after models and gives their identifiers nowhere.
    func deviceIndex(_ platform: Platform) async throws -> DeviceIndex {
        var index = DeviceIndex()
        for channel in Channel.allCases {
            guard let releases = try? await catalog.everyBuild(platform, channel: channel).releases else { continue }
            for release in releases {
                for firmware in release.firmwares {
                    index.add(firmware, at: release.releasedAt)
                }
            }
        }
        return index
    }

    func everyBuild(_ platform: Platform, channel: Channel) async throws -> [Release] {
        let releases = try await catalog.everyBuild(platform, channel: channel).releases
        // The beta track carries the build that eventually shipped as well as
        // the ones leading up to it. Asked for betas and release candidates,
        // that is what comes back — a build Apple gave no beta or RC label is
        // a release, and belongs in the other channel.
        guard channel == .beta else { return releases }
        return releases.filter { $0.prerelease != nil }
    }

    /// Fetch exactly what was asked for, leaving everything else alone.
    func fetchChosen(
        _ firmwares: [Firmware],
        into folder: URL,
        concurrently limit: Int,
        report: @escaping @Sendable @MainActor (Transfer) -> Void,
        log: @escaping @Sendable @MainActor (LogEntry) -> Void
    ) async {
        resetCancellation()
        do { try checkVolume(folder) } catch {
            await log(LogEntry(kind: .bad, message: error.localizedDescription))
            return
        }
        await downloads.setLimit(limit)
        var pending = firmwares[...]
        let atOnce = max(1, limit) + 4
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            while !cancelled, let firmware = pending.first {
                pending = pending.dropFirst()
                group.addTask { [self] in
                    await fetch(firmware, into: folder, report: report, log: log)
                }
                running += 1
                if running >= atOnce {
                    await group.next()
                    running -= 1
                }
            }
            await group.waitForAll()
        }
    }

    /// `nil` means every device; an empty set means none. They used to be the
    /// same value, so clearing the device list fetched the whole catalog.
    func wantedFirmwares(_ platform: Platform, devices: Set<String>?) async throws -> [Firmware] {
        let document = try await catalog.latest(platform)
        return document.releases.flatMap(\.firmwares).filter { firmware in
            guard firmware.signed else { return false }
            guard let devices else { return true }
            return !devices.isDisjoint(with: firmware.devices)
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

/// What the catalog knows about which devices an image covers, for filling in
/// what Apple's downloads page leaves out.
///
/// Not a union across every build: a model-named image drops devices as they
/// stop being supported — iPad_Pro_A12X_A12Z covered four iPads by iPadOS 27
/// and twelve before that — so unioning would offer a build to a device it
/// cannot restore. The newest build that used a name is what that name means.
struct DeviceIndex: Sendable {
    /// The same image in the catalog, which settles it exactly.
    private var byFilename: [String: [String]] = [:]
    /// Failing that, what the name covered in the newest build that used it.
    private var byModel: [String: (devices: [String], at: Date)] = [:]
    /// iPhone18,5 → "iPhone 17 Pro", for the sources that publish only the one.
    private(set) var names: [String: String] = [:]

    mutating func add(_ firmware: Firmware, at moment: Date?) {
        guard !firmware.devices.isEmpty else { return }
        byFilename[firmware.filename] = firmware.devices
        // Only an image for a single device says what that device is called;
        // one covering four carries all four names at once.
        if firmware.devices.count == 1 { names[firmware.devices[0]] = firmware.name }
        let when = moment ?? .distantPast
        if let held = byModel[firmware.modelKey], held.at >= when { return }
        byModel[firmware.modelKey] = (firmware.devices, when)
    }

    /// Take the newer of two, name by name, rather than merging their devices.
    mutating func formUnion(_ other: DeviceIndex) {
        names.merge(other.names) { mine, _ in mine }
        byFilename.merge(other.byFilename) { _, new in new }
        byModel.merge(other.byModel) { mine, theirs in mine.at >= theirs.at ? mine : theirs }
    }

    func devices(for filename: String) -> [String] {
        exact(filename) ?? byModel[Firmware.modelKey(of: filename)]?.devices ?? []
    }

    /// The catalog's own answer for this very file, where it has one.
    func exact(_ filename: String) -> [String]? { byFilename[filename] }
}


/// A boolean two threads may look at.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return held }
    func set(_ newValue: Bool) { lock.lock(); held = newValue; lock.unlock() }
}
