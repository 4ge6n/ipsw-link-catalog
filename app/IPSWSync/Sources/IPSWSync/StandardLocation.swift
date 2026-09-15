import Foundation

/// The folder Finder restores from. Pointing it at the drive the images
/// actually live on means a restore finds them without copying anything.
enum StandardLocation {
    enum State: Equatable {
        case missing
        case emptyFolder
        case folder(count: Int)
        case linked(to: URL)
        case somethingElse(String)
    }

    /// Finder's name for each platform's folder, which is the whole point of
    /// linking: it looks here and nowhere else.
    static func folderName(for platform: Platform) -> String {
        platform == .ios ? "iPhone Software Updates" : "iPad Software Updates"
    }

    static func url(for platform: Platform, inside home: URL = .init(filePath: NSHomeDirectory())) -> URL {
        home.appending(path: "Library/iTunes").appending(path: folderName(for: platform))
    }

    static func state(for platform: Platform, inside home: URL = .init(filePath: NSHomeDirectory())) -> State {
        let path = url(for: platform, inside: home)
        let manager = FileManager.default
        if let destination = try? manager.destinationOfSymbolicLink(atPath: path.path(percentEncoded: false)) {
            return .linked(to: URL(filePath: destination))
        }
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: path.path(percentEncoded: false), isDirectory: &directory) else {
            return .missing
        }
        guard directory.boolValue else { return .somethingElse("A file is in the way.") }
        let contents = (try? manager.contentsOfDirectory(atPath: path.path(percentEncoded: false)))?
            .filter { $0 != ".DS_Store" } ?? []
        return contents.isEmpty ? .emptyFolder : .folder(count: contents.count)
    }

    /// Replace the standard folder with a link to `folder`. A folder with
    /// anything in it is left alone: its contents are moved first, and only
    /// then is the empty shell replaced.
    static func link(_ platform: Platform, to folder: URL,
                     inside home: URL = .init(filePath: NSHomeDirectory())) throws {
        let path = url(for: platform, inside: home)
        let manager = FileManager.default
        try manager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch state(for: platform, inside: home) {
        case .linked:
            try manager.removeItem(at: path)
        case .emptyFolder:
            // Finder leaves a .DS_Store behind; removeItem, not rmdir, for that.
            try manager.removeItem(at: path)
        case .folder(let count):
            throw LinkError.folderNotEmpty(count)
        case .somethingElse(let why):
            throw LinkError.inTheWay(why)
        case .missing:
            break
        }
        try manager.createSymbolicLink(at: path, withDestinationURL: folder)
    }

    /// Move what the standard folder holds into `folder`, then link it.
    /// A name already present at the destination is never overwritten.
    @discardableResult
    static func moveContentsThenLink(_ platform: Platform, to folder: URL,
                                     inside home: URL = .init(filePath: NSHomeDirectory())) throws -> (moved: Int, kept: [String]) {
        let path = url(for: platform, inside: home)
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var moved = 0
        var kept: [String] = []
        for name in (try? manager.contentsOfDirectory(atPath: path.path(percentEncoded: false))) ?? [] {
            let source = path.appending(path: name)
            let destination = folder.appending(path: name)
            if name == ".DS_Store" { try? manager.removeItem(at: source); continue }
            if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
                kept.append(name)
                continue
            }
            try manager.moveItem(at: source, to: destination)
            moved += 1
        }
        guard kept.isEmpty else { throw LinkError.wouldOverwrite(kept) }
        try link(platform, to: folder, inside: home)
        return (moved, kept)
    }

    /// Put an ordinary empty folder back where the link was.
    static func unlink(_ platform: Platform, inside home: URL = .init(filePath: NSHomeDirectory())) throws {
        let path = url(for: platform, inside: home)
        let manager = FileManager.default
        guard case .linked = state(for: platform, inside: home) else { throw LinkError.notLinked }
        try manager.removeItem(at: path)
        try manager.createDirectory(at: path, withIntermediateDirectories: true)
    }
}

enum LinkError: LocalizedError {
    case folderNotEmpty(Int)
    case inTheWay(String)
    case wouldOverwrite([String])
    case notLinked

    var errorDescription: String? {
        switch self {
        case .folderNotEmpty(let count):
            "The standard folder already holds \(count) item(s); move them first."
        case .inTheWay(let why): why
        case .wouldOverwrite(let names):
            "\(names.count) file(s) are already in the destination, so nothing was moved: \(names.prefix(3).joined(separator: ", "))"
        case .notLinked: "The standard folder is not a link."
        }
    }
}
