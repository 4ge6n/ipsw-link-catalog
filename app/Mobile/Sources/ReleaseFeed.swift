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

/// When the next build might come, from how far apart the last ones were.
///
/// A guess and labelled as one: the median gap between recent builds, added
/// to the last one, with the middle half of those gaps as the range. Apple
/// announces nothing in advance and this knows nothing it does not show.
struct Forecast {
    let title: String
    let expected: Date
    let earliest: Date
    let latest: Date
    /// How many gaps it was worked out from, and the typical one.
    let samples: Int
    let typicalDays: Int
    let after: ReleaseFeed.Entry

    var overdue: Bool { expected < Calendar.current.startOfDay(for: .now) }

    /// Gaps between distinct days, newest last; `limit` of them at most, and
    /// none longer than `cap` (a quiet summer between cycles is not a gap
    /// between betas).
    static func gaps(_ days: [Date], limit: Int, cap: Int?) -> [Int] {
        let calendar = Calendar.current
        let sorted = Array(Set(days.map { calendar.startOfDay(for: $0) })).sorted()
        var gaps: [Int] = []
        for (one, next) in zip(sorted, sorted.dropFirst()) {
            let days = calendar.dateComponents([.day], from: one, to: next).day ?? 0
            if days <= 0 { continue }
            if let cap, days > cap { continue }
            gaps.append(days)
        }
        return Array(gaps.suffix(limit))
    }

    /// Friday to Sunday moved on to the Monday. Apple ships Monday to
    /// Thursday almost every time — 97% of iOS builds since 2019, Monday most
    /// of all — so a median that lands on a weekend is a day nobody expects.
    static func onAWorkingDay(_ date: Date) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let weekday = calendar.component(.weekday, from: date) // 1 = Sunday
        let shift = [1: 1, 6: 3, 7: 2][weekday] ?? 0
        return calendar.date(byAdding: .day, value: shift, to: date) ?? date
    }

    static func make(title: String, after: ReleaseFeed.Entry, gaps: [Int]) -> Forecast? {
        guard gaps.count >= 4, let last = after.release.releasedAt else { return nil }
        let sorted = gaps.sorted()
        func quantile(_ q: Double) -> Int {
            let position = q * Double(sorted.count - 1)
            let low = Int(position.rounded(.down)), high = Int(position.rounded(.up))
            return Int((Double(sorted[low]) + (Double(sorted[high]) - Double(sorted[low])) * (position - Double(low))).rounded())
        }
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: last)
        func plus(_ days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: day) ?? day }
        return Forecast(title: title, expected: onAWorkingDay(plus(quantile(0.5))),
                        earliest: onAWorkingDay(plus(quantile(0.25))),
                        latest: onAWorkingDay(plus(quantile(0.75))), samples: gaps.count,
                        typicalDays: quantile(0.5), after: after)
    }
}

extension ReleaseFeed {
    /// The next release and the next beta for one platform, where there is
    /// enough history to say anything.
    func forecast(for platform: Platform) -> (release: Forecast?, beta: Forecast?) {
        let mine = entries.filter { $0.platform == platform && $0.release.releasedAt != nil }
        let releases = mine.filter { $0.channel == .release && $0.release.prerelease == nil }
            .sorted { ($0.release.releasedAt ?? .distantPast) < ($1.release.releasedAt ?? .distantPast) }
        let betas = mine.filter { $0.release.prerelease != nil }
            .sorted { ($0.release.releasedAt ?? .distantPast) < ($1.release.releasedAt ?? .distantPast) }

        var release: Forecast?
        if let last = releases.last {
            release = Forecast.make(title: String(localized: "Next release"), after: last,
                                    gaps: Forecast.gaps(releases.compactMap(\.release.releasedAt), limit: 12, cap: nil))
        }
        var beta: Forecast?
        if let last = betas.last {
            // The number that comes next, when the track is still open: a
            // beta after beta 2 is beta 3. After an RC, or once that version
            // has shipped, what comes next is not something to number.
            var title = String(localized: "Next beta")
            let shipped = releases.contains { $0.release.version == last.release.version }
            if !shipped, last.release.stage.rank == 0 {
                title = "\(last.release.version) beta \(last.release.stage.number + 1)"
            }
            beta = Forecast.make(title: title, after: last,
                                 gaps: Forecast.gaps(betas.compactMap(\.release.releasedAt), limit: 10, cap: 45))
        }
        return (release, beta)
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
