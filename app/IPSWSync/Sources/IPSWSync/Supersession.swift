import Foundation

/// Which build on the drive a newer one replaces.
///
/// Not by filename. Apple changes how it packages an image without warning:
/// the iPhone 18 Pro, iPhone 18 Pro Max (US) and iPhone 18 Pro Max (Global)
/// each had an image of their own at 27.0, and one image between them at 27.2.
/// Comparing names, the old three matched nothing and were kept for ever;
/// comparing the other way, after a split, the old combined one would be.
///
/// What does not change is which devices an image restores. A build is
/// replaced when every device it was for has a newer build here — which is
/// true of a merge, of a split, and of a rename, without knowing which
/// happened.
enum Supersession {
    /// The devices a file on the drive is for.
    ///
    /// The catalog first where it holds this very file, because the name is
    /// not the whole truth: iPhone10,6_11.2.6_15D100_Restore.ipsw is named for
    /// the GSM iPhone X alone and restores the global iPhone10,3 as well. Read
    /// from the name, the other half of the pair was invisible — its build was
    /// never seen as held, and an older one was never seen as replaced.
    ///
    /// Only for a file the catalog no longer lists does the name have to do,
    /// and the model-name table is the last resort under that.
    static func devices(of filename: String, using index: DeviceIndex) -> [String] {
        if let exact = index.exact(filename) { return exact }
        let written = Firmware.devices(in: filename)
        return written.isEmpty ? index.devices(for: filename) : written
    }

    /// Whether `filename` has been replaced by something in `wanted`.
    ///
    /// Every device it was for must be covered, and the file itself must not be
    /// one of the ones wanted. A file whose devices cannot be worked out at all
    /// is never replaced: not knowing what something is for is not a reason to
    /// delete it.
    static func isReplaced(_ filename: String, by wanted: [Firmware], using index: DeviceIndex) -> Bool {
        guard !wanted.contains(where: { $0.filename == filename }) else { return false }
        let mine = Set(devices(of: filename, using: index))
        guard !mine.isEmpty else { return false }
        let covered = Set(wanted.flatMap(\.devices))
        return mine.isSubset(of: covered)
    }

    /// Whether any file on the drive is for `device` at this build — the
    /// question "have I already got this one", asked of a device rather than
    /// of a filename, so a merge does not hide what is already here.
    static func holds(_ device: String, among filenames: [String], using index: DeviceIndex) -> Bool {
        filenames.contains { devices(of: $0, using: index).contains(device) }
    }
}
