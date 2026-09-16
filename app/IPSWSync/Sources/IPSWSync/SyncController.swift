import AppKit
import Foundation
import Observation
import UserNotifications

/// Drives the engine for the interface: what is running, what it found, and
/// when it should run next.
@MainActor
@Observable
final class SyncController {
    private(set) var transfers: [Transfer] = []
    private(set) var log: [LogEntry] = []
    private(set) var running = false
    private(set) var knownDevices: [Platform: [Firmware]] = [:]
    private(set) var nextRun: Date?

    /// Where the whole run stands, for the bar above the per-file list.
    var overall: (done: Int, total: Int, fraction: Double, received: Int64, expected: Int64) {
        let done = transfers.filter { if case .done = $0.state { return true } else { return false } }.count
        let expected = transfers.reduce(Int64(0)) { $0 + max($1.total, $1.received) }
        let received = transfers.reduce(Int64(0)) { partial, transfer in
            if case .done = transfer.state { return partial + max(transfer.total, transfer.received) }
            return partial + transfer.received
        }
        let fraction = expected > 0 ? Double(received) / Double(expected) : 0
        return (done, transfers.count, min(1, fraction), received, expected)
    }

    private let engine = SyncEngine()
    let updater = Updater()
    private let settings = Settings.shared
    private var timer: Timer?

    init() {
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // A Mac asleep at the appointed time gets its run on waking.
            Task { @MainActor in self?.scheduleNext(catchUpIfMissed: true) }
        }
        NotificationCenter.default.addObserver(
            forName: .ipswSyncNow, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.run() }
        }
    }

    /// Load the device list so the interface can offer it.
    func loadDevices() async {
        for platform in Platform.allCases {
            do {
                knownDevices[platform] = try await engine.wantedFirmwares(platform, devices: [])
            } catch {
                // Starting hidden closes the window, which cancels this; that is
                // not something to report as a failure.
                guard !isCancellation(error) else { return }
                note(.warning, String(format: String(localized: "Could not read the %1$@ catalog: %2$@"), platform.title, error.localizedDescription))
            }
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    func scheduleNext(catchUpIfMissed: Bool = false) {
        timer?.invalidate()
        nextRun = settings.nextRun()
        guard let nextRun else { return }
        if catchUpIfMissed, settings.missedRun() {
            note(.info, String(localized: "Catching up on a run that was missed."))
            Task { await run() }
        }
        let fires = Timer(fire: nextRun, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.run()
                self?.scheduleNext()
            }
        }
        RunLoop.main.add(fires, forMode: .common)
        timer = fires
    }

    func run() async {
        guard !running else { return }
        running = true
        transfers = []
        note(.info, String(localized: "Sync started."))
        var attempted = 0
        var unreachable = 0
        for platform in Platform.allCases {
            guard let folder = settings.folder(for: platform) else {
                note(.warning, String(format: String(localized: "No folder chosen for %@; skipped."), platform.title))
                continue
            }
            attempted += 1
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            do {
                try await engine.sync(
                    platform: platform, into: folder,
                    devices: settings.selectedDevices, prune: settings.prune,
                    concurrently: settings.maxConcurrent,
                    report: { [weak self] transfer in self?.update(transfer) },
                    log: { [weak self] entry in self?.log.append(entry) }
                )
            } catch {
                unreachable += 1
                note(.bad, error.localizedDescription)
            }
        }
        // A run that reached nothing is not a run. Leaving the mark alone keeps
        // it counted as missed, so plugging the drive in earns a catch-up rather
        // than a wait until tomorrow.
        if attempted == 0 || unreachable < attempted { settings.lastRun = .now }
        running = false
        // The app updates itself on the same daily rhythm as the catalog.
        if settings.autoUpdate { await updater.check(installAutomatically: true) }
        let failures = transfers.filter { if case .failed = $0.state { return true } else { return false } }
        let fetched = transfers.filter { if case .done(let had) = $0.state { return !had } else { return false } }
        let failed = failures.count + unreachable
        note(failed == 0 ? .good : .bad, summary(fetched: fetched.count, failed: failed))
        notify(fetched: fetched.count, failed: failed)
    }

    func cancel() { Task { await engine.cancel() } }

    /// Read what is on the drive against Apple's own checksums. The daily run
    /// trusts the record of having checked; this does not.
    func verify() async {
        guard !running else { return }
        running = true
        transfers = []
        note(.info, String(localized: "Checking what is already here against Apple's checksums."))
        for platform in Platform.allCases {
            guard let folder = settings.folder(for: platform) else { continue }
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            do {
                try await engine.verify(
                    platform, in: folder,
                    report: { [weak self] transfer in self?.update(transfer) },
                    log: { [weak self] entry in self?.log.append(entry) })
            } catch {
                note(.bad, error.localizedDescription)
            }
        }
        running = false
    }

    /// Fetch builds the person picked by hand. Nothing is pruned: a build asked
    /// for on purpose must not take another one away.
    func download(_ firmwares: [Firmware], into folder: URL) async {
        guard !running else { return }
        running = true
        transfers = []
        // Asked before anything is announced, so a missing drive reads as the
        // refusal it is rather than as a download that started.
        do { try await engine.checkVolume(folder) } catch {
            note(.bad, error.localizedDescription)
            running = false
            return
        }
        note(.info, String(format: String(localized: "Downloading %1$lld file(s) into %2$@"), firmwares.count, folder.path(percentEncoded: false)))
        let scoped = folder.startAccessingSecurityScopedResource()
        await engine.fetchChosen(
            firmwares, into: folder, concurrently: settings.maxConcurrent,
            report: { [weak self] transfer in self?.update(transfer) },
            log: { [weak self] entry in self?.log.append(entry) }
        )
        if scoped { folder.stopAccessingSecurityScopedResource() }
        running = false
        let failures = transfers.filter { if case .failed = $0.state { return true } else { return false } }
        note(failures.isEmpty ? .good : .bad,
             failures.isEmpty
             ? String(localized: "Finished.")
             : String(format: String(localized: "Finished with %lld failure(s)."), failures.count))
    }

    /// Every build the catalog knows, for the picker.
    func everyBuild(_ platform: Platform, channel: Channel) async throws -> [Release] {
        try await engine.everyBuild(platform, channel: channel)
    }

    private func summary(fetched: Int, failed: Int) -> String {
        if failed > 0 {
            return String(format: String(localized: "Finished with %1$lld failure(s); %2$lld downloaded."), failed, fetched)
        }
        return fetched == 0
            ? String(localized: "Everything was already up to date.")
            : String(format: String(localized: "Downloaded %lld file(s)."), fetched)
    }

    private func update(_ transfer: Transfer) {
        if let index = transfers.firstIndex(where: { $0.id == transfer.id }) {
            transfers[index] = transfer
        } else {
            transfers.append(transfer)
        }
    }

    private func note(_ kind: LogEntry.Kind, _ message: String) {
        log.append(LogEntry(kind: kind, message: message))
    }

    private func notify(fetched: Int, failed: Int) {
        let content = UNMutableNotificationContent()
        content.title = "IPSW Sync"
        content.body = summary(fetched: fetched, failed: failed)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
