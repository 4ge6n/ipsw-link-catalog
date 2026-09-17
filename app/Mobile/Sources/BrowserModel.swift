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
    /// Builds that shipped publicly. A build in the beta channel and not in
    /// here is a pre-release — which is a fact rather than a guess about the
    /// shape of its build number.
    private(set) var public_: Set<String> = []
    /// Apple's own wording for the builds it has announced lately: "beta 3",
    /// "RC". Only the last few weeks, and never invented for the rest.
    private(set) var wording: [String: String] = [:]
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
    private let feed = AppleFeed()

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
    }

    func load() async {
        loading = true
        failure = nil
        defer { loading = false }
        do {
            releases = try await engine.everyBuild(platform, channel: channel)
            tree = VersionTree.of(releases)
        } catch {
            releases = []
            tree = []
            failure = error.localizedDescription
        }
        // Both of these only add to what is shown, so neither is allowed to
        // fail the load.
        if channel == .beta, public_.isEmpty {
            public_ = Set((try? await engine.everyBuild(platform, channel: .release))?.map(\.build) ?? [])
        }
        if wording.isEmpty, let announced = try? await feed.announcements() {
            wording = Dictionary(announced.compactMap { announcement in
                announcement.prerelease.map { (announcement.build, $0) }
            }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// What to call one build, saying only what is known. Apple's own wording
    /// where it has said it lately; "Pre-release" where all that is known is
    /// that it never shipped; nothing where it did ship.
    func label(for release: Release) -> String? {
        if let said = wording[release.build] { return said }
        guard channel == .beta, !public_.isEmpty, !public_.contains(release.build) else { return nil }
        return String(localized: "Pre-release")
    }

    func refreshSaved() { saved = Library.contents() }

    /// Ask the server how large it is, check it will fit, and hand it over.
    func download(_ firmware: Firmware) async {
        guard !isRunning(firmware) else { return }
        var transfer = Transfer(id: firmware.id, name: firmware.filename, device: firmware.name)
        transfer.state = .checking
        record(transfer)
        if let wanted = await size(of: firmware.url), let free = Library.freeSpace, wanted > free {
            transfers.removeAll { $0.id == firmware.id }
            noRoom = String(format: String(localized: "%1$@ needs %2$@ and there is %3$@ free."),
                            firmware.name,
                            wanted.formatted(.byteCount(style: .file)),
                            free.formatted(.byteCount(style: .file)))
            return
        }
        downloads.start(firmware)
    }

    func cancel(_ firmware: Firmware) {
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
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let length = response.expectedContentLength
        return length > 0 ? length : nil
    }

    private func record(_ transfer: Transfer) {
        if let index = transfers.firstIndex(where: { $0.id == transfer.id }) {
            transfers[index] = transfer
        } else {
            transfers.append(transfer)
        }
    }
}
