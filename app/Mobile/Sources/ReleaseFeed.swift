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
        // Japan's day: a build out at ten in Cupertino arrives the next
        // morning here, and is listed on the day it arrived.
        let calendar = Clocks.japan
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

/// Two clocks. Apple's — Cupertino, where a build comes out at about ten in
/// the morning — for working out what day something happened and which
/// weekday it fell on; and Japan's, for showing it, where that same build
/// arrives at two or three the next morning.
enum Clocks {
    static let apple: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()
    static let japan: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    /// A day in Cupertino, as the moment Apple usually publishes on it.
    static func publishing(on day: Date) -> Date {
        apple.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day
    }

    /// Dates shown in Japan time, whatever the phone is set to.
    static func japanese(_ style: Date.FormatStyle) -> Date.FormatStyle {
        var style = style
        style.timeZone = japan.timeZone
        style.calendar = japan
        return style
    }
}

/// One reason to expect a build on a given day, and how much it counts.
struct Signal: Identifiable {
    let id = UUID()
    /// What it is, in a phrase: "26.2, 18.2, 17.2: beta 2 → beta 3 took 6 days".
    let reason: String
    let date: Date
    let weight: Double
}

/// When the next build might come.
///
/// Not one rule but several, each a reason with a weight: how far apart this
/// track's own builds have been; how long the same step took in the same
/// slot in past years (x.2 beta 2 to beta 3); where the same build fell in
/// past years, when this year's cycle runs to the same calendar; and how
/// long a version takes from first beta to release. They are combined as a
/// weighted median, moved off Cupertino's Friday-to-Sunday and its holidays,
/// and shown in Japan time. Every reason is listed with the day it points
/// to, so the estimate can be checked rather than taken on trust. Apple
/// announces nothing in advance and this knows nothing it does not show.
struct Forecast: Identifiable {
    enum Kind: Hashable {
        /// A shipping build, of whatever version.
        case release
        /// A version's release, worked out from where its betas have got to.
        case versionRelease(String)
        /// The next build of a beta track already open — 27.2 beta 3.
        case beta(track: String)
        /// The first beta of a version not yet begun.
        case newVersion
    }

    let kind: Kind
    let title: String
    let expected: Date
    let earliest: Date
    let latest: Date
    let signals: [Signal]
    /// Something worth saying about what was left out, and why.
    let note: String?
    let after: ReleaseFeed.Entry

    var id: String {
        switch kind {
        case .release: "release"
        case .versionRelease(let v): "release-\(v)"
        case .beta(let track): "beta-\(track)"
        case .newVersion: "new"
        }
    }

    var overdue: Bool {
        Clocks.apple.startOfDay(for: expected) < Clocks.apple.startOfDay(for: .now)
    }

    /// Gaps in days between distinct Cupertino days, newest last.
    static func gaps(_ moments: [Date], limit: Int, cap: Int?) -> [Int] {
        let calendar = Clocks.apple
        let days = Array(Set(moments.map { calendar.startOfDay(for: $0) })).sorted()
        var gaps: [Int] = []
        for (one, next) in zip(days, days.dropFirst()) {
            let span = calendar.dateComponents([.day], from: one, to: next).day ?? 0
            if span <= 0 { continue }
            if let cap, span > cap { continue }
            gaps.append(span)
        }
        return Array(gaps.suffix(limit))
    }

    static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle] + 1) / 2 : sorted[middle]
    }

    static func days(from one: Date, to other: Date) -> Int {
        Clocks.apple.dateComponents([.day], from: Clocks.apple.startOfDay(for: one),
                                    to: Clocks.apple.startOfDay(for: other)).day ?? 0
    }

    /// That many Cupertino days on, at the hour Apple publishes — so the
    /// day a reason points to reads the same as the forecast it feeds, both
    /// in Japan time.
    static func adding(_ days: Int, to date: Date) -> Date {
        Clocks.publishing(on: Clocks.apple.date(byAdding: .day, value: days, to: Clocks.apple.startOfDay(for: date)) ?? date)
    }

    /// A day Apple would plausibly publish on. Friday to Sunday in Cupertino
    /// moves to the Monday — 97% of iOS builds since 2019 came Monday to
    /// Thursday — and so do the US Thanksgiving Thursday and Friday and the
    /// last week of December, when Apple has not shipped.
    static func publishable(_ day: Date) -> Date {
        let calendar = Clocks.apple
        var day = calendar.startOfDay(for: day)
        for _ in 0..<14 {
            let weekday = calendar.component(.weekday, from: day) // 1 = Sunday
            let month = calendar.component(.month, from: day)
            let date = calendar.component(.day, from: day)
            let thanksgiving = month == 11 && (weekday == 5 || weekday == 6) && (22...29).contains(date - (weekday == 6 ? 1 : 0))
            let yearEnd = (month == 12 && date >= 23) || (month == 1 && date <= 1)
            if (2...5).contains(weekday) && !thanksgiving && !yearEnd { break }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        }
        return Clocks.publishing(on: day)
    }

    /// Weighted quantile of the signals' days.
    static func quantile(_ signals: [Signal], _ q: Double) -> Date? {
        let sorted = signals.sorted { $0.date < $1.date }
        let total = sorted.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        var running = 0.0
        for signal in sorted {
            running += signal.weight
            if running / total >= q { return signal.date }
        }
        return sorted.last?.date
    }

    static func combine(_ kind: Kind, title: String, signals: [Signal], note: String?,
                        after: ReleaseFeed.Entry) -> Forecast? {
        let usable = signals.filter { $0.weight > 0 }
        guard !usable.isEmpty, let middle = quantile(usable, 0.5),
              let low = quantile(usable, 0.25), let high = quantile(usable, 0.75) else { return nil }
        return Forecast(kind: kind, title: title, expected: publishable(middle),
                        earliest: publishable(low), latest: publishable(high),
                        signals: usable.sorted { $0.weight > $1.weight }, note: note, after: after)
    }
}

