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
    var showInDock: Bool { didSet { write(showInDock, "showInDock"); applyPresentation() } }
    var showInMenuBar: Bool { didSet { write(showInMenuBar, "showInMenuBar") } }

    /// With neither shown the app is invisible while it runs; opening it again
    /// from Finder is what brings the window back.
    var isHidden: Bool { !showInDock && !showInMenuBar }

    func applyPresentation() {
        NSApp?.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    private var folderBookmarks: [String: Data] { didSet { write(folderBookmarks, "folders") } }

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
        showInDock = defaults.object(forKey: "showInDock") as? Bool ?? true
        showInMenuBar = defaults.object(forKey: "showInMenuBar") as? Bool ?? true
        folderBookmarks = defaults.dictionary(forKey: "folders") as? [String: Data] ?? [:]
    }

    /// Folders are kept as security-scoped bookmarks so access survives a relaunch.
    /// A path in the environment overrides one, for running without the interface.
    func folder(for platform: Platform) -> URL? {
        let variable = platform == .ios ? "IPSW_FOLDER_IOS" : "IPSW_FOLDER_IPADOS"
        if let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty {
            return URL(filePath: path)
        }
        guard let data = folderBookmarks[platform.rawValue] else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return url
    }

    func setFolder(_ url: URL?, for platform: Platform) {
        guard let url else { folderBookmarks[platform.rawValue] = nil; return }
        folderBookmarks[platform.rawValue] = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
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
