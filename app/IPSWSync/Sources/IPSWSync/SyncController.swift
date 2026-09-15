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

    private let engine = SyncEngine()
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
                note(.warning, "Could not read the \(platform.title) catalog: \(error.localizedDescription)")
            }
        }
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
