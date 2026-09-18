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

struct ReleaseOrderTests {
    private func release(_ version: String, _ label: String?, _ build: String) -> Release {
        Release(id: build, version: version, versionLabel: label, build: build,
                releasedAt: nil, firmwares: [])
    }

    /// The build number cannot order these: 27.0's betas run up to 24A5430A
    /// and the build that shipped is 24A437, a smaller number than any of
    /// them. Ordering by build put what shipped underneath the betas.
    @Test func whatShippedComesFirst() {
        let order = [release("27.0", "27.0-beta-8", "24A5430A"),
                     release("27.0", "27.0-rc", "24A435"),
                     release("27.0", "27.0-beta", "24A5355Q"),
                     release("27.0", "27.0", "24A437"),
                     release("27.0", "27.0-beta-2", "24A5370H")]
            .sorted(by: Release.newestFirst)
            .map(\.build)
        #expect(order == ["24A437", "24A435", "24A5430A", "24A5370H", "24A5355Q"])
    }

    /// Two builds of beta 1 stay together, the later one above.
    @Test func aRevisionSitsAboveWhatItRevised() {
        let order = [release("26.0", "26.0-beta", "23A5260N"),
                     release("26.0", "26.0-beta-2", "23A5276F"),
                     release("26.0", "26.0-beta", "23A5260U")]
            .sorted(by: Release.newestFirst)
            .map(\.build)
        #expect(order == ["23A5276F", "23A5260U", "23A5260N"])
    }
}

struct CatalogFilteringTests {
    /// Splitting a catalog per platform rebuilds each release, and a rebuild
    /// that forgets a field loses it silently — the labels reached the app and
    /// were thrown away one step later.
    @Test func filteringKeepsWhatTheCatalogSaid() throws {
        let json = """
        {"os":"iOS","os_key":"ios","generated_at":"2026-09-17T00:00:00Z","releases":[
          {"id":"a","version":"26.6","version_label":"26.6-beta-5","build":"23G5065A",
           "released_at":null,"firmwares":[
             {"id":"f","name":"iPhone 17","devices":["iPhone18,3"],
              "filename":"iPhone18,3_26.6_23G5065A_Restore.ipsw",
              "url":"https://updates.cdn-apple.com/x.ipsw","sha1":null,"signed":true}]}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(Catalog.self, from: Data(json.utf8))
        #expect(catalog.releases[0].prerelease == "beta 5")
        #expect(catalog.covering(.ios).releases[0].prerelease == "beta 5")
    }
}

/// What the device list is asked for is what is fetched. An empty selection
/// used to be read as "every device", so clearing every box downloaded the
/// whole catalog instead of nothing.
struct ChoiceTests {
    private let images = [
        Firmware(id: "a", name: "iPhone 17e", devices: ["iPhone17,5"], filename: "a.ipsw",
                 url: URL(string: "https://updates.cdn-apple.com/a.ipsw")!, sha1: nil, signed: true),
        Firmware(id: "b", name: "iPad Air", devices: ["iPad16,8", "iPad16,10"], filename: "b.ipsw",
                 url: URL(string: "https://updates.cdn-apple.com/b.ipsw")!, sha1: nil, signed: true)
    ]

    /// The same test the engine's filter applies.
    private func wanted(_ devices: Set<String>?) -> [Firmware] {
        images.filter { image in
            guard image.signed else { return false }
            guard let devices else { return true }
            return !devices.isDisjoint(with: image.devices)
        }
    }

    @Test func nothingChosenFetchesNothing() {
        #expect(wanted([]).isEmpty)
    }

    @Test func everyDeviceFetchesEverything() {
        #expect(wanted(nil).count == 2)
    }

    @Test func oneDeviceFetchesOnlyItsImage() {
        #expect(wanted(["iPhone17,5"]).map(\.id) == ["a"])
    }

    /// Apple ships one file for several iPads, so asking for one of them
    /// necessarily brings the others; the row names them all.
    @Test func aSharedImageBringsTheDevicesItServes() {
        let only = wanted(["iPad16,8"])
        #expect(only.count == 1)
        #expect(only[0].devices.contains("iPad16,10"))
    }
}
