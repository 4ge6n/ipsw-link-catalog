import Foundation

/// Apple's own restore catalog — the property list Finder reads to find out
/// what a device can be restored to.
///
/// It needs no account, it carries the download link *and* the checksum, and it
/// changes the moment Apple starts signing a build. The catalog this app
/// normally reads is rebuilt every quarter of an hour and then sits in a CDN,
/// so it learns the same thing twenty minutes later; this is here for the
/// twenty minutes in between.
///
/// It is six megabytes, which would be a rude thing to ask for every minute, so
/// it is asked for two ways at once: conditionally, which often has Apple
/// answer with nothing at all, and only when there is a reason to. Apple
/// re-dates the object every few minutes even when its contents have not
/// changed, so a conditional ask is a saving rather than a guarantee, and the
/// header is no use as a signal that something is new.
actor AppleRestoreCatalog {
    private let source = ProcessInfo.processInfo.environment["IPSW_APPLE_CATALOG"].flatMap(URL.init(string:))
        ?? URL(string: "https://itunes.apple.com/WebObjects/MZStore.woa/wa"
               + "/com.apple.jingle.appserver.client.MZITunesClientCheck/version")!
    private let session: URLSession
    /// What Apple said the last time, so the next ask can be conditional.
    private var lastModified: String?
    private var held: [Release] = []

    init(session: URLSession = .shared) { self.session = session }

    /// When it was last actually read, so a caller can decide to leave it.
    private var lastRead: Date?

    /// Read it — unless it was read within `keepingFor`, in which case what was
    /// read then is what comes back. `.zero` always asks.
    func read(naming names: [String: String] = [:], keepingFor: TimeInterval = 0) async throws -> [Release] {
        if !held.isEmpty, let lastRead, Date.now.timeIntervalSince(lastRead) < keepingFor { return held }
        var request = URLRequest(url: source)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        request.setValue("IPSW Sync", forHTTPHeaderField: "User-Agent")
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.appleCatalogUnavailable }
        lastRead = .now
        // Unchanged. Apple sends no body at all, which is the point of asking
        // this way.
        if http.statusCode == 304 { return held }
        guard http.statusCode == 200 else { throw SyncError.appleCatalogUnavailable }
        let tree = try PropertyListSerialization.propertyList(from: data, format: nil)
        held = group(entries(in: tree).compactMap { firmware(from: $0, names: names) })
        lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        return held
    }

    /// What was read last, without asking again.
    var current: [Release] { held }

    /// One line of Apple's catalog, flattened out of the tree it arrives in.
    private struct Entry {
        let device: String
        let version: String
        let build: String
        let url: String
        let sha1: String?
    }

    private func firmware(from entry: Entry, names: [String: String]) -> (Firmware, String)? {
        guard let link = URL(string: entry.url), AppleHosts.allowed.contains(link.host() ?? "") else { return nil }
        let firmware = Firmware(id: "\(entry.device)-\(entry.build)",
                                name: names[entry.device] ?? entry.device,
                                devices: [entry.device], filename: link.lastPathComponent, url: link,
                                sha1: (entry.sha1?.isEmpty ?? true) ? nil : entry.sha1?.lowercased(),
                                // Being in this catalog at all is what signed means.
                                signed: true)
        return (firmware, entry.version)
    }

    /// One release per build, the shape the rest of the app reads.
    private func group(_ found: [(Firmware, String)]) -> [Release] {
        var byBuild: [String: [Firmware]] = [:]
        var versionOf: [String: String] = [:]
        for (firmware, version) in found {
            let build = String(firmware.id.split(separator: "-").last ?? "")
            // The same device and build appear under several catalog versions.
            if byBuild[build]?.contains(where: { $0.id == firmware.id }) == true { continue }
            byBuild[build, default: []].append(firmware)
            versionOf[build] = version
        }
        return byBuild.map { build, list in
            Release(id: build, version: versionOf[build] ?? "", build: build, releasedAt: nil,
                    firmwares: list.sorted(by: Firmware.newestFirst))
        }
        // The catalog carries no dates, so the version is what orders it.
        .sorted {
            let byVersion = $1.version.localizedStandardCompare($0.version)
            if byVersion != .orderedSame { return byVersion == .orderedAscending }
            return $0.build.localizedStandardCompare($1.build) == .orderedDescending
        }
    }

    /// Walk to every Restore entry, remembering the device identifier above it.
    private nonisolated func entries(in node: Any, device: String? = nil) -> [Entry] {
        if let dictionary = node as? [String: Any] {
            var found: [Entry] = []
            if let device,
               let url = dictionary["FirmwareURL"] as? String, url.hasSuffix(".ipsw"),
               let version = dictionary["ProductVersion"].map(String.init(describing:)),
               let build = dictionary["BuildVersion"].map(String.init(describing:)) {
                found.append(Entry(device: device, version: version, build: build, url: url,
                                   sha1: dictionary["FirmwareSHA1"] as? String))
            }
            for (key, value) in dictionary {
                // MobileDeviceSoftwareVersions is keyed by device identifier.
                let named = Self.identifier.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
                found += entries(in: value, device: named ? key : device)
            }
            return found
        }
        if let list = node as? [Any] {
            return list.flatMap { entries(in: $0, device: device) }
        }
        return []
    }

    /// Device identifiers look like iPhone18,5. Container keys such as
    /// "iPodSoftwareVersions" must not be mistaken for one.
    private static let identifier = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9]*[0-9]+,[0-9]+$")
}
