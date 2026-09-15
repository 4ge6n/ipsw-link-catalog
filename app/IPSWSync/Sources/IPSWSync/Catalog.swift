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
    var modelKey: String {
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
    case ios, ipados, ipod

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ios: "iOS"
        case .ipados: "iPadOS"
        case .ipod: "iPod"
        }
    }

    /// An iPod touch runs iOS and Apple publishes it in the iOS catalog. Only
    /// the folder a restore reads from is its own, so that is where they part.
    var catalogKey: String { self == .ipod ? Platform.ios.rawValue : rawValue }

    func covers(_ firmware: Firmware) -> Bool {
        let isPod = firmware.devices.contains { $0.hasPrefix("iPod") }
        switch self {
        case .ipod: return isPod
        case .ios: return !isPod
        case .ipados: return true
        }
    }
}

/// Release images, or the beta and release-candidate ones.
enum Channel: String, CaseIterable, Identifiable, Codable {
    case release, beta

    var id: String { rawValue }
    var title: String { self == .release ? "Release" : "Beta and RC" }
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
    case volumeNotMounted(String)
    case checksumMismatch(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .catalogUnavailable(let platform): "Could not read the \(platform.title) catalog."
        case .volumeNotMounted(let volume): "\(volume) is not mounted."
        case .checksumMismatch(let name): "\(name) does not match Apple's checksum."
        case .http(let code, let name): "\(name) failed with HTTP \(code)."
        }
    }
}
