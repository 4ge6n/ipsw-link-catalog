import Foundation

/// One restore image, as the catalog publishes it.
struct Firmware: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let devices: [String]
    let filename: String
    let url: URL
    let sha1: String?
    let signed: Bool

    /// The same image, with a checksum that was found somewhere else.
    func checked(against sha1: String) -> Firmware {
        Firmware(id: id, name: name, devices: devices, filename: filename, url: url,
                 sha1: sha1, signed: signed)
    }

    /// iPhone18,5_27.0_24A437_Restore.ipsw and its other builds share this.
    var modelKey: String { Firmware.modelKey(of: filename) }

    /// The name without its version and build. iPad_Pro_M4_27.2_24B5084k and
    /// the same image for every other version share iPad_Pro_M4, which is what
    /// lets one build say what another one covers.
    static func modelKey(of filename: String) -> String {
        filename.replacing(#/_[0-9][^_]*_[A-Za-z0-9]+_Restore\.ipsw$/#, with: "")
    }

    /// The identifiers written into a filename, where there are any.
    ///
    /// iPhone19,2,iPhone19,3,iPhone19,7_27.2_24B5084k_Restore.ipsw is three
    /// devices in one image — Apple began combining the iPhone 18 Pro line at
    /// 27.2, having shipped one image each at 27.0 — and a name like
    /// iPad_Pro_M4_27.2_24B5084k_Restore.ipsw is none at all.
    static func devices(in filename: String) -> [String] {
        let head = modelKey(of: filename)
        return head.split(separator: ",").reduce(into: [String]()) { result, part in
            // The split breaks "iPhone19,2" in half; the number rejoins the name.
            if part.allSatisfy(\.isNumber), let last = result.last {
                result[result.count - 1] = "\(last),\(part)"
            } else {
                result.append(String(part))
            }
        }
        .filter { $0.contains(",") }
    }

    /// The highest identifier this image covers, as the three parts that
    /// order it. The highest rather than the first, so an image covering a
    /// whole generation sorts by the newest device in it.
    var modelNumber: (kind: String, major: Int, minor: Int) {
        let parts = devices.map(Firmware.parts(of:))
        let highest = parts.max { ($0.major, $0.minor) < ($1.major, $1.minor) }
        return highest ?? Firmware.parts(of: name)
    }

    /// iPhone18,5 → ("iPhone", 18, 5).
    private static func parts(of identifier: String) -> (kind: String, major: Int, minor: Int) {
        let kind = identifier.prefix { !$0.isNumber }
        let numbers = identifier.dropFirst(kind.count).split(separator: ",")
        return (String(kind),
                Int(numbers.first ?? "") ?? 0,
                Int(numbers.dropFirst().first ?? "") ?? 0)
    }

    /// Highest identifier first, kept together by the kind of device:
    /// iPhone18,5 before iPhone18,4 before iPhone18,3, then iPhone17,x, and
    /// the iPods after the iPhones. The identifier is what is being ordered,
    /// so it is the identifier that decides — not the name, which runs in an
    /// order of its own.
    static func newestFirst(_ one: Firmware, _ other: Firmware) -> Bool {
        let left = one.modelNumber, right = other.modelNumber
        if left.kind != right.kind { return left.kind < right.kind }
        if left.major != right.major { return left.major > right.major }
        if left.minor != right.minor { return left.minor > right.minor }
        return one.name.localizedStandardCompare(other.name) == .orderedAscending
    }
}

struct Release: Codable, Identifiable, Hashable {
    let id: String
    let version: String
    /// "26.0-beta-2", "26.0-rc", "26.0". Apple's own numbering of the build,
    /// as the catalog recorded it when the build was published — which is the
    /// only place it is written down, and is never guessed at here.
    let versionLabel: String?
    let build: String
    let releasedAt: Date?
    let firmwares: [Firmware]

    enum CodingKeys: String, CodingKey {
        case id, version, build, firmwares
        case versionLabel = "version_label"
        case releasedAt = "released_at"
    }

    init(id: String, version: String, versionLabel: String? = nil, build: String,
         releasedAt: Date?, firmwares: [Firmware]) {
        self.id = id
        self.version = version
        self.versionLabel = versionLabel
        self.build = build
        self.releasedAt = releasedAt
        self.firmwares = firmwares
    }

    /// What Apple called this build, without the version in front of it:
    /// "beta 2", "RC", and nothing at all for a build that shipped.
    ///
    /// A revision — Apple posting a second build under the same beta number,
    /// as it did with 23A5260N and 23A5260U — keeps that number. They are two
    /// builds of beta 1, not beta 1 and beta 2.
    var prerelease: String? {
        guard let versionLabel, versionLabel != version else { return nil }
        let tail = versionLabel.hasPrefix(version + "-")
            ? String(versionLabel.dropFirst(version.count + 1))
            : versionLabel
        guard !tail.isEmpty else { return nil }
        let text = tail
            .replacingOccurrences(of: "rc", with: "RC")
            .replacingOccurrences(of: "-", with: " ")
        // Apple writes the first one as "beta" and the next as "beta 2". In a
        // list of them that reads as a different kind of thing rather than as
        // the one before beta 2, so the number it has is the number shown.
        return text == "beta" ? "beta 1" : text
    }
}

struct Catalog: Codable {
    let os: String
    let osKey: String
    let generatedAt: Date
    let releases: [Release]

