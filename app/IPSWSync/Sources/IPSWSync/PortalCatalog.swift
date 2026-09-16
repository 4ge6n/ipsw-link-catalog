import Foundation

/// Apple's downloads page, as it is actually written.
///
/// The page is rendered on the server rather than filled in from a JSON feed,
/// so this reads the page. Each release is one expandable row carrying its name,
/// its build, the day it was posted, and a link per device — all of them on the
/// same Apple CDN the public images come from, so nothing here needs a session
/// to be fetched once it has been found.
enum PortalCatalog {
    /// One release Apple is currently offering, with the images under it.
    struct Entry {
        let platform: Platform
        let version: String
        let build: String
        /// Apple writes "iOS 27.2 beta" for these, and "iOS 27.0" for the rest.
        let prerelease: String?
        let released: Date?
        let firmwares: [Firmware]

        var isBeta: Bool { prerelease != nil }
    }

    /// `identifiers` maps a filename's model key to the devices it covers, for
    /// the images Apple names after the model rather than the identifier. The
    /// key outlives a version, so a build posted an hour ago is resolved from
    /// what the catalog already knew about the one before it.
    static func parse(_ page: String, identifiers: [String: [String]] = [:]) -> [Entry] {
        rows(in: page).compactMap { entry(from: $0, identifiers: identifiers) }
    }

    /// Each release begins with a comment naming it. The markup after that
    /// comment differs — some rows are expandable and some are not — so the
    /// comment is the only thing every release has in common.
    private static func rows(in page: String) -> [String] {
        let marker = "<!--------"
        var found: [String] = []
        var start = page.startIndex
        var bounds: [String.Index] = []
        while let range = page.range(of: marker, range: start..<page.endIndex) {
            bounds.append(range.lowerBound)
            start = range.upperBound
        }
        for (index, from) in bounds.enumerated() {
            let to = index + 1 < bounds.count ? bounds[index + 1] : page.endIndex
            found.append(String(page[from..<to]))
        }
        return found
    }

    /// "iOS 27.2 beta", "iPadOS 27.0", "macOS 27.1 RC".
    private static let heading = expression(#"^([A-Za-z ]+?)\s+([0-9][0-9.]*)(?:\s+(beta.*|RC|Release Candidate.*))?$"#)

    private static func entry(from row: String, identifiers: [String: [String]]) -> Entry? {
        guard let title = capture(row, #"<h3>(.*?)</h3>"#).map(text(of:)),
              let named = heading.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let osRange = Range(named.range(at: 1), in: title),
              let versionRange = Range(named.range(at: 2), in: title),
              let platform = platform(String(title[osRange]).trimmingCharacters(in: .whitespaces)),
              let build = capture(row, #"<li><span>Build</span>(.*?)</li>"#).map(text(of:))
        else { return nil }
        let prerelease = Range(named.range(at: 3), in: title).map { String(title[$0]) }
        let released = capture(row, #"<li><span>Released</span>(.*?)</li>"#).map(text(of:)).flatMap(date(from:))
        let firmwares = images(in: row, build: build, identifiers: identifiers)
        guard !firmwares.isEmpty else { return nil }
        return Entry(platform: platform, version: String(title[versionRange]), build: build,
                     prerelease: prerelease, released: released, firmwares: firmwares)
    }

    /// The device names are the link text; the identifiers are in the filename,
    /// which is the only place they appear at all.
    private static let image = expression(#"<a href="(https://[^"]+\.ipsw)"[^>]*>(.*?)</a>"#)

    private static func images(in row: String, build: String, identifiers: [String: [String]]) -> [Firmware] {
        var found: [Firmware] = []
        for match in image.matches(in: row, range: NSRange(row.startIndex..., in: row)) {
            guard let linkRange = Range(match.range(at: 1), in: row),
                  let labelRange = Range(match.range(at: 2), in: row),
                  let url = URL(string: String(row[linkRange])),
                  AppleHosts.allowed.contains(url.host() ?? "") else { continue }
            let filename = url.lastPathComponent
            // Some images are named for the model rather than the identifier —
            // iPad_Pro_M4_… — and Apple gives the identifier nowhere on the
            // page. The name without its version is the same as it was for the
            // build before, so what that one covered is what this one covers.
            let named = self.identifiers(in: filename)
            let devices = named.isEmpty ? (identifiers[modelKey(of: filename)] ?? []) : named
            found.append(Firmware(id: "\(devices.first ?? filename)-\(build)", name: text(of: String(row[labelRange])),
                                  devices: devices, filename: filename, url: url,
                                  // Apple publishes no checksum on this page.
                                  sha1: nil, signed: true))
        }
        return found
    }

    /// iPad_Pro_M4_27.2_24B5084k_Restore.ipsw and the same image for every
    /// other version share iPad_Pro_M4.
    static func modelKey(of filename: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"_[0-9][^_]*_[A-Za-z0-9]+_Restore\.ipsw$"#) else { return filename }
        let whole = NSRange(filename.startIndex..., in: filename)
        return expression.stringByReplacingMatches(in: filename, range: whole, withTemplate: "")
    }

    /// iPhone19,2,iPhone19,3,iPhone19,7_27.2_24B5084k_Restore.ipsw
    private static func identifiers(in filename: String) -> [String] {
        let head = filename.split(separator: "_").first.map(String.init) ?? ""
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

    private static func platform(_ name: String) -> Platform? {
        switch name {
        case "iOS": .ios
        case "iPadOS": .ipados
        // Apple stopped shipping iPod touch before it had a page of its own; it
        // rides along with iOS, as it does everywhere else.
        default: nil
        }
    }

    private static let tags = expression("<[^>]+>")

    private static func expression(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators)
    }

    private static func capture(_ text: String, _ pattern: String) -> String? {
        let expression = Self.expression(pattern)
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Strip the markup and the entities, leaving what a reader would see.
    private static func text(of markup: String) -> String {
        let whole = NSRange(markup.startIndex..., in: markup)
        var result = tags.stringByReplacingMatches(in: markup, range: whole, withTemplate: " ")
        for (entity, character) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func date(from text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.date(from: text)
    }
}

/// The only hosts an image is ever fetched from.
enum AppleHosts {
    static let allowed: Set<String> = ["updates.cdn-apple.com", "secure-appldnld.apple.com", "appldnld.apple.com"]
}

enum PortalError: LocalizedError {
    case signedOut
    case unreadable
    case nothingRecognised

    var errorDescription: String? {
        switch self {
        case .signedOut:
            String(localized: "Apple asked for a sign-in. The session has expired.")
        case .unreadable:
            String(localized: "Apple's downloads page did not answer with anything readable.")
        case .nothingRecognised:
            String(localized: "Apple answered, but not in a shape this app recognises. The reply was kept so it can be looked at.")
        }
    }
}
