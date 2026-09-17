import Foundation

/// Apple's own releases feed — the announcement, not the download.
///
/// It is eighteen kilobytes, needs no account, and names every build Apple
/// ships the moment it ships: "iOS 27.2 beta (24B5084k)". No link, no
/// checksum, nothing but the name — but it is the first place a build is ever
/// mentioned, so it is what decides that there is something to go and look for.
struct AppleFeed {
    var source = ProcessInfo.processInfo.environment["IPSW_RELEASES_FEED"].flatMap(URL.init(string:))
        ?? URL(string: "https://developer.apple.com/news/releases/rss/releases.rss")!
    var session: URLSession = .shared

    /// One line of the feed that names a build this app cares about.
    struct Announcement: Sendable, Hashable {
        let platform: Platform
        let version: String
        let build: String
        let prerelease: String?
        let at: Date

        var isBeta: Bool { prerelease != nil }
        /// The same shape a portal entry uses, so the two can be compared.
        var id: String { "\(platform.rawValue)-\(version)-\(build)" }
        var title: String {
            [platform.title, version, prerelease].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// What Apple has announced lately, newest first. Only iOS and iPadOS: the
    /// feed carries Xcode and TestFlight and every other platform as well.
    func announcements() async throws -> [Announcement] {
        var request = URLRequest(url: source)
        // Apple lets this sit in a cache for five minutes, and asking more often
        // than that answers out of the same cache anyway.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let feed = String(data: data, encoding: .utf8) else {
            throw SyncError.feedUnavailable
        }
        return parse(feed).sorted { $0.at > $1.at }
    }

    func parse(_ feed: String) -> [Announcement] {
        var found: [Announcement] = []
        for block in Self.item.captures(in: feed) {
            guard let heading = Self.title.captures(in: block).first,
                  let posted = Self.posted.captures(in: block).first,
                  let at = Self.moment(from: posted.trimmingCharacters(in: .whitespacesAndNewlines))
            else { continue }
            let text = heading.trimmingCharacters(in: .whitespacesAndNewlines)
            let whole = NSRange(text.startIndex..., in: text)
            guard let match = Self.heading.firstMatch(in: text, range: whole),
                  let osRange = Range(match.range(at: 1), in: text),
                  let versionRange = Range(match.range(at: 2), in: text),
                  let buildRange = Range(match.range(at: 4), in: text),
                  let platform = Self.platform(String(text[osRange]))
            else { continue }
            let prerelease = Range(match.range(at: 3), in: text)
                .map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
            found.append(Announcement(platform: platform, version: String(text[versionRange]),
                                      build: String(text[buildRange]),
                                      prerelease: prerelease?.isEmpty == true ? nil : prerelease, at: at))
        }
        return found
    }

    /// "iOS 27.2 beta (24B5084k)", "iPadOS 27.0 (24A437)", and the release
    /// candidates, which Apple writes as "iOS 27.1 RC (24B82)".
    private static let heading = try! NSRegularExpression(
        pattern: #"^([A-Za-z]+)\s+([0-9][0-9.]*)((?:\s+(?:beta|RC|Release Candidate)[^()]*)?)\s*\(([A-Za-z0-9]+)\)$"#)

    private static let item = Pattern("<item>(.*?)</item>")
    private static let title = Pattern("<title>(.*?)</title>")
    private static let posted = Pattern("<pubDate>(.*?)</pubDate>")

    private static func platform(_ name: String) -> Platform? {
        switch name {
        case "iOS": .ios
        case "iPadOS": .ipados
        // macOS, tvOS, watchOS, visionOS, Xcode and the rest are announced here
        // too, and none of them is a folder this app keeps.
        default: nil
        }
    }

    /// Apple writes the zone as an abbreviation — "PDT" — which is zzz, not the
    /// numeric offset Z reads.
    private static func moment(from text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: text)
    }
}

/// A regular expression that is only ever asked for its first capture.
struct Pattern {
    private let expression: NSRegularExpression
    init(_ pattern: String) {
        expression = try! NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators)
    }
    func captures(in text: String) -> [String] {
        expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { range in String(text[range]) }
        }
    }
}
