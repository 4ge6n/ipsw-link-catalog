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
    /// linking: it looks here and nowhere else. Nothing for the platforms
    /// Finder does not restore — a Mac, a HomePod and a Vision Pro are
    /// restored from somewhere else entirely, so there is no folder to point.
    static func folderName(for platform: Platform) -> String? {
        switch platform {
        case .ios: "iPhone Software Updates"
        case .ipados: "iPad Software Updates"
        case .ipod: "iPod Software Updates"
        case .tvos: "Apple TV Software Updates"
        case .audioos, .visionos, .macos: nil
        }
    }

    /// The platforms there is anything to link at all.
    static var linkable: [Platform] { Platform.allCases.filter { folderName(for: $0) != nil } }

    static func url(for platform: Platform, inside home: URL = .init(filePath: NSHomeDirectory())) -> URL? {
        guard let name = folderName(for: platform) else { return nil }
        return home.appending(path: "Library/iTunes").appending(path: name)
    }

    static func state(for platform: Platform, inside home: URL = .init(filePath: NSHomeDirectory())) -> State {
        guard let path = url(for: platform, inside: home) else { return .missing }
        let manager = FileManager.default
        if let destination = try? manager.destinationOfSymbolicLink(atPath: path.path(percentEncoded: false)) {
            return .linked(to: URL(filePath: destination))
        }
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: path.path(percentEncoded: false), isDirectory: &directory) else {
            return .missing
        }
        guard directory.boolValue else { return .somethingElse(String(localized: "A file is in the way.")) }
        let contents = (try? manager.contentsOfDirectory(atPath: path.path(percentEncoded: false)))?
            .filter { $0 != ".DS_Store" } ?? []
        return contents.isEmpty ? .emptyFolder : .folder(count: contents.count)
    }

    /// Replace the standard folder with a link to `folder`. A folder with
    /// anything in it is left alone: its contents are moved first, and only
    /// then is the empty shell replaced.
    static func link(_ platform: Platform, to folder: URL,
                     inside home: URL = .init(filePath: NSHomeDirectory())) throws {
        guard let path = url(for: platform, inside: home) else { throw LinkError.notLinkable }
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
        guard let path = url(for: platform, inside: home) else { throw LinkError.notLinkable }
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
        guard let path = url(for: platform, inside: home) else { throw LinkError.notLinkable }
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
    case notLinkable

    var errorDescription: String? {
        switch self {
        case .folderNotEmpty(let count):
            String(format: String(localized: "The standard folder already holds %lld item(s); move them first."), count)
        case .inTheWay(let why): why
        case .wouldOverwrite(let names):
            String(format: String(localized: "%1$lld file(s) are already in the destination, so nothing was moved: %2$@"),
                   names.count, names.prefix(3).joined(separator: ", "))
        case .notLinked: String(localized: "The standard folder is not a link.")
        case .notLinkable: String(localized: "Finder does not restore this platform, so there is no folder to point.")
        }
    }
}
