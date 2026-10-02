import Foundation
import Observation

/// Every build of every platform the catalog carries, read once, for the
/// timeline and the per-device history.
///
/// The catalog tab reads one platform at a time; the screens here need all of
/// them side by side — what came out on a given day across iOS, iPadOS, tvOS
/// and the rest, and everything one device has ever been offered. Only what
/// the catalog actually holds is shown: a build with no restore image (an
/// OTA-only one) is not in it, and is not invented here.
@MainActor
@Observable
final class ReleaseFeed {
    struct Entry: Identifiable, Hashable {
        let platform: Platform
        let channel: Channel
        let release: Release
        var id: String { "\(platform.rawValue)-\(release.id)" }
    }

    /// One day's builds, grouped by platform, newest day first.
    struct Day: Identifiable {
        let date: Date
        let groups: [(platform: Platform, entries: [Entry])]
        var id: Date { date }
    }

    /// One build as one device sees it.
    struct DeviceBuild: Identifiable, Hashable {
        let entry: Entry
        let firmware: Firmware
        var id: String { "\(entry.id)-\(firmware.id)" }
    }

    private(set) var entries: [Entry] = []
    private(set) var loading = false
    private(set) var failure: String?
    var includeBetas = UserDefaults.standard.bool(forKey: "feedIncludesBetas") {
        didSet { UserDefaults.standard.set(includeBetas, forKey: "feedIncludesBetas") }
    }

    /// The catalogs there are. iPod lives inside iOS's.
    static let platforms: [Platform] = [.ios, .ipados, .tvos, .audioos, .visionos, .macos]

    private let engine = SyncEngine()

    func load() async {
        guard !loading else { return }
        loading = true
        failure = nil
        defer { loading = false }
        var found: [Entry] = []
        var problems: [String] = []
        await withTaskGroup(of: (Platform, Channel, Result<[Release], Error>).self) { group in
            for platform in Self.platforms {
                for channel in Channel.allCases {
                    group.addTask { [engine] in
                        do { return (platform, channel, .success(try await engine.everyBuild(platform, channel: channel))) }
                        catch { return (platform, channel, .failure(error)) }
                    }
                }
            }
            for await (platform, channel, result) in group {
                switch result {
                case .success(let releases):
                    found += releases.map { Entry(platform: platform, channel: channel, release: $0) }
                case .failure(let error):
                    // A platform with no betas at all answers with nothing, not
                    // an error worth showing; a release catalog failing is.
                    if channel == .release { problems.append("\(platform.title): \(error.localizedDescription)") }
                }
            }
        }
        entries = found
        failure = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    private var shown: [Entry] {
        entries.filter { includeBetas || $0.channel == .release }
    }

    /// The timeline: days that saw a build, newest first. A build with no
    /// date is left out rather than placed on a day it did not come out.
    var days: [Day] {
        let calendar = Calendar.current
        var byDay: [Date: [Entry]] = [:]
        for entry in shown {
            guard let at = entry.release.releasedAt else { continue }
            byDay[calendar.startOfDay(for: at), default: []].append(entry)
        }
        return byDay.keys.sorted(by: >).map { day in
            let entries = byDay[day] ?? []
            let groups = Self.platforms.compactMap { platform -> (Platform, [Entry])? in
                let mine = entries.filter { $0.platform == platform }
                    .sorted { Release.newestFirst($0.release, $1.release) }
                return mine.isEmpty ? nil : (platform, mine)
            }
            return Day(date: day, groups: groups)
        }
    }

    /// Everything one device has been offered, newest first.
    func history(of identifier: String) -> [DeviceBuild] {
        var seen = Set<String>()
        var builds: [DeviceBuild] = []
        for entry in shown {
            for firmware in entry.release.firmwares where firmware.devices.contains(identifier) {
                // The same file can be listed twice across tracks.
                guard seen.insert(firmware.url.absoluteString).inserted else { continue }
                builds.append(DeviceBuild(entry: entry, firmware: firmware))
            }
        }
        return builds.sorted { Release.newestFirst($0.entry.release, $1.entry.release) }
    }

    /// Every device the catalog knows, by platform, newest first.
    var devices: [(platform: Platform, identifiers: [String])] {
        var found: [Platform: Set<String>] = [:]
        for entry in entries {
            for firmware in entry.release.firmwares {
                for device in firmware.devices {
                    let platform = Platform.allCases.first { device.hasPrefix($0.prefix) } ?? entry.platform
                    found[platform, default: []].insert(device)
                }
            }
        }
        return Platform.allCases.compactMap { platform -> (platform: Platform, identifiers: [String])? in
            guard let ids = found[platform], !ids.isEmpty else { return nil }
            return (platform, ids.sorted { Self.ordering($1).lexicographicallyPrecedes(Self.ordering($0)) })
        }
    }

    /// iPhone19,7 above iPhone19,2 above iPhone18,5: by the numbers, not the text.
    private static func ordering(_ identifier: String) -> [Int] {
        identifier.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    /// The newest build Apple is known to sign for a device, if any.
    func newestSigned(_ identifier: String) -> DeviceBuild? {
        history(of: identifier).first { $0.firmware.signed == true }
    }
}

extension Release {
    /// "27.0.1", "27.2 beta 2"
    var displayVersion: String {
        prerelease.map { "\(version) \($0)" } ?? version
    }
}

/// What Apple calls each device. The same table the pipeline publishes from,
/// carried with the app so an iPad that only ever shares an image with three
/// others still has a name of its own.
enum DeviceNames {
    private static let table: [String: String] = {
        guard let url = Bundle.main.url(forResource: "device-names", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let names = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return names
    }()

    static func name(_ identifier: String) -> String { table[identifier] ?? identifier }
}

/// Devices starred to keep at hand on the first tab.
@MainActor
@Observable
final class Favorites {
    static let shared = Favorites()
    private(set) var identifiers: [String] = UserDefaults.standard.stringArray(forKey: "favoriteDevices") ?? []

    func contains(_ identifier: String) -> Bool { identifiers.contains(identifier) }

    func toggle(_ identifier: String) {
        if let index = identifiers.firstIndex(of: identifier) {
            identifiers.remove(at: index)
        } else {
            identifiers.append(identifier)
        }
        UserDefaults.standard.set(identifiers, forKey: "favoriteDevices")
    }
}
