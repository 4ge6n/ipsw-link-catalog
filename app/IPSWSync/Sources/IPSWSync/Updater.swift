import AppKit
import CryptoKit
import Foundation
import Observation

/// What the repository says the current build is.
struct Appcast: Codable {
    let version: String
    let build: Int
    let url: URL
    let sha256: String
    let notes: String?
}

/// Keeps the app itself current, the same way it keeps the folders current:
/// read a small manifest, check a checksum, replace what is there.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case available(String)
        case downloading(Double)
        case installed(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    var lastChecked: Date?

    private let manifest = ProcessInfo.processInfo.environment["IPSW_APPCAST_URL"].flatMap(URL.init(string:))
        ?? URL(string: "https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/app/appcast.json")!

    var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func check(installAutomatically: Bool) async {
        guard state == .idle || isSettled else { return }
        state = .checking
        do {
            var request = URLRequest(url: manifest)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.noManifest }
            let appcast = try JSONDecoder().decode(Appcast.self, from: data)
            lastChecked = .now
            guard appcast.build > currentBuild else { state = .idle; return }
            state = .available(appcast.version)
            if installAutomatically { await install(appcast) }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func install(_ appcast: Appcast) async {
        state = .downloading(0)
        do {
            let archive = try await download(appcast)
            let replacement = try unpack(archive)
            try swapInPlace(replacement)
            state = .installed(appcast.version)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private var isSettled: Bool {
        if case .checking = state { return false }
        if case .downloading = state { return false }
        return true
    }

    private func download(_ appcast: Appcast) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: appcast.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.downloadFailed }
        // An update replaces the running app, so it is only trusted once the
        // bytes match what the manifest committed to.
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == appcast.sha256.lowercased() else { throw UpdateError.checksumMismatch }
        let file = URL.temporaryDirectory.appending(path: "IPSWSync-\(appcast.build).zip")
        try data.write(to: file, options: .atomic)
        return file
    }

    private func unpack(_ archive: URL) throws -> URL {
        let folder = URL.temporaryDirectory.appending(path: "IPSWSync-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(filePath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path(percentEncoded: false), folder.path(percentEncoded: false)]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw UpdateError.unpackFailed }
        let contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else { throw UpdateError.unpackFailed }
        return app
    }

    /// Swap the bundle and relaunch. The replacement is put beside the running
    /// copy first, so a failure leaves the working app where it was.
    private func swapInPlace(_ replacement: URL) throws {
        let current = Bundle.main.bundleURL
        let backup = current.appendingPathExtension("previous")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.moveItem(at: current, to: backup)
        do {
            try FileManager.default.moveItem(at: replacement, to: current)
        } catch {
            try? FileManager.default.moveItem(at: backup, to: current)
            throw error
        }
        try? FileManager.default.removeItem(at: backup)
        relaunch(current)
    }

    private func relaunch(_ app: URL) {
        let task = Process()
        task.executableURL = URL(filePath: "/bin/sh")
        // Wait for this process to go before opening the new copy.
        task.arguments = ["-c", "sleep 1; /usr/bin/open \(app.path(percentEncoded: false).replacing(" ", with: "\\ "))"]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApplication.shared.terminate(nil) }
    }
}

enum UpdateError: LocalizedError {
    case noManifest, downloadFailed, checksumMismatch, unpackFailed

    var errorDescription: String? {
        switch self {
        case .noManifest: "Could not read the update manifest."
        case .downloadFailed: "The update could not be downloaded."
        case .checksumMismatch: "The update did not match its checksum and was discarded."
        case .unpackFailed: "The update could not be unpacked."
        }
    }
}
