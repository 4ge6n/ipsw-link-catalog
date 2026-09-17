import Foundation
import Testing
@testable import IPSWSync

/// Apple changes how it packages an image without warning, and the app has to
/// keep up without being told. These are the shapes it has actually taken.
struct SupersessionTests {
    private func firmware(_ filename: String, _ devices: [String]) -> Firmware {
        Firmware(id: filename, name: devices.first ?? filename, devices: devices,
                 filename: filename, url: URL(string: "https://updates.cdn-apple.com/\(filename)")!,
                 sha1: nil, signed: true)
    }

    @Test func readsTheIdentifiersApplePutsInTheName() {
        #expect(Firmware.devices(in: "iPhone18,5_27.0_24A437_Restore.ipsw") == ["iPhone18,5"])
        #expect(Firmware.devices(in: "iPhone19,2,iPhone19,3,iPhone19,7_27.2_24B5084k_Restore.ipsw")
                == ["iPhone19,2", "iPhone19,3", "iPhone19,7"])
        // Named for the model; the identifiers are nowhere in it.
        #expect(Firmware.devices(in: "iPad_Pro_M4_27.2_24B5084k_Restore.ipsw").isEmpty)
    }

    /// 27.0 shipped one image per device; 27.2 shipped one between the three.
    /// Each of the old three is replaced by the one new one.
    @Test func aMergedImageReplacesTheSeparateOnes() {
        let merged = [firmware("iPhone19,2,iPhone19,3,iPhone19,7_27.2_24B5084k_Restore.ipsw",
                               ["iPhone19,2", "iPhone19,3", "iPhone19,7"])]
        for old in ["iPhone19,2_27.0_24A437_Restore.ipsw",
                    "iPhone19,3_27.0_24A437_Restore.ipsw",
                    "iPhone19,7_27.0_24A437_Restore.ipsw"] {
            #expect(Supersession.isReplaced(old, by: merged, using: DeviceIndex()))
        }
    }

    /// And the other way, for when Apple splits one again.
    @Test func separateImagesReplaceAMergedOne() {
        let split = [firmware("iPhone19,2_28.0_25A1_Restore.ipsw", ["iPhone19,2"]),
                     firmware("iPhone19,3_28.0_25A1_Restore.ipsw", ["iPhone19,3"]),
                     firmware("iPhone19,7_28.0_25A1_Restore.ipsw", ["iPhone19,7"])]
        #expect(Supersession.isReplaced("iPhone19,2,iPhone19,3,iPhone19,7_27.2_24B5084k_Restore.ipsw",
                                        by: split, using: DeviceIndex()))
    }

    @Test func aDeviceWhoseReplacementIsNotHereKeepsItsBuild() {
        let partial = [firmware("iPhone19,2_28.0_25A1_Restore.ipsw", ["iPhone19,2"])]
        // The merged image is also for 19,3 and 19,7, and neither has a newer
        // build here, so it stays.
        #expect(!Supersession.isReplaced("iPhone19,2,iPhone19,3,iPhone19,7_27.2_24B5084k_Restore.ipsw",
                                         by: partial, using: DeviceIndex()))
    }

    @Test func aFileThatIsWantedIsNotReplacedByItself() {
        let wanted = [firmware("iPhone18,5_27.0_24A437_Restore.ipsw", ["iPhone18,5"])]
        #expect(!Supersession.isReplaced("iPhone18,5_27.0_24A437_Restore.ipsw", by: wanted, using: DeviceIndex()))
    }

    /// Not knowing what something is for is not a reason to delete it.
    @Test func anUnreadableNameIsNeverReplaced() {
        let wanted = [firmware("iPhone18,5_27.0_24A437_Restore.ipsw", ["iPhone18,5"])]
        #expect(!Supersession.isReplaced("something_someone_renamed.ipsw", by: wanted, using: DeviceIndex()))
    }

    /// A model-named image has no identifiers in it, so what it is for comes
    /// from what the catalog knew of that name.
    @Test func aModelNamedImageIsResolvedThroughTheCatalog() {
        var index = DeviceIndex()
        index.add(firmware("iPad_Pro_M4_27.0_24A437_Restore.ipsw",
                           ["iPad16,3", "iPad16,4", "iPad16,5", "iPad16,6"]), at: .now)
        let newer = [firmware("iPad_Pro_M4_27.2_24B5084k_Restore.ipsw",
                              ["iPad16,3", "iPad16,4", "iPad16,5", "iPad16,6"])]
        #expect(Supersession.isReplaced("iPad_Pro_M4_27.0_24A437_Restore.ipsw", by: newer, using: index))
    }
}

struct OrderingTests {
    private func firmware(_ devices: [String], _ name: String) -> Firmware {
        Firmware(id: name, name: name, devices: devices, filename: "\(devices[0])_1_1_Restore.ipsw",
                 url: URL(string: "https://updates.cdn-apple.com/x.ipsw")!, sha1: nil, signed: true)
    }

    /// Descending identifier, kept together by the kind of device.
    @Test func devicesRunDownwards() {
        let sorted = [firmware(["iPhone17,1"], "iPhone 16 Pro"),
                      firmware(["iPhone19,7"], "iPhone 18 Pro Max (Global)"),
                      firmware(["iPhone18,4"], "iPhone Air"),
                      firmware(["iPhone18,5"], "iPhone 17e"),
                      firmware(["iPod9,1"], "iPod touch")]
            .sorted(by: Firmware.newestFirst)
            .map { $0.devices[0] }
        #expect(sorted == ["iPhone19,7", "iPhone18,5", "iPhone18,4", "iPhone17,1", "iPod9,1"])
    }

    /// A combined image sorts by the newest device in it, not the first.
    @Test func aCombinedImageSortsByItsNewestDevice() {
        let sorted = [firmware(["iPhone18,5"], "iPhone 17e"),
                      firmware(["iPhone19,2", "iPhone19,3", "iPhone19,7"], "iPhone 18 Pro")]
            .sorted(by: Firmware.newestFirst)
        #expect(sorted[0].devices.count == 3)
    }
}

struct PrereleaseTests {
    private func release(_ version: String, _ label: String?, _ build: String) -> Release {
        Release(id: build, version: version, versionLabel: label, build: build,
                releasedAt: nil, firmwares: [])
    }

    /// Apple's own numbering, as the catalog recorded it. Never derived from
    /// the order, which the revisions would put out.
    @Test func saysWhatAppleCalledIt() {
        #expect(release("26.0", "26.0-beta-3", "23A5287G").prerelease == "beta 3")
        #expect(release("26.0", "26.0-rc", "23A340").prerelease == "RC")
        #expect(release("26.0", "26.0", "23A341").prerelease == nil)
        #expect(release("27.2", nil, "24B5084K").prerelease == nil)
    }

    /// 23A5260N and 23A5260U are both iOS 26 beta 1 — Apple posted it twice.
    /// They are two builds of beta 1, not beta 1 and beta 2.
    @Test func aRevisionKeepsItsBetaNumber() {
        #expect(release("26.0", "26.0-beta", "23A5260N").prerelease == "beta 1")
        #expect(release("26.0", "26.0-beta", "23A5260U").prerelease == "beta 1")
    }
}
