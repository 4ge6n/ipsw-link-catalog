import Foundation

/// Where saved images live. The app's own Documents folder, which the Files app
/// shows as a place of its own, so what is fetched here can be moved to iCloud
/// Drive or an attached drive without this app doing the moving.
enum Library {
    static var folder: URL {
        URL.documentsDirectory
    }

    /// Where a transfer writes while it runs. A half-finished image in the
    /// folder above would show up in the Files app, and be taken for a saved
    /// one; kept aside, it is still there to carry on from.
    static var incoming: URL {
        let url = URL.documentsDirectory.appending(path: ".incoming")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Put a finished image where it can be seen.
    static func accept(_ name: String) throws {
        let from = incoming.appending(path: name)
        let to = folder.appending(path: name)
        try? FileManager.default.removeItem(at: to)
        try FileManager.default.moveItem(at: from, to: to)
    }

    struct Item: Identifiable, Hashable {
        let url: URL
        let size: Int64
        let saved: Date
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    static func contents() -> [Item] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let found = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return found
            .filter { $0.pathExtension == "ipsw" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return Item(url: url,
                            size: Int64(values?.fileSize ?? 0),
                            saved: values?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.saved > $1.saved }
    }

    static func remove(_ item: Item) throws {
        try FileManager.default.removeItem(at: item.url)
        VerifiedStore.shared.forget(item.url)
    }

    /// What is left on the device, so a nine-gigabyte image is not started with
    /// nowhere to put it.
    static var freeSpace: Int64? {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
