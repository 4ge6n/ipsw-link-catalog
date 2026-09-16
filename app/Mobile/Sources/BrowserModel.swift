import Foundation
import Observation

/// Holds the catalog the browser shows and runs the transfers it starts.
@MainActor
@Observable
final class BrowserModel {
    var platform: Platform = .ios { didSet { Task { await load() } } }
    var channel: Channel = .release { didSet { Task { await load() } } }

    private(set) var releases: [Release] = []
    private(set) var loading = false
    private(set) var failure: String?

    private(set) var transfers: [Transfer] = []
    private(set) var log: [LogEntry] = []
    private(set) var saved: [Library.Item] = []

    private let engine = SyncEngine()
    private var running: Set<String> = []

    func isRunning(_ firmware: Firmware) -> Bool { running.contains(firmware.id) }
    var isBusy: Bool { !running.isEmpty }

    func transfer(for firmware: Firmware) -> Transfer? {
        transfers.first { $0.id == firmware.id }
    }

    func load() async {
        loading = true
        failure = nil
        defer { loading = false }
        do {
            releases = try await engine.everyBuild(platform, channel: channel)
        } catch {
            releases = []
            failure = error.localizedDescription
        }
    }

    func refreshSaved() { saved = Library.contents() }

    /// Fetch one image into the Files-visible folder, checksum and all. The
    /// engine that does it is the Mac app's, unchanged.
    func download(_ firmware: Firmware) async {
        guard !running.contains(firmware.id) else { return }
        running.insert(firmware.id)
        defer { running.remove(firmware.id); refreshSaved() }
        await engine.fetch(
            firmware, into: Library.incoming,
            report: { [weak self] transfer in self?.record(transfer) },
            log: { [weak self] entry in self?.log.append(entry) }
        )
        // Only a finished one is moved into view; anything else stays aside so
        // the next attempt carries on rather than starting over.
        if case .done = transfer(for: firmware)?.state {
            do { try Library.accept(firmware.filename) }
            catch { log.append(LogEntry(kind: .bad, message: error.localizedDescription)) }
        }
    }

    func cancel() { Task { await engine.cancel() } }

    /// Whether this image is already sitting in the folder, whole.
    func alreadySaved(_ firmware: Firmware) -> Bool {
        saved.contains { $0.name == firmware.filename }
    }

    private func record(_ transfer: Transfer) {
        if let index = transfers.firstIndex(where: { $0.id == transfer.id }) {
            transfers[index] = transfer
        } else {
            transfers.append(transfer)
        }
    }
}
