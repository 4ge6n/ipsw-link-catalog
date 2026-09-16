import Foundation

/// One restore image Apple is offering this account.
///
/// The endpoint this comes from is private and undocumented, so the field names
/// below are what Apple's own page appears to read and not a contract. The
/// parser therefore looks for each of them among a few likely spellings and
/// says plainly when it finds nothing, rather than returning an empty list as
/// though Apple had offered nothing.
struct PortalDownload: Identifiable, Hashable {
    let title: String
    let filename: String
    let url: URL
    let size: Int64?
    let released: Date?
    var id: String { url.absoluteString }

    /// Beta images are served from here, and only to a signed-in account.
    static let host = "download.developer.apple.com"

    static func parse(_ data: Data) throws -> [PortalDownload] {
        guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PortalError.unreadable
        }
        // The endpoint answers 200 with a message rather than an HTTP error.
        if let message = top["resultString"] as? String,
           (top["resultCode"] as? Int ?? 0) != 0 {
            throw PortalError.refused(message)
        }
        guard let listing = first(of: top, ["downloads", "downloadList", "items"]) as? [[String: Any]] else {
            throw PortalError.unexpectedShape
        }
        var found: [PortalDownload] = []
        for entry in listing {
            let title = (first(of: entry, ["name", "title"]) as? String) ?? ""
            let released = (first(of: entry, ["dateCreated", "datePublished", "releaseDate"]) as? String)
                .flatMap(date(from:))
            guard let files = first(of: entry, ["files", "fileList"]) as? [[String: Any]] else { continue }
            for file in files {
                guard let name = first(of: file, ["filename", "fileName", "name"]) as? String,
                      name.lowercased().hasSuffix(".ipsw"),
                      let path = first(of: file, ["remotePath", "path", "url"]) as? String
                else { continue }
                guard let url = link(from: path) else { continue }
                let size = (first(of: file, ["fileSize", "size"]) as? NSNumber)?.int64Value
                found.append(PortalDownload(title: title, filename: name, url: url, size: size, released: released))
            }
        }
        guard !found.isEmpty else { throw PortalError.nothingRecognised }
        return found
    }

    /// A path that is already a link is left alone; one that is not is hung off
    /// the download host Apple serves these from.
    private static func link(from path: String) -> URL? {
        if path.hasPrefix("https://") { return URL(string: path) }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path.hasPrefix("/") ? path : "/" + path
        return components.url
    }

    private static func first(of dictionary: [String: Any], _ keys: [String]) -> Any? {
        for key in keys {
            if let value = dictionary[key] { return value }
        }
        return nil
    }

    private static func date(from text: String) -> Date? {
        for format in ["MM/dd/yy", "MM/dd/yyyy", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

enum PortalError: LocalizedError {
    case unreadable
    case refused(String)
    case unexpectedShape
    case nothingRecognised

    var errorDescription: String? {
        switch self {
        case .unreadable:
            String(localized: "Apple's downloads page did not answer with anything readable.")
        case .refused(let message):
            message
        case .unexpectedShape, .nothingRecognised:
            String(localized: "Apple answered, but not in a shape this app recognises. The reply was kept so it can be looked at.")
        }
    }
}
