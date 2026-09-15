import AppKit
import Foundation
import SwiftUI

/// Everything the app remembers between launches.
@Observable
final class Settings {
    static let shared = Settings()

    var selectedDevices: Set<String> { didSet { write(Array(selectedDevices).sorted(), "devices") } }
    var prune: Bool { didSet { write(prune, "prune") } }
    /// Typed by hand, so it is held to something a connection can actually do.
    var maxConcurrent: Int {
        didSet {
            let held = min(max(maxConcurrent, 1), 16)
            if held != maxConcurrent { maxConcurrent = held; return }
            write(maxConcurrent, "maxConcurrent")
        }
    }
    var scheduleEnabled: Bool { didSet { write(scheduleEnabled, "scheduleEnabled") } }
    var hour: Int { didSet { write(hour, "hour") } }
    var minute: Int { didSet { write(minute, "minute") } }
    var lastRun: Date? { didSet { write(lastRun, "lastRun") } }
    var autoUpdate: Bool { didSet { write(autoUpdate, "autoUpdate") } }
    var hasLaunchedBefore: Bool { didSet { write(hasLaunchedBefore, "hasLaunchedBefore") } }
    var lastUpdateCheck: Date? { didSet { write(lastUpdateCheck, "lastUpdateCheck") } }
    var language: Language { didSet { write(language.rawValue, "language"); applyLanguage() } }
    var showInDock: Bool { didSet { write(showInDock, "showInDock"); applyPresentation() } }
    var showInMenuBar: Bool { didSet { write(showInMenuBar, "showInMenuBar") } }

    /// With neither shown the app is invisible while it runs; opening it again
    /// from Finder is what brings the window back.
    var isHidden: Bool { !showInDock && !showInMenuBar }

    /// Opening the app again is a request to be seen, so both switches go back
    /// on together. Turning either one off is how it leaves again.
    func comeBack() {
        showInDock = true
        showInMenuBar = true
    }

    /// AppKit reads the language it draws menus and panels in once, at launch,
    /// so this is written for the next one rather than applied to this.
    func applyLanguage() {
        if let code = language.code {
            defaults.set([code], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }

    /// Whether the app is already drawing in the language that is set.
    var languageIsCurrent: Bool {
        guard let wanted = language.code else {
            // Read this app's own domain: the global one names a language on
            // nearly every Mac, and that is not the app having been told.
            let mine = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) }
            return mine?["AppleLanguages"] == nil
        }
        return Bundle.main.preferredLocalizations.first?.hasPrefix(wanted) ?? false
    }

    func applyPresentation() {
        NSApp?.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    private var folderBookmarks: [String: Data] { didSet { write(folderBookmarks, "folders"); resolved = [:] } }
    /// Resolving a bookmark asks the system to find the volume it names, which
    /// on a Mac that has never seen that drive takes seconds. Views read this
    /// on every redraw, so it is resolved once and remembered.
    private var resolved: [String: URL?] = [:]

    private let defaults = UserDefaults.standard
    private func write<T>(_ value: T?, _ key: String) { defaults.set(value, forKey: key) }

    private init() {
        let defaults = UserDefaults.standard
        selectedDevices = Set(defaults.stringArray(forKey: "devices") ?? [])
        prune = defaults.object(forKey: "prune") as? Bool ?? true
        maxConcurrent = min(max(defaults.object(forKey: "maxConcurrent") as? Int ?? 3, 1), 16)
        scheduleEnabled = defaults.bool(forKey: "scheduleEnabled")
        hour = defaults.object(forKey: "hour") as? Int ?? 4
        minute = defaults.object(forKey: "minute") as? Int ?? 0
        lastRun = defaults.object(forKey: "lastRun") as? Date
        autoUpdate = defaults.object(forKey: "autoUpdate") as? Bool ?? true
        hasLaunchedBefore = defaults.bool(forKey: "hasLaunchedBefore")
        lastUpdateCheck = defaults.object(forKey: "lastUpdateCheck") as? Date
        language = Language(rawValue: defaults.string(forKey: "language") ?? "") ?? .system
        showInDock = defaults.object(forKey: "showInDock") as? Bool ?? true
        showInMenuBar = defaults.object(forKey: "showInMenuBar") as? Bool ?? true
        folderBookmarks = defaults.dictionary(forKey: "folders") as? [String: Data] ?? [:]
    }

    /// Folders are kept as security-scoped bookmarks so access survives a relaunch.
    /// A path in the environment overrides one, for running without the interface.
    func folder(for platform: Platform) -> URL? {
        let variable = switch platform {
        case .ios: "IPSW_FOLDER_IOS"
        case .ipados: "IPSW_FOLDER_IPADOS"
        case .ipod: "IPSW_FOLDER_IPOD"
        }
        if let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty {
            return URL(filePath: path)
        }
        if let known = resolved[platform.rawValue] { return known }
        guard let data = folderBookmarks[platform.rawValue] else { return nil }
        var stale = false
        // withoutMounting: a bookmark naming a drive that is not attached must
        // come back empty rather than send the system looking for it.
        let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutMounting],
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        resolved[platform.rawValue] = url
        return url
    }

    /// Changes whenever a folder is chosen, so a view can watch for it without
    /// resolving a bookmark to compare.
    private(set) var folderMark = 0

    func setFolder(_ url: URL?, for platform: Platform) {
        defer { folderMark += 1 }
        guard let url else { folderBookmarks[platform.rawValue] = nil; return }
        folderBookmarks[platform.rawValue] = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// A copy installed a moment ago is not behind, and a launch is the worst
    /// time to add a request that can hang. Later launches check, but not more
    /// than a few times a day.
    func shouldCheckForUpdateAtLaunch(now: Date = .now) -> Bool {
        guard autoUpdate else { return false }
        guard hasLaunchedBefore else { return false }
        guard let lastUpdateCheck else { return true }
        return now.timeIntervalSince(lastUpdateCheck) > 6 * 60 * 60
    }

    /// When the next daily run is due, counting from a reference point.
    func nextRun(after moment: Date = .now) -> Date? {
        guard scheduleEnabled else { return nil }
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return Calendar.current.nextDate(after: moment, matching: components,
                                         matchingPolicy: .nextTime)
    }

    /// True when today's run was missed — the Mac was asleep or the app was not
    /// running — so it can be caught up instead of waiting another day.
    func missedRun(now: Date = .now) -> Bool {
        guard scheduleEnabled else { return false }
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        guard let due = Calendar.current.nextDate(after: now, matching: components,
                                                  matchingPolicy: .nextTime,
                                                  direction: .backward) else { return false }
        guard let lastRun else { return true }
        return lastRun < due
    }
}
