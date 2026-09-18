import Foundation
import Testing
@testable import IPSWSync

/// What happens to what is already on the drive. These write real files into a
/// real folder and then ask the engine about them, because the questions are
/// about the disk and nothing else answers them.
struct OnDiskTests {
    private func scratch() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "ipsw-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// What a person would see in the folder: the app keeps its record of what
    /// it has already checked in a dotfile beside the images.
    private func images(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path())
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    private func write(_ name: String, _ bytes: String, into folder: URL) throws -> URL {
        let url = folder.appending(path: name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    private func firmware(_ filename: String, _ devices: [String], sha1: String? = nil) -> Firmware {
        Firmware(id: filename, name: devices.first ?? filename, devices: devices,
                 filename: filename, url: URL(string: "https://updates.cdn-apple.com/\(filename)")!,
                 sha1: sha1, signed: true)
    }

    // MARK: Is what is here still good

    /// "abc" hashed with SHA-1.
    private let abc = "a9993e364706816aba3e25717850c26c9cd0d89d"

    @Test func aFileThatMatchesIsKept() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try write("x.ipsw", "abc", into: folder)
        let engine = SyncEngine()
        #expect(await engine.isIntact(file, sha1: abc))
    }

    @Test func aFileThatDoesNotMatchIsNotKept() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try write("x.ipsw", "abd", into: folder)
        let engine = SyncEngine()
        #expect(!(await engine.isIntact(file, sha1: abc)))
    }

    /// Apple publishes no checksum for some images. Without one there is
    /// nothing to verify against, so the length is what the caller falls back
    /// to — and this must not claim the file is good.
    @Test func withoutAChecksumNothingIsClaimed() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try write("x.ipsw", "abc", into: folder)
        let engine = SyncEngine()
        #expect(!(await engine.isIntact(file, sha1: nil)))
    }

    @Test func aFileThatIsNotThereIsNotIntact() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = SyncEngine()
        #expect(!(await engine.isIntact(folder.appending(path: "nothing.ipsw"), sha1: abc)))
    }

    /// The record of having checked is a shortcut, not the truth: changing the
    /// bytes underneath it must be noticed.
    @Test func aFileChangedAfterCheckingIsNoticed() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try write("x.ipsw", "abc", into: folder)
        let engine = SyncEngine()
        #expect(await engine.isIntact(file, sha1: abc))
        try Data("abd".utf8).write(to: file)
        VerifiedStore.shared.forget(file)
        #expect(!(await engine.isIntact(file, sha1: abc)))
    }

    /// And noticed without being told to forget first. The record is trusted
    /// on the file's size and date, and those were read through a URL, which
    /// keeps the answers it has already been given — so a file replaced after
    /// it was verified went on being called verified, which is the one place
    /// where the shortcut means never reading the bytes at all.
    @Test func aFileChangedBehindTheAppIsNoticedAnyway() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try write("x.ipsw", "abc", into: folder)
        let engine = SyncEngine()
        #expect(await engine.isIntact(file, sha1: abc))
        try Data("something else entirely".utf8).write(to: file)
        #expect(!(await engine.isIntact(file, sha1: abc)))
    }

    /// A URL keeps the answers it has already been given. Asked its size, then
    /// deleted, then asked again, it answered with the size it used to be —
    /// and the download that followed asked for the bytes after the end of a
    /// file that was not there, got nothing, and wrote nothing over the
    /// damaged image it had been sent to replace.
    @Test func aDeletedFileHasNoSize() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try write("x.ipsw", "abc", into: folder)
        let engine = SyncEngine()
        #expect(engine.fileSize(file) == 3)
        try FileManager.default.removeItem(at: file)
        #expect(engine.fileSize(file) == nil)
    }

    // MARK: What the newer build replaces

    @Test func theOldBuildGoesAndTheNewOneStays() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try write("iPhone18,5_27.0_24A437_Restore.ipsw", "old", into: folder)
        _ = try write("iPhone18,5_27.2_24B5084k_Restore.ipsw", "new", into: folder)
        let engine = SyncEngine()
        await engine.removeReplacedBuilds(
            in: folder,
            keeping: [firmware("iPhone18,5_27.2_24B5084k_Restore.ipsw", ["iPhone18,5"])],
            using: DeviceIndex(), log: { _ in })
        #expect(try images(in: folder) == ["iPhone18,5_27.2_24B5084k_Restore.ipsw"])
    }

    /// 27.0 shipped one image per device and 27.2 shipped one between three.
    /// All three old ones are replaced by the one new one.
    @Test func threeOldImagesGoWhenOneNewOneCoversThem() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        for device in ["iPhone19,2", "iPhone19,3", "iPhone19,7"] {
            _ = try write("\(device)_27.0_24A437_Restore.ipsw", "old", into: folder)
        }
        let merged = "iPhone19,2,iPhone19,3,iPhone19,7_27.2_24B5084k_Restore.ipsw"
        _ = try write(merged, "new", into: folder)
        let engine = SyncEngine()
        await engine.removeReplacedBuilds(
            in: folder,
            keeping: [firmware(merged, ["iPhone19,2", "iPhone19,3", "iPhone19,7"])],
            using: DeviceIndex(), log: { _ in })
        #expect(try images(in: folder) == [merged])
    }

    /// A device whose replacement is not here keeps the build it has.
    @Test func nothingGoesWithoutSomethingToReplaceIt() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try write("iPhone18,5_27.0_24A437_Restore.ipsw", "old", into: folder)
        _ = try write("iPhone18,4_27.0_24A437_Restore.ipsw", "old", into: folder)
        let engine = SyncEngine()
        // Only the iPhone 17e has a newer build here.
        await engine.removeReplacedBuilds(
            in: folder,
            keeping: [firmware("iPhone18,5_27.2_24B5084k_Restore.ipsw", ["iPhone18,5"])],
            using: DeviceIndex(), log: { _ in })
        #expect(try images(in: folder) == ["iPhone18,4_27.0_24A437_Restore.ipsw"])
    }

    /// Anything that is not a restore image, and anything whose devices cannot
    /// be worked out, is left where it is.
    @Test func whatIsNotUnderstoodIsLeftAlone() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try write("holiday.jpg", "photo", into: folder)
        _ = try write("something_renamed.ipsw", "mine", into: folder)
        _ = try write("iPhone18,5_27.0_24A437_Restore.ipsw", "old", into: folder)
        let engine = SyncEngine()
        await engine.removeReplacedBuilds(
            in: folder,
            keeping: [firmware("iPhone18,5_27.2_24B5084k_Restore.ipsw", ["iPhone18,5"])],
            using: DeviceIndex(), log: { _ in })
        #expect(try images(in: folder) == ["holiday.jpg", "something_renamed.ipsw"])
    }
}

