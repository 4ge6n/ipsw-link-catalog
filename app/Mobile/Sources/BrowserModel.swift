import Foundation
import Observation

/// Holds the catalog the browser shows and follows the transfers it starts.
@MainActor
@Observable
final class BrowserModel {
    var platform: Platform = .ios { didSet { Task { await load() } } }
    var channel: Channel = .release { didSet { Task { await load() } } }

    private(set) var releases: [Release] = []
    /// The same builds, arranged major → point release → build.
    private(set) var tree: [VersionTree.Major] = []
    private(set) var loading = false
    private(set) var failure: String?

    private(set) var transfers: [Transfer] = []
    private(set) var log: [LogEntry] = []
    private(set) var saved: [Library.Item] = []
    /// Raised when an image will not fit, rather than filling the disk and
    /// failing however far in that happens to be.
    var noRoom: String?

    private let engine = SyncEngine()
    private let downloads = BackgroundDownloads.shared

    func isRunning(_ firmware: Firmware) -> Bool {
        if case .downloading = transfer(for: firmware)?.state { return true }
        if case .verifying = transfer(for: firmware)?.state { return true }
        return false
    }

    var isBusy: Bool { transfers.contains { isBusy($0.state) } }

    private func isBusy(_ state: Transfer.State) -> Bool {
        switch state {
        case .downloading, .verifying, .checking: true
        default: false
        }
    }

    func transfer(for firmware: Firmware) -> Transfer? {
        transfers.first { $0.id == firmware.id }
    }

    /// Hand the transfer manager somewhere to report to, and pick up whatever
    /// the system was still carrying while the app was away.
    func listen() {
        downloads.report = { [weak self] transfer in self?.record(transfer) }
        downloads.log = { [weak self] entry in self?.log.append(entry) }
        downloads.settled = { [weak self] in self?.refreshSaved() }
        downloads.resumeReporting()
        DiagnosticJournal.shared.record("detail", area: "app", event: "listen",
                                        "Transfer reporting resumed")
    }

    func load() async {
        let requestedPlatform = platform
        let requestedChannel = channel
        DiagnosticJournal.shared.record("detail", area: "catalog", event: "request",
                                        "Loading \(requestedChannel.rawValue) catalog",
                                        platform: requestedPlatform.rawValue)
        loading = true
        failure = nil
        defer { loading = false }
        do {
            releases = try await engine.everyBuild(requestedPlatform, channel: requestedChannel)
            tree = VersionTree.of(releases)
            DiagnosticJournal.shared.record("info", area: "catalog", event: "loaded",
                                            "releases=\(releases.count), images=\(releases.flatMap(\.firmwares).count)",
                                            platform: requestedPlatform.rawValue)
        } catch {
            releases = []
            tree = []
            failure = error.localizedDescription
            DiagnosticJournal.shared.recordError(error, area: "catalog", event: "failed",
                                                 "Catalog request failed", platform: requestedPlatform.rawValue)
        }
    }

    func refreshSaved() { saved = Library.contents() }

    /// Ask the server how large it is, check it will fit, and hand it over.
    func download(_ firmware: Firmware) async {
        guard !isRunning(firmware) else { return }
        let platform = Platform.allCases.first { $0.covers(firmware) }?.rawValue
        DiagnosticJournal.shared.record("info", area: "transfer", event: "preflight",
                                        "\(firmware.filename): checking size and free space; host=\(firmware.url.host() ?? "?")",
                                        transferID: firmware.id, platform: platform)
        var transfer = Transfer(id: firmware.id, name: firmware.filename, device: firmware.name)
        transfer.state = .checking
        record(transfer)
        let wanted = await size(of: firmware.url)
        let free = Library.freeSpace
        DiagnosticJournal.shared.record("detail", area: "transfer", event: "capacity",
                                        "\(firmware.filename): expected=\(wanted.map { String($0) } ?? "unknown") bytes, free=\(free.map { String($0) } ?? "unknown") bytes",
                                        transferID: firmware.id, platform: platform)
        if let wanted, let free, wanted > free {
            transfers.removeAll { $0.id == firmware.id }
            noRoom = String(format: String(localized: "%1$@ needs %2$@ and there is %3$@ free."),
                            firmware.name,
                            wanted.formatted(.byteCount(style: .file)),
                            free.formatted(.byteCount(style: .file)))
            DiagnosticJournal.shared.record("warning", area: "transfer", event: "no_room",
                                            "\(firmware.filename): expected=\(wanted), free=\(free) bytes",
                                            transferID: firmware.id, platform: platform)
            return
        }
        downloads.start(firmware)
    }

    func cancel(_ firmware: Firmware) {
        DiagnosticJournal.shared.record("warning", area: "transfer", event: "stop_requested",
                                        firmware.filename, transferID: firmware.id)
        downloads.stop(firmware)
        transfers.removeAll { $0.id == firmware.id }
    }

    func alreadySaved(_ firmware: Firmware) -> Bool {
        saved.contains { $0.name == firmware.filename }
    }

    private func size(of url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 30
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                DiagnosticJournal.shared.record("warning", area: "transfer", event: "head_status",
                                                "HEAD \(url.lastPathComponent): HTTP \(http.statusCode)")
                return nil
            }
            let length = response.expectedContentLength
            return length > 0 ? length : nil
        } catch {
            DiagnosticJournal.shared.recordError(error, area: "transfer", event: "head_failed",
                                                 "HEAD \(url.lastPathComponent)")
            return nil
        }
    }

    private func record(_ transfer: Transfer) {
        if let index = transfers.firstIndex(where: { $0.id == transfer.id }) {
            transfers[index] = transfer
        } else {
            transfers.append(transfer)
        }
    }
}
