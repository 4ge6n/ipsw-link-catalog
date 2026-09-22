import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The iPhone or iPad the app is running on.
///
/// The catalog is a list of every device Apple has ever shipped, and the one
/// in your hand is somewhere in it. Nothing here is guessed: the identifier
/// and the build come from the kernel, and the name comes from the catalog
/// itself: this app carries no table of its own.
struct ThisDevice: Sendable {
    /// iPhone18,4
    let identifier: String
    /// 27.0
    let version: String
    /// 24A437 — the build, which the version alone does not say and which is
    /// what a catalog entry is actually keyed by.
    let build: String

    static let current = ThisDevice()

    private init() {
        identifier = Self.hardware()
        #if canImport(UIKit)
        version = UIDevice.current.systemVersion
        #else
        version = ProcessInfo.processInfo.operatingSystemVersionString
        #endif
        build = Self.sysctl("kern.osversion") ?? ""
    }

    /// The model identifier. In the Simulator `uname` answers for the Mac
    /// underneath, so the simulated device says which one it is instead.
    private static func hardware() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        return sysctl("hw.machine") ?? ""
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }

    /// "iPhone" or "iPad", for a heading that reads like the thing in hand.
    var kindName: String {
        identifier.hasPrefix("iPad") ? String(localized: "iPad")
            : identifier.hasPrefix("iPod") ? String(localized: "iPod touch")
            : String(localized: "iPhone")
    }

    /// What Apple calls this device, according to the catalog. An image for
    /// one device carries that device's name; one covering fourteen iPads
    /// carries something else, so only the former is read.
    func name(from releases: [Release]) -> String {
        for release in releases {
            for image in release.firmwares where image.devices == [identifier] {
                return image.name
            }
        }
        return identifier
    }

    /// The images in a release that this device can actually be restored with.
    func images(in release: Release) -> [Firmware] {
        release.firmwares.filter { $0.devices.contains(identifier) }
    }

    /// Whether a build is the one already installed.
    func isInstalled(_ release: Release) -> Bool {
        release.build.caseInsensitiveCompare(build) == .orderedSame
    }
}
