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
            guard image.mightBeSigned else { return false }
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

/// The awkward names Apple has actually shipped, taken from its catalog.
struct RealNameTests {
    private func firmware(_ filename: String, _ devices: [String]) -> Firmware {
        Firmware(id: filename, name: devices[0], devices: devices, filename: filename,
                 url: URL(string: "https://updates.cdn-apple.com/\(filename)")!, sha1: nil, signed: true)
    }

    private func index(_ firmwares: [Firmware]) -> DeviceIndex {
        var built = DeviceIndex()
        for firmware in firmwares { built.add(firmware, at: nil) }
        return built
    }

    /// The GSM iPhone X. Apple names the file for iPhone10,6 alone and
    /// restores the global iPhone10,3 with it, so the name undercounts.
    @Test func aFileNamedForOneHalfOfAPairCoversBoth() {
        let real = firmware("iPhone10,6_11.2.6_15D100_Restore.ipsw", ["iPhone10,3", "iPhone10,6"])
        let found = Supersession.devices(of: real.filename, using: index([real]))
        #expect(Set(found) == ["iPhone10,3", "iPhone10,6"])
    }

    /// iPad_7,5_iPad_7,6 splits into "5_iPad_7,6", which is not a device.
    @Test func aNameThatIsNotAnIdentifierIsNotReadAsOne() {
        #expect(Firmware.devices(in: "iPad_7,5_iPad_7,6_11.3_15E216_Restore.ipsw").isEmpty)
    }

    @Test func thatSameNameIsStillResolvedThroughTheCatalog() {
        let real = firmware("iPad_7,5_iPad_7,6_11.3_15E216_Restore.ipsw", ["iPad7,5"])
        #expect(Supersession.devices(of: real.filename, using: index([real])) == ["iPad7,5"])
    }

    /// The combined iPhone 18 Pro image must still be read from its name, for
    /// a file the catalog has moved on from.
    @Test func identifiersInANameAreStillReadWhenTheCatalogHasMovedOn() {
        #expect(Firmware.devices(in: "iPhone19,2,iPhone19,3,iPhone19,7_27.2_24B5084k_Restore.ipsw")
                == ["iPhone19,2", "iPhone19,3", "iPhone19,7"])
    }

    /// And the GSM pair's older build must be deletable once the newer one,
    /// whatever Apple has named it, covers both halves.
    @Test func theOlderBuildOfThatPairIsReplaced() {
        let old = firmware("iPhone10,6_11.2.6_15D100_Restore.ipsw", ["iPhone10,3", "iPhone10,6"])
        let new = firmware("iPhone10,3_11.4_15F79_Restore.ipsw", ["iPhone10,3", "iPhone10,6"])
        var both = DeviceIndex()
        both.add(old, at: nil)
        both.add(new, at: Date())
        #expect(Supersession.isReplaced(old.filename, by: [new], using: both))
    }
}

/// The number in Settings is a number of downloads.
struct GateTests {
    /// Counts how many are inside at once.
    private actor Peak {
        private var now = 0
        private(set) var highest = 0
        func enter() { now += 1; highest = max(highest, now) }
        func leave() { now -= 1 }
    }

    @Test func neverMoreThanTheLimitAtOnce() async {
        let gate = Gate(limit: 3)
        let peak = Peak()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    await gate.enter()
                    await peak.enter()
                    try? await Task.sleep(for: .milliseconds(5))
                    await peak.leave()
                    await gate.leave()
                }
            }
        }
        #expect(await peak.highest <= 3)
        #expect(await peak.highest > 1)
    }

    /// The point of the whole thing: work done after leaving the gate — hashing
    /// a file that has just landed — does not hold the next transfer up.
    @Test func hashingRunsWhileTheNextFileIsAlreadyComing() async {
        let gate = Gate(limit: 1)
        let peak = Peak()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await gate.enter()
                    try? await Task.sleep(for: .milliseconds(2))   // the transfer
                    await gate.leave()
                    await peak.enter()
                    try? await Task.sleep(for: .milliseconds(20))  // the checksum
                    await peak.leave()
                }
            }
        }
        // One download at a time, and yet several checksums at once.
        #expect(await peak.highest > 1)
    }

    /// Raising the limit lets the ones already waiting through.
    @Test func aRaisedLimitAdmitsWhatIsWaiting() async {
        let gate = Gate(limit: 1)
        await gate.enter()
        let waiting = Task { await gate.enter() }
        try? await Task.sleep(for: .milliseconds(10))
        await gate.setLimit(4)
        await waiting.value
        #expect(true)  // it returned rather than hanging
    }
}

