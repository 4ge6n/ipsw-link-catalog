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

    /// iPhone18,5_27.0_24A437_Restore.ipsw and its other builds share this.
    var modelKey: String { Firmware.modelKey(of: filename) }

    /// The name without its version and build. iPad_Pro_M4_27.2_24B5084k and
    /// the same image for every other version share iPad_Pro_M4, which is what
    /// lets one build say what another one covers.
    static func modelKey(of filename: String) -> String {
        filename.replacing(#/_[0-9][^_]*_[A-Za-z0-9]+_Restore\.ipsw$/#, with: "")
    }

    /// iPhone19,7 against iPhone18,5. The catalog's own order runs through a
    /// generation out of step — 17e, then 17, then 17 Pro — so anything meant
    /// for a person to read down is put back in order with this.
    var modelNumber: (kind: String, major: Int, minor: Int) {
        let identifier = devices.first ?? name
        let kind = identifier.prefix { !$0.isNumber }
        let numbers = identifier.dropFirst(kind.count).split(separator: ",")
        return (String(kind),
                Int(numbers.first ?? "") ?? 0,
                Int(numbers.dropFirst().first ?? "") ?? 0)
    }

    /// Newest generation first, kept together by the kind of device, and within
    /// a generation by name. The identifiers do not run in the order the models
    /// are spoken of — 18,1 is the Pro and 18,3 the plain one — so past the
    /// generation it is the name that decides.
    static func newestFirst(_ one: Firmware, _ other: Firmware) -> Bool {
        let left = one.modelNumber, right = other.modelNumber
        if left.kind != right.kind { return left.kind < right.kind }
        if left.major != right.major { return left.major > right.major }
        let byName = one.name.localizedStandardCompare(other.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return left.minor < right.minor
    }
}

struct Release: Codable, Identifiable, Hashable {
    let id: String
    let version: String
    let build: String
    let releasedAt: Date?
    let firmwares: [Firmware]

    enum CodingKeys: String, CodingKey {
        case id, version, build, firmwares
        case releasedAt = "released_at"
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
