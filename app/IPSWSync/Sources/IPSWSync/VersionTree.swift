import Foundation

/// Builds arranged the way they are spoken of: 27, then 27.2, then the build.
///
/// A channel holds hundreds of builds — five hundred and forty-one for iOS
/// betas alone — and a flat list of them is not something to read. The major
/// version is the first thing anyone knows about a build, the point release the
/// second, and only then which build of it.
enum VersionTree {
    /// One major version: iOS 27, with the point releases under it.
    struct Major: Identifiable {
        let number: Int
        let versions: [Version]
        var id: Int { number }
        var name: String { "\(number)" }
        var buildCount: Int { versions.reduce(0) { $0 + $1.builds.count } }
    }

    /// One point release: 27.2, with the builds that carried it.
    struct Version: Identifiable {
        let name: String
        let builds: [Release]
        var id: String { name }
    }

    /// Newest first, all the way down.
    static func of(_ releases: [Release]) -> [Major] {
        var byMajor: [Int: [String: [Release]]] = [:]
        for release in releases {
            guard let major = major(of: release.version) else { continue }
            byMajor[major, default: [:]][release.version, default: []].append(release)
        }
        return byMajor.map { number, versions in
            Major(number: number, versions: versions.map { name, builds in
                Version(name: name, builds: builds.sorted(by: newestFirst))
            }
            .sorted { $1.name.localizedStandardCompare($0.name) == .orderedAscending })
        }
        .sorted { $0.number > $1.number }
    }

    /// "27.2" is 27; "9.3.5" is 9.
    static func major(of version: String) -> Int? {
        Int(version.split(separator: ".").first ?? "")
    }

    /// The day it was posted where that is known, and the build otherwise —
    /// most builds carry no date at all, and the build number runs forward.
    private static func newestFirst(_ one: Release, _ other: Release) -> Bool {
        if let mine = one.releasedAt, let theirs = other.releasedAt, mine != theirs {
            return mine > theirs
        }
        return one.build.localizedStandardCompare(other.build) == .orderedDescending
    }
}