/// Once a day is a long time to be a few files short of a restore.
struct ScheduleTests {
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    @Test func dailyIsStillDaily() {
        #expect(Schedule.next(after: at(20, 5), hour: 4, minute: 0, everyHours: 24) == at(21, 4))
    }

    /// Counted from the time that was set, not from whenever the app started.
    @Test func everySixHoursKeepsToTheHourThatWasSet() {
        #expect(Schedule.next(after: at(20, 5), hour: 4, minute: 0, everyHours: 6) == at(20, 10))
        #expect(Schedule.next(after: at(20, 10, 1), hour: 4, minute: 0, everyHours: 6) == at(20, 16))
        #expect(Schedule.next(after: at(20, 23), hour: 4, minute: 0, everyHours: 6) == at(21, 4))
    }

    @Test func everyHourIsEveryHour() {
        #expect(Schedule.next(after: at(20, 9, 30), hour: 4, minute: 0, everyHours: 1) == at(20, 10))
    }

    /// What says whether a run was missed while the Mac was asleep.
    @Test func theLastTimeOneWasDue() {
        #expect(Schedule.lastDue(before: at(20, 10, 30), hour: 4, minute: 0, everyHours: 6) == at(20, 10))
        #expect(Schedule.lastDue(before: at(20, 9, 59), hour: 4, minute: 0, everyHours: 6) == at(20, 4))
        #expect(Schedule.lastDue(before: at(20, 10, 30), hour: 4, minute: 0, everyHours: 24) == at(20, 4))
    }
}

/// Three states, and none of them invented.
struct SigningTests {
    private func firmware(_ signed: Bool?) -> Firmware {
        Firmware(id: "a", name: "iPhone 17e", devices: ["iPhone18,5"], filename: "a.ipsw",
                 url: URL(string: "https://updates.cdn-apple.com/a.ipsw")!, sha1: nil, signed: signed)
    }

    /// The badge says signed. It may only appear when that has been checked.
    @Test func onlyACheckedBuildIsCalledSigned() {
        #expect(firmware(true).signed == true)
        #expect(firmware(nil).signed != true)
        #expect(firmware(false).signed != true)
    }

    /// And the other label says not signed, which is also a claim.
    @Test func onlyARuledOutBuildIsCalledUnsigned() {
        #expect(firmware(false).knownUnsigned)
        #expect(!firmware(nil).knownUnsigned)
        #expect(!firmware(true).knownUnsigned)
    }

    /// A beta nobody has asked Apple about is still worth fetching.
    @Test func anUncheckedBuildIsNotTreatedAsUnusable() {
        #expect(firmware(nil).mightBeSigned)
        #expect(firmware(true).mightBeSigned)
        #expect(!firmware(false).mightBeSigned)
    }
}

/// Six transfers used to look at the same free space, each see enough for
/// itself, and fill the drive together.
struct RoomClaimTests {
    @Test func whatOneTransferClaimsIsNotThereForTheNext() async throws {
        let engine = SyncEngine()
        let folder = FileManager.default.temporaryDirectory
        let free = try #require(engine.freeSpace(at: folder))
        // More than half of what is free, twice: the first fits, the second
        // would have fitted too when each only looked.
        let big = free / 2 + (free / 10)
        #expect(await engine.claimRoom(big, in: folder))
        #expect(!(await engine.claimRoom(big, in: folder)))
        await engine.releaseRoom(big, in: folder)
        #expect(await engine.claimRoom(big, in: folder))
        await engine.releaseRoom(big, in: folder)
    }

    @Test func aFullDriveIsRecognisedHoweverItIsSaid() {
        #expect(SyncEngine.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        #expect(SyncEngine.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        let wrapped = NSError(domain: NSURLErrorDomain, code: -1,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        #expect(SyncEngine.isOutOfSpace(wrapped))
        #expect(!SyncEngine.isOutOfSpace(URLError(.timedOut)))
    }
}
