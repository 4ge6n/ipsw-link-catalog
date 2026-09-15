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
}

/// The operating systems this app can keep a folder in step with.
enum Platform: String, CaseIterable, Identifiable, Codable {
    case ios, ipados

    var id: String { rawValue }
    var title: String { self == .ios ? "iOS" : "iPadOS" }
}

struct CatalogClient {
    /// Overridable so the interface can be exercised against a local catalog.
    var base = ProcessInfo.processInfo.environment["IPSW_CATALOG_BASE"].flatMap(URL.init(string:))
        ?? URL(string: "https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api")!
    var session: URLSession = .shared

    func latest(_ platform: Platform) async throws -> Catalog {
        let url = base.appending(path: "\(platform.rawValue)/release/latest.json")
        var request = URLRequest(url: url)
        // The catalog is rewritten in place, so a cached copy hides new builds.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SyncError.catalogUnavailable(platform)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Catalog.self, from: data)
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
