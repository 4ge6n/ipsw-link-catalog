import Foundation
import UserNotifications

/// Watches Apple for builds as they ship.
///
/// The catalog this app normally reads is rebuilt every quarter of an hour and
/// then sits in a CDN, so it learns about a build some twenty minutes after
/// Apple posts it. Three of Apple's own endpoints know sooner, and none of
/// them is expensive to ask:
///
/// - the releases feed, eighteen kilobytes, which names every build the minute
///   it ships and is the first place any of them appears;
/// - the restore catalog, which carries the link and the checksum, and which
///   is asked conditionally so an unchanged one answers with nothing at all;
/// - the downloads page, the only place a beta's link lives, which needs the
///   account and is the heaviest — so it is read when there is a reason to.
@MainActor
@Observable
final class ReleaseWatch {
    /// What Apple is offering, newest first.
    private(set) var builds: [Build] = []
    private(set) var lastLooked: Date?
    private(set) var failure: String?
    private(set) var looking = false

    private let settings = Settings.shared
    private let feed = AppleFeed()
    private let apple = AppleRestoreCatalog()
    private weak var controller: SyncController?
    private var timer: Timer?
    /// Built once from the catalog and kept, so the page's model-named images
    /// and the restore catalog's bare identifiers both read as devices.
    private var index: DeviceIndex?

    func begin(with controller: SyncController) {
        self.controller = controller
        reschedule()
        Task { await look() }
    }

    /// Called whenever the switch or the interval changes.
    func reschedule() {
        timer?.invalidate()
        timer = nil
        guard settings.portalWatch else { return }
        let fires = Timer(timeInterval: TimeInterval(settings.portalMinutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.look() }
        }
        // .common, so the timer keeps its rhythm while a menu is open.
        RunLoop.main.add(fires, forMode: .common)
        timer = fires
    }

    /// Ask Apple what it has. `announce` is what makes this a watch rather than
    /// a fetch: it is off for the look the interface asks for and for the one
    /// the daily run makes, and on for the ones the timer makes.
    @discardableResult
    func look(announce: Bool = true) async -> [Build] {
        guard let controller, !looking else { return builds }
        looking = true
        defer { looking = false }
        var trouble: [String] = []
        var found: [String: Build] = [:]

        // The announcement first: it is the cheapest, and it is what says
        // whether anything has happened at all.
        var announced: [Build] = []
        do {
            announced = try await feed.announcements().map {
                Build(platform: $0.platform, version: $0.version, build: $0.build,
                      prerelease: $0.prerelease, at: $0.at, firmwares: [], source: .announced)
            }
            for build in announced { found[build.id] = build }
        } catch { trouble.append(error.localizedDescription) }

        let known = await identifiers(controller)
        // Then the link and the checksum, if Apple has started signing it.
        do {
            let reading = try await apple.read(naming: known.names)
            for build in fromApple(reading.releases, announced: announced) {
                found[build.id] = found[build.id]?.merged(with: build) ?? build
            }
        } catch { trouble.append(error.localizedDescription) }

        // And the page, for the betas the other two will never carry. It needs
        // the account, so it is only read when there is one.
        if DeveloperPortal.shared.signedIn {
            do {
                for entry in try await DeveloperPortal.shared.downloads(index: known) {
                    let build = Build(platform: entry.platform, version: entry.version, build: entry.build,
                                      prerelease: entry.prerelease, at: entry.released,
                                      firmwares: entry.firmwares, source: .portal)
                    found[build.id] = found[build.id]?.merged(with: build) ?? build
                }
            } catch { trouble.append(error.localizedDescription) }
        }

        guard !found.isEmpty else {
            failure = trouble.first
            return builds
        }
        failure = trouble.isEmpty ? nil : trouble.first
        lastLooked = .now
        builds = found.values.sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }

        let fresh = newcomers(in: builds)
        // Everything is new the first time. Announcing all of it would be forty
        // notifications about builds that shipped months ago, so the first look
        // is what establishes what "already known" means.
        if settings.seenPortalBuilds.isEmpty {
            remember(builds)
        } else if !fresh.isEmpty {
            remember(fresh)
            if announce { tell(about: fresh) }
            controller.arrived(fresh)
        }
        return builds
    }

    /// Apple's restore catalog names a build and its devices but not which
    /// platform Apple called it, so the announcement decides that where it can
    /// and the devices decide it otherwise.
    private func fromApple(_ releases: [Release], announced: [Build]) -> [Build] {
        var found: [Build] = []
        for release in releases {
            for platform in Platform.allCases {
                let firmwares = release.firmwares.filter(platform.owns)
                guard !firmwares.isEmpty else { continue }
                let same = announced.first { $0.build == release.build && $0.platform == platform }
                found.append(Build(platform: platform, version: same?.version ?? release.version,
                                   build: release.build, prerelease: same?.prerelease, at: same?.at,
                                   firmwares: firmwares, source: .apple))
            }
        }
        return found
    }

    /// The catalog's own view of which devices an image covers, read once.
    private func identifiers(_ controller: SyncController) async -> DeviceIndex {
        if let index { return index }
        let built = await controller.deviceIndex()
        index = built
        return built
    }

    /// Builds that were not there the last time, minus the ones that are not
    /// wanted: a person who asked not to hear about betas is not told.
    private func newcomers(in found: [Build]) -> [Build] {
        found.filter { build in
            guard settings.portalIncludesBetas || !build.isBeta else { return false }
            return !settings.seenPortalBuilds.contains(build.id)
        }
    }

    private func remember(_ found: [Build]) {
        // Betas that were skipped are remembered too, so turning the switch on
        // later is not a flood of announcements about builds already shipped.
        settings.seenPortalBuilds.formUnion(found.map(\.id))
        // Apple drops a build from all of these when it is superseded; keeping
        // the last few hundred is enough for one never to be announced twice.
        if settings.seenPortalBuilds.count > 500 {
            settings.seenPortalBuilds = Set(settings.seenPortalBuilds.sorted().suffix(400))
        }
    }

    private func tell(about fresh: [Build]) {
        let content = UNMutableNotificationContent()
        content.title = fresh.count == 1
            ? fresh[0].title
            : String(format: String(localized: "%lld new build(s) from Apple"), fresh.count)
        if fresh.count == 1, let only = fresh.first {
            content.body = only.isDownloadable
                ? String(format: String(localized: "Build %1$@ — %2$lld restore image(s)."),
                         only.build, only.firmwares.count)
                // Apple announces a build before it puts the images up.
                : String(format: String(localized: "Build %@ — announced; no download yet."), only.build)
        } else {
            content.body = fresh.map(\.title).joined(separator: ", ")
        }
        content.sound = .default
        // One thread, so several of these stack rather than pile up.
        content.threadIdentifier = "releases"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
