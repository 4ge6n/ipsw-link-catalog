import Foundation
import UserNotifications

/// Keeps an eye on Apple's own downloads page.
///
/// The catalog is rebuilt on a schedule, so a build posted at noon reaches it
/// later that day. The page is what Apple is offering the moment it is asked,
/// so this asks it — on a timer while the app runs, and once whenever the app
/// comes back — and says so when a build appears that was not there before.
@MainActor
@Observable
final class PortalWatch {
    /// What the page last held, newest build first.
    private(set) var entries: [PortalCatalog.Entry] = []
    private(set) var lastLooked: Date?
    private(set) var failure: String?
    private(set) var looking = false

    private let settings = Settings.shared
    private weak var controller: SyncController?
    private var timer: Timer?

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
        let every = TimeInterval(settings.portalMinutes * 60)
        let fires = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.look() }
        }
        // .common, so the timer keeps its rhythm while a menu is open.
        RunLoop.main.add(fires, forMode: .common)
        timer = fires
    }

    /// Ask the page what it is offering. `announce` is what makes this a watch
    /// rather than a fetch: it is off for the look the interface asks for, and
    /// on for the ones the timer asks for.
    @discardableResult
    func look(announce: Bool = true) async -> [PortalCatalog.Entry] {
        guard let controller, !looking else { return entries }
        await DeveloperPortal.shared.refreshSignedIn()
        guard DeveloperPortal.shared.signedIn else { return entries }
        looking = true
        defer { looking = false }
        do {
            let found = try await controller.portalDownloads()
            failure = nil
            lastLooked = .now
            entries = found.sorted { ($0.released ?? .distantPast) > ($1.released ?? .distantPast) }
            let fresh = newcomers(in: entries)
            // Everything is new the first time. Announcing all of it would be
            // sixteen notifications about builds that have been out for months,
            // so the first look is what establishes what "already known" means.
            if settings.seenPortalBuilds.isEmpty {
                remember(entries)
            } else if !fresh.isEmpty {
                remember(fresh)
                if announce { tell(about: fresh) }
                controller.noteFromPortal(fresh)
            }
            return entries
        } catch {
            failure = error.localizedDescription
            return entries
        }
    }

    /// Builds that were not there the last time, minus the ones that are not
    /// wanted: a person who asked not to hear about betas is not told.
    private func newcomers(in found: [PortalCatalog.Entry]) -> [PortalCatalog.Entry] {
        found.filter { entry in
            guard settings.portalIncludesBetas || !entry.isBeta else { return false }
            return !settings.seenPortalBuilds.contains(entry.id)
        }
    }

    private func remember(_ found: [PortalCatalog.Entry]) {
        // Betas that were skipped are remembered too, so turning the switch on
        // later is not a flood of announcements about builds already shipped.
        settings.seenPortalBuilds.formUnion(found.map(\.id))
        // Apple drops a build from the page when it is superseded; keeping the
        // last few hundred is enough for one never to be announced twice.
        if settings.seenPortalBuilds.count > 500 {
            settings.seenPortalBuilds = Set(settings.seenPortalBuilds.sorted().suffix(400))
        }
    }

    private func tell(about fresh: [PortalCatalog.Entry]) {
        let content = UNMutableNotificationContent()
        content.title = fresh.count == 1
            ? fresh[0].title
            : String(format: String(localized: "%lld new build(s) on Apple Developer"), fresh.count)
        content.body = fresh.count == 1
            ? String(format: String(localized: "Build %1$@ — %2$lld restore image(s)."),
                     fresh[0].build, fresh[0].firmwares.count)
            : fresh.map(\.title).joined(separator: ", ")
        content.sound = .default
        // One thread, so several of these stack rather than pile up.
        content.threadIdentifier = "portal"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
