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
                note(.warning, "Could not read the \(platform.title) catalog: \(error.localizedDescription)")
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
            note(.info, "Catching up on a run that was missed.")
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
        note(.info, "Sync started.")
        for platform in Platform.allCases {
            guard let folder = settings.folder(for: platform) else {
                note(.warning, "No folder chosen for \(platform.title); skipped.")
                continue
            }
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            await engine.sync(
                platform: platform, into: folder,
                devices: settings.selectedDevices, prune: settings.prune,
                concurrently: settings.maxConcurrent,
                report: { [weak self] transfer in self?.update(transfer) },
                log: { [weak self] entry in self?.log.append(entry) }
            )
        }
        settings.lastRun = .now
        running = false
        // The app updates itself on the same daily rhythm as the catalog.
        if settings.autoUpdate { await updater.check(installAutomatically: true) }
        let failures = transfers.filter { if case .failed = $0.state { return true } else { return false } }
        let fetched = transfers.filter { if case .done(let had) = $0.state { return !had } else { return false } }
        note(failures.isEmpty ? .good : .bad, summary(fetched: fetched.count, failed: failures.count))
        notify(fetched: fetched.count, failed: failures.count)
    }

    func cancel() { Task { await engine.cancel() } }

    private func summary(fetched: Int, failed: Int) -> String {
        if failed > 0 { return "Finished with \(failed) failure(s); \(fetched) downloaded." }
        return fetched == 0 ? "Everything was already up to date." : "Downloaded \(fetched) file(s)."
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