/// "27.2" as numbers, for finding the same slot in past years.
struct VersionSlot: Hashable {
    let major: Int
    let minor: Int
    let patch: Int?

    init?(_ version: String) {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        major = parts[0]; minor = parts[1]; patch = parts.count > 2 ? parts[2] : nil
    }
}

extension ReleaseFeed {
    /// Everything there is to say about what comes next for a platform.
    struct Outlook {
        var release: Forecast?
        var versionReleases: [Forecast] = []
        /// One per beta track still open. Two can run at once — 26.6
        /// alongside 27.0 — and each is worked out from its own builds and
        /// its own slot only, so neither is mistaken for the other.
        var tracks: [Forecast] = []
        var newVersion: Forecast?
        var all: [Forecast] {
            [release].compactMap { $0 } + versionReleases + tracks + [newVersion].compactMap { $0 }
        }
    }

    private func dated(_ platform: Platform) -> [Entry] {
        entries.filter { $0.platform == platform && $0.release.releasedAt != nil }
            .sorted { ($0.release.releasedAt ?? .distantPast) < ($1.release.releasedAt ?? .distantPast) }
    }

    /// Betas grouped by the version they lead up to, oldest track first.
    func betaTracks(for platform: Platform) -> [(version: String, builds: [Entry])] {
        var byVersion: [String: [Entry]] = [:]
        var seen = Set<String>()
        for entry in dated(platform) where entry.release.prerelease != nil {
            guard seen.insert(entry.release.build).inserted else { continue }
            byVersion[entry.release.version, default: []].append(entry)
        }
        return byVersion.map { ($0.key, $0.value) }
            .sorted { ($0.builds.first?.release.releasedAt ?? .distantPast) < ($1.builds.first?.release.releasedAt ?? .distantPast) }
    }

    func releases(for platform: Platform) -> [Entry] {
        var seen = Set<String>()
        return dated(platform).filter { $0.release.prerelease == nil && seen.insert($0.release.build).inserted }
    }