    enum CodingKeys: String, CodingKey {
        case os, releases
        case osKey = "os_key"
        case generatedAt = "generated_at"
    }

    /// iPod touch is published inside the iOS catalog, so each platform is given
    /// only the devices that are its own. A release left with nothing goes.
    func covering(_ platform: Platform) -> Catalog {
        let kept = releases.compactMap { release -> Release? in
            let firmwares = release.firmwares.filter(platform.covers)
            guard !firmwares.isEmpty else { return nil }
            return Release(id: release.id, version: release.version, build: release.build,
                           releasedAt: release.releasedAt, firmwares: firmwares)
        }
        return Catalog(os: os, osKey: osKey, generatedAt: generatedAt, releases: kept)
    }
}

/// The operating systems this app can keep a folder in step with.
enum Platform: String, CaseIterable, Identifiable, Codable {
    case ios, ipados, ipod, tvos, audioos, visionos, macos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ios: "iOS"
        case .ipados: "iPadOS"
        case .ipod: "iPod"
        case .tvos: "tvOS"
        // Apple ships this inside tvOS and has never given it a name of its
        // own in public, so it goes by the thing it runs on.
        case .audioos: "HomePod"
        case .visionos: "visionOS"
        case .macos: "macOS"
        }
    }

    /// An iPod touch runs iOS and Apple publishes it in the iOS catalog. Only
    /// the folder a restore reads from is its own, so that is where they part.
    var catalogKey: String { self == .ipod ? Platform.ios.rawValue : rawValue }

    /// The identifiers that belong to this platform and no other. Every source
    /// this app reads — the catalog, Apple's restore catalog, Apple's downloads
    /// page — mixes platforms together under one heading: a tvOS release
    /// carries the HomePod, an iOS one carries the iPod touch. The identifier
    /// is the only thing that says which is which.
    var prefix: String {
        switch self {
        case .ios: "iPhone"
        case .ipados: "iPad"
        case .ipod: "iPod"
        case .tvos: "AppleTV"
        case .audioos: "AudioAccessory"
        case .visionos: "RealityDevice"
        // Mac14,3, MacBookPro18,1, Macmini9,1 — all of them.
        case .macos: "Mac"
        }
    }

    /// Whether any part of an image is this platform's.
    func covers(_ firmware: Firmware) -> Bool {
        firmware.devices.contains { $0.hasPrefix(prefix) }
    }

    /// Whether an image straight out of Apple's own restore catalog is wholly
    /// this platform's. That catalog hands over everything Apple restores at
    /// once, so unlike `covers` — which sorts an image known to be somewhere in
    /// this family — this decides whether it belongs here in the first place.
    func owns(_ firmware: Firmware) -> Bool {
        !firmware.devices.isEmpty && firmware.devices.allSatisfy { $0.hasPrefix(prefix) }
    }
}

/// Release images, or the beta and release-candidate ones.
enum Channel: String, CaseIterable, Identifiable, Codable {
    case release, beta

    var id: String { rawValue }
    var title: String {
        self == .release ? String(localized: "Release") : String(localized: "Beta and RC")
    }
}

struct CatalogClient {
    /// Overridable so the interface can be exercised against a local catalog.
    var base = ProcessInfo.processInfo.environment["IPSW_CATALOG_BASE"].flatMap(URL.init(string:))
        ?? URL(string: "https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api")!
    var session: URLSession = .shared

    func latest(_ platform: Platform) async throws -> Catalog {
        try await document(at: "\(platform.catalogKey)/release/latest.json", platform)
    }

    /// Every build the catalog knows for a platform, for picking one by hand.
    func everyBuild(_ platform: Platform, channel: Channel) async throws -> Catalog {
        try await document(at: "\(platform.catalogKey)/\(channel.rawValue)/all.json", platform)
    }

    private func document(at path: String, _ platform: Platform) async throws -> Catalog {
        let url = base.appending(path: path)
        var request = URLRequest(url: url)
        // The catalog is rewritten in place, so a cached copy hides new builds.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // A stalled network must not leave the interface waiting indefinitely.
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SyncError.catalogUnavailable(platform)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Catalog.self, from: data).covering(platform)
    }
}

enum SyncError: LocalizedError {
    case catalogUnavailable(Platform)
    case appleCatalogUnavailable
    case feedUnavailable
    case volumeNotMounted(String)
    case checksumMismatch(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .catalogUnavailable(let platform):
            String(format: String(localized: "Could not read the %@ catalog."), platform.title)
        case .appleCatalogUnavailable:
            String(localized: "Could not read Apple's restore catalog.")
        case .feedUnavailable:
            String(localized: "Could not read Apple's releases feed.")
        case .volumeNotMounted(let volume):
            String(format: String(localized: "%@ is not mounted."), volume)
        case .checksumMismatch(let name):
            String(format: String(localized: "%@ does not match Apple's checksum."), name)
        case .http(let code, let name):
            String(format: String(localized: "%1$@ failed with HTTP %2$lld."), name, code)
        }
    }
}

/// The language the app draws itself in. macOS decides for itself unless it is
/// told otherwise, which is what the other two do.
enum Language: String, CaseIterable, Identifiable, Codable {
    case system, english, japanese

    var id: String { rawValue }

    /// What to write into AppleLanguages; nothing, for the system's own choice.
    var code: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .japanese: "ja"
        }
    }

    /// Each in its own language, so the one being looked for reads as itself.
    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .english: "English"
        case .japanese: "日本語"
        }
    }
}
