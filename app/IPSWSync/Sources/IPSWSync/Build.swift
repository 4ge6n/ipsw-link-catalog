import Foundation

/// One build of one platform, however it was heard about.
///
/// The three places Apple says a build exists do not say the same things. The
/// releases feed is first but carries no link. The restore catalog carries the
/// link and the checksum, but only once Apple is signing it, and never for a
/// beta. The downloads page carries betas, but no checksum and only with an
/// account. This is all of them, one build at a time.
struct Build: Sendable, Hashable, Identifiable {
    /// Where the best thing known about this build came from.
    enum Source: String, Sendable {
        /// Announced, with nothing to download yet.
        case announced
        /// Apple's restore catalog: a link and a checksum.
        case apple
        /// Apple's downloads page: a link, and no checksum.
        case portal
    }

    let platform: Platform
    let version: String
    let build: String
    /// "beta", "beta 3", "RC" — nothing, for a release.
    let prerelease: String?
    let at: Date?
    var firmwares: [Firmware]
    var source: Source

    var id: String { "\(platform.rawValue)-\(version)-\(build)" }
    var isBeta: Bool { prerelease != nil }
    var title: String {
        [platform.title, version, prerelease].compactMap { $0 }.joined(separator: " ")
    }
    /// Whether there is anything to fetch yet.
    var isDownloadable: Bool { !firmwares.isEmpty }

    /// What of this belongs in a given platform's folder. Apple heads a row iOS
    /// and puts the iPod touch images under it, as the catalog does.
    func firmwares(for wanted: Platform) -> [Firmware] {
        guard platform.catalogKey == wanted.catalogKey else { return [] }
        return firmwares.filter(wanted.covers)
    }

    /// The same build heard about twice. The one that can be downloaded wins,
    /// and between two that can, the one carrying a checksum does.
    func better(than other: Build) -> Bool {
        if isDownloadable != other.isDownloadable { return isDownloadable }
        let mine = firmwares.contains { $0.sha1 != nil }
        let theirs = other.firmwares.contains { $0.sha1 != nil }
        if mine != theirs { return mine }
        return firmwares.count > other.firmwares.count
    }

    /// Keep what each one knows: the feed has the moment and how Apple worded
    /// it, the other two have the files.
    func merged(with other: Build) -> Build {
        let best = better(than: other) ? self : other
        return Build(platform: platform, version: version, build: build,
                     prerelease: prerelease ?? other.prerelease,
                     at: at ?? other.at,
                     firmwares: best.firmwares, source: best.source)
    }
}