    func outlook(for platform: Platform) -> Outlook {
        var outlook = Outlook()
        let shipped = releases(for: platform)
        let shippedAt: [String: Date] = Dictionary(shipped.compactMap { entry in
            entry.release.releasedAt.map { (entry.release.version, $0) } }, uniquingKeysWith: { first, _ in first })
        let tracks = betaTracks(for: platform)
        let byVersion = Dictionary(tracks.map { ($0.version, $0.builds) }, uniquingKeysWith: { first, _ in first })
        // Majors that exist, in order: iOS went from 18 to 26, so "last year"
        // is the major before in the data, not the number before.
        let majors = Array(Set(tracks.compactMap { VersionSlot($0.version)?.major }
                               + shipped.compactMap { VersionSlot($0.release.version)?.major })).sorted()
        func earlier(than major: Int) -> [Int] { Array(majors.filter { $0 < major }.suffix(4)) }
        func years(_ from: Int, _ to: Int) -> Int {
            // A major is a year; the gap in years is the gap in place.
            (majors.firstIndex(of: to) ?? 0) - (majors.firstIndex(of: from) ?? 0)
        }
        func atDate(_ entry: Entry?) -> Date? { entry?.release.releasedAt }
        func stageOf(_ entry: Entry) -> (rank: Int, number: Int) { entry.release.stage }

        let now = Date.now

        // MARK: Each open beta track
        for track in tracks.reversed() {
            guard shippedAt[track.version] == nil, let slot = VersionSlot(track.version), slot.patch == nil,
                  let last = track.builds.last, let lastAt = last.release.releasedAt,
                  let firstAt = track.builds.first?.release.releasedAt,
                  now.timeIntervalSince(lastAt) < 60 * 86_400 else { continue }
            let step = stageOf(last)
            var signals: [Signal] = []
            var note: String?

            // How many betas this slot usually has, to tell beta n+1 from RC.
            var pastBetaCounts: [Int] = []
            var slotGaps: [(String, Int)] = []
            var seasonal: [(String, Date)] = []
            var aligned = true
            for major in earlier(than: slot.major) {
                let name = "\(major).\(slot.minor)"
                guard let past = byVersion[name], let pastFirst = atDate(past.first) else { continue }
                pastBetaCounts.append(past.filter { stageOf($0).rank == 0 }.map { stageOf($0).number }.max() ?? 0)
                // The same step: from the build at this stage to the one after.
                if let index = past.firstIndex(where: { stageOf($0).rank == step.rank && stageOf($0).number == step.number }),
                   index + 1 < past.count, let a = atDate(past[index]), let b = atDate(past[index + 1]) {
                    slotGaps.append((name, Forecast.days(from: a, to: b)))
                    // The same build a year on — only if this year's cycle
                    // started at the same time of year as that one.
                    let shift = years(major, slot.major)
                    let thisYear = Clocks.apple.date(byAdding: .year, value: shift, to: b) ?? b
                    let offset = Forecast.days(from: Clocks.apple.date(byAdding: .year, value: shift, to: pastFirst) ?? pastFirst, to: firstAt)
                    if abs(offset) <= 14 { seasonal.append((name, thisYear)) } else { aligned = false }
                }
            }
            let likelyBetas = Forecast.median(pastBetaCounts) ?? 0
            let nextIsRC = step.rank == 0 && likelyBetas > 0 && step.number >= likelyBetas
            let title = step.rank == 0
                ? (nextIsRC ? "\(track.version) RC" : "\(track.version) beta \(step.number + 1)")
                : String(format: String(localized: "%@: next build after the RC"), track.version)

            let own = Forecast.gaps(track.builds.compactMap(\.release.releasedAt), limit: 10, cap: 45)
            if let gap = Forecast.median(own) {
                signals.append(Signal(reason: String(format: String(localized: "This track so far: every %lld days"), gap),
                                      date: Forecast.adding(gap, to: lastAt), weight: Double(min(own.count, 3))))
            }
            if let gap = Forecast.median(slotGaps.map(\.1)) {
                signals.append(Signal(reason: String(format: String(localized: "Same step in %1$@: %2$lld days"),
                                                     slotGaps.map(\.0).joined(separator: ", "), gap),
                                      date: Forecast.adding(gap, to: lastAt), weight: slotGaps.count >= 2 ? 3 : 1.5))
            }
            for (name, date) in seasonal {
                signals.append(Signal(reason: String(format: String(localized: "Same build in %@, a year on"), name),
                                      date: date, weight: 1))
            }
            if !aligned && !slotGaps.isEmpty {
                note = String(localized: "This cycle started at a different time of year from past ones, so the calendar of past years is not used.")
            }
            if let forecast = Forecast.combine(.beta(track: track.version), title: title,
                                               signals: signals, note: note, after: last) {
                outlook.tracks.append(forecast)
            }

            // The release of this version: how long the slot took from its
            // first beta to release in past years.
            var durations: [(String, Int)] = []
            var releaseSeasonal: [(String, Date)] = []
            for major in earlier(than: slot.major) {
                let name = "\(major).\(slot.minor)"
                guard let pastFirst = atDate(byVersion[name]?.first), let pastRelease = shippedAt[name] else { continue }
                durations.append((name, Forecast.days(from: pastFirst, to: pastRelease)))
                let shift = years(major, slot.major)
                let offset = Forecast.days(from: Clocks.apple.date(byAdding: .year, value: shift, to: pastFirst) ?? pastFirst, to: firstAt)
                if abs(offset) <= 14 {
                    releaseSeasonal.append((name, Clocks.apple.date(byAdding: .year, value: shift, to: pastRelease) ?? pastRelease))
                }
            }
            var releaseSignals: [Signal] = []
            if let span = Forecast.median(durations.map(\.1)) {
                releaseSignals.append(Signal(reason: String(format: String(localized: "%1$@ took %2$lld days from beta 1 to release"),
                                                            durations.map(\.0).joined(separator: ", "), span),
                                             date: Forecast.adding(span, to: firstAt), weight: 3))
            }
            for (name, date) in releaseSeasonal {
                releaseSignals.append(Signal(reason: String(format: String(localized: "%@ released at this time of year"), name),
                                             date: date, weight: 1))
            }
            if let forecast = Forecast.combine(.versionRelease(track.version),
                                               title: String(format: String(localized: "%@ release"), track.version),
                                               signals: releaseSignals,
                                               note: releaseSeasonal.isEmpty && !durations.isEmpty
                                                ? String(localized: "This cycle started at a different time of year from past ones, so the calendar of past years is not used.") : nil,
                                               after: last) {
                outlook.versionReleases.append(forecast)
            }
        }

        // MARK: The next release of any kind
        if let last = shipped.last, let lastAt = last.release.releasedAt {
            var signals: [Signal] = []
            let recent = Forecast.gaps(shipped.compactMap(\.release.releasedAt), limit: 12, cap: nil)
            if let gap = Forecast.median(recent) {
                signals.append(Signal(reason: String(format: String(localized: "Recent releases: every %lld days"), gap),
                                      date: Forecast.adding(gap, to: lastAt), weight: 1.5))
            }
            // Past years: the first release after this same day of the year.
            if let current = VersionSlot(last.release.version)?.major {
                var gaps: [(Int, Int)] = []
                for major in earlier(than: current) {
                    let shift = years(major, current)
                    guard let then = Clocks.apple.date(byAdding: .year, value: -shift, to: lastAt) else { continue }
                    if let following = shipped.first(where: { ($0.release.releasedAt ?? .distantPast) > Forecast.adding(1, to: then) }),
                       let at = following.release.releasedAt {
                        gaps.append((major, Forecast.days(from: then, to: at)))
                    }
                }
                if let gap = Forecast.median(gaps.map(\.1)) {
                    signals.append(Signal(reason: String(format: String(localized: "Past years after this date: %lld days"), gap),
                                          date: Forecast.adding(gap, to: lastAt), weight: Double(min(gaps.count, 3))))
                }
            }
            // A version whose release is due sooner bounds the next release.
            if let soonest = outlook.versionReleases.min(by: { $0.expected < $1.expected }) {
                signals.append(Signal(reason: String(format: String(localized: "%@ is due"), soonest.title),
                                      date: soonest.expected, weight: 1))
            }
            outlook.release = Forecast.combine(.release, title: String(localized: "Next release"),
                                               signals: signals, note: nil, after: last)
        }

        // MARK: A new version's first beta
        let cycles = tracks.filter { $0.builds.count >= 2 && VersionSlot($0.version)?.patch == nil }
        if let newest = cycles.last, let slot = VersionSlot(newest.version), let firstAt = atDate(newest.builds.first) {
            var signals: [Signal] = []
            var spacing: [(String, Int)] = []
            var seasonal: [(String, Date)] = []
            var aligned = true
            for major in earlier(than: slot.major) {
                let this = "\(major).\(slot.minor)", next = "\(major).\(slot.minor + 1)"
                guard let a = atDate(byVersion[this]?.first), let b = atDate(byVersion[next]?.first) else { continue }
                spacing.append((next, Forecast.days(from: a, to: b)))
                let shift = years(major, slot.major)
                let offset = Forecast.days(from: Clocks.apple.date(byAdding: .year, value: shift, to: a) ?? a, to: firstAt)
                if abs(offset) <= 14 {
                    seasonal.append((next, Clocks.apple.date(byAdding: .year, value: shift, to: b) ?? b))
                } else { aligned = false }
            }
            if let gap = Forecast.median(spacing.map(\.1)) {
                signals.append(Signal(reason: String(format: String(localized: "%1$@ beta 1 came %2$lld days after the one before"),
                                                     spacing.map(\.0).joined(separator: ", "), gap),
                                      date: Forecast.adding(gap, to: firstAt), weight: 3))
            }
            for (name, date) in seasonal {
                signals.append(Signal(reason: String(format: String(localized: "%@ beta 1 at this time of year"), name),
                                      date: date, weight: 1))
            }
            let firsts = Forecast.gaps(cycles.compactMap { atDate($0.builds.first) }, limit: 8, cap: nil)
            if let gap = Forecast.median(firsts) {
                signals.append(Signal(reason: String(format: String(localized: "Recent first betas: every %lld days"), gap),
                                      date: Forecast.adding(gap, to: firstAt), weight: 1))
            }
            let title = spacing.isEmpty ? String(localized: "First beta of a new version")
                                        : "\(slot.major).\(slot.minor + 1) beta 1"
            outlook.newVersion = Forecast.combine(.newVersion, title: title, signals: signals,
                                                  note: !aligned ? String(localized: "This cycle started at a different time of year from past ones, so the calendar of past years is not used.") : nil,
                                                  after: newest.builds[0])
        }
        return outlook
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
