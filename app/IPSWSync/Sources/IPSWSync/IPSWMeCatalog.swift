import Foundation

/// ipsw.me, asked for one thing only: the checksum Apple stops publishing.
///
/// Apple's restore catalog carries a SHA-1 for every image — until it stops
/// signing that build, at which point the build leaves the catalog altogether
/// and the only place left with a link is the downloads page, which publishes
/// no checksum at all. An image from there can be checked by its size and
/// nothing more.
///
/// ipsw.me keeps the checksums for builds Apple has moved on from. It is asked
/// by version and told nothing else: no identifier, no account, nothing about
/// which device this Mac is looking after. A build it does not know about —
/// every beta, since it carries none — is left as it was.
actor IPSWMeCatalog {
    private let base = ProcessInfo.processInfo.environment["IPSW_ME_BASE"].flatMap(URL.init(string:))
        ?? URL(string: "https://api.ipsw.me/v4/ipsw")!
    private let session: URLSession
    /// Answers already had, by version. A version it does not know is
    /// remembered as empty so it is asked once rather than on every look.
    private var held: [String: [String: String]] = [:]

    init(session: URLSession = .shared) { self.session = session }

    /// Filename to SHA-1, for one version.
    func checksums(for version: String) async -> [String: String] {
        if let known = held[version] { return known }
        var found: [String: String] = [:]
        defer { held[version] = found }
        guard !version.isEmpty else { return found }
        var request = URLRequest(url: base.appending(path: version))
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return found }
        for entry in entries {
            guard let sha1 = entry.sha1sum, !sha1.isEmpty,
                  let url = URL(string: entry.url ?? ""),
                  // The same rule the rest of the app follows: a link anywhere
                  // but Apple's own servers is not one of Apple's images, and
                  // a checksum attached to it says nothing about ours.
                  AppleHosts.allowed.contains(url.host() ?? "") else { continue }
            found[url.lastPathComponent] = sha1.lowercased()
        }
        return found
    }

    private struct Entry: Decodable {
        let url: String?
        let sha1sum: String?
    }
}