/// Neither Mac app counted what it was about to fetch against the room left.
/// Every device Apple still signs is some two hundred images — about two
/// terabytes — and a drive with twenty-six gigabytes free was asked for all of
/// it, filled, and stopped answering.
struct RoomTests {
    @Test func whatFitsIsFetchedAndWhatDoesNotIsNot() async throws {
        let engine = SyncEngine()
        let folder = URL.temporaryDirectory
        guard let free = engine.freeSpace(at: folder) else { return }
        // A byte is always fine; the whole volume never is.
        #expect(engine.hasRoom(for: 1, in: folder))
        #expect(!engine.hasRoom(for: free + 1, in: folder))
        // Room is kept back on purpose, so filling it exactly is refused too.
        #expect(!engine.hasRoom(for: free, in: folder))
        #expect(!engine.hasRoom(for: free - SyncEngine.spareRoom + 1, in: folder))
        #expect(engine.hasRoom(for: free - SyncEngine.spareRoom, in: folder))
    }

    /// The old build goes as soon as the new one is here, so what it is
    /// holding is room the new one may use. A drive with one old copy of
    /// everything has room for a new copy of everything, and refusing that was
    /// refusing the whole point of the run.
    @Test func theBuildAboutToBeReplacedCountsAsRoom() async throws {
        let folder = URL.temporaryDirectory.appending(path: "room-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appending(path: "iPhone18,5_27.0_24A437_Restore.ipsw")
        try Data(repeating: 0x41, count: 4096).write(to: old)
        // Something else, for a device this one has nothing to do with.
        try Data(repeating: 0x42, count: 4096).write(to: folder.appending(path: "iPhone18,4_27.0_24A437_Restore.ipsw"))

        let engine = SyncEngine()
        let newer = Firmware(id: "n", name: "iPhone 17e", devices: ["iPhone18,5"],
                             filename: "iPhone18,5_27.2_24B5084k_Restore.ipsw",
                             url: URL(string: "https://updates.cdn-apple.com/x.ipsw")!,
                             sha1: nil, signed: true)
        // Only the build it replaces, not the one beside it.
        #expect(engine.reclaimableSpace(replacedBy: newer, in: folder, using: DeviceIndex()) == 4096)
    }

    /// Replacing an image needs only the difference, not the whole of it.
    @Test func whatIsAlreadyThereCounts() async throws {
        let engine = SyncEngine()
        let folder = URL.temporaryDirectory
        guard let free = engine.freeSpace(at: folder) else { return }
        let tooBig = free + (8 << 30)
        #expect(!engine.hasRoom(for: tooBig, in: folder))
        #expect(engine.hasRoom(for: tooBig, in: folder, alreadyHave: tooBig))
    }
}
