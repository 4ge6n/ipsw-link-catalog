import CryptoKit
import Foundation

extension SyncEngine {
    /// Download one file if the folder does not already hold it intact.
    nonisolated func fetch(
        _ firmware: Firmware,
        into folder: URL,
        report: @escaping @Sendable @MainActor (Transfer) -> Void,
        log: @escaping @Sendable @MainActor (LogEntry) -> Void
    ) async {
        let destination = folder.appending(path: firmware.filename)
        var transfer = Transfer(id: firmware.id, name: firmware.filename, device: firmware.name)
        transfer.state = .checking
        await report(transfer)

        if await isIntact(destination, sha1: firmware.sha1) {
            transfer.state = .done(alreadyHad: true)
            await report(transfer)
            await log(LogEntry(kind: .info, message: String(format: String(localized: "Already have %@"), firmware.filename)))
            return
        }
        do {
            let expected = try await contentLength(firmware.url)
            let onDisk = fileSize(destination)
            // Apple publishes no checksum for some older images, and without one
            // the length is the only thing there is to go on. Treating that as a
            // failed check threw the file away and fetched it again on every run,
            // which could never learn anything the run before had not.
            if firmware.sha1 == nil, let size = onDisk, expected > 0, size == expected {
                transfer.total = expected
                transfer.received = size
                transfer.state = .done(alreadyHad: true)
                await report(transfer)
                await log(LogEntry(kind: .info, message: String(format: String(localized: "Already have %@"), firmware.filename)))
                return
            }
            // A file that is already the full length but hashes wrong is damaged,
            // not partial, so resuming would only append to the damage.
            if let size = onDisk, expected > 0, size >= expected {
                try? FileManager.default.removeItem(at: destination)
                await log(LogEntry(kind: .warning, message: String(format: String(localized: "Refetching %@: the copy on disk did not match"), firmware.filename)))
            }
            transfer.total = expected
            for attempt in 1...2 {
                transfer.resumedFrom = fileSize(destination) ?? 0
                transfer.received = transfer.resumedFrom
                transfer.startedAt = .now
                transfer.state = .downloading
                await report(transfer)
                try await download(firmware.url, to: destination, from: transfer.resumedFrom) { received in
                    transfer.received = received
                    Task { @MainActor in report(transfer) }
                }
                transfer.state = .verifying
                await report(transfer)
                guard let sha1 = firmware.sha1 else { break }
                if await isIntact(destination, sha1: sha1) { break }
                if attempt == 1 {
                    // A resumed transfer can inherit damage from what was there.
                    try? FileManager.default.removeItem(at: destination)
                    await log(LogEntry(kind: .warning, message: String(format: String(localized: "Checksum did not match; fetching %@ whole"), firmware.filename)))
                    continue
                }
                let quarantine = destination.appendingPathExtension("sha1-mismatch")
                try? FileManager.default.removeItem(at: quarantine)
                try? FileManager.default.moveItem(at: destination, to: quarantine)
                throw SyncError.checksumMismatch(firmware.filename)
            }
            transfer.state = .done(alreadyHad: false)
            await report(transfer)
            await log(LogEntry(kind: .good, message: String(format: String(localized: firmware.sha1 == nil ? "Downloaded %@" : "Downloaded %@, SHA-1 verified"), firmware.filename)))
        } catch is CancellationError {
            transfer.state = .waiting
            await report(transfer)
            await log(LogEntry(kind: .warning, message: String(format: String(localized: "Stopped %@; what arrived is kept to carry on from"), firmware.filename)))
        } catch {
            transfer.state = .failed(error.localizedDescription)
            await report(transfer)
            await log(LogEntry(kind: .bad, message: error.localizedDescription))
        }
    }

    /// Append to whatever is already on disk rather than starting over.
    nonisolated private func download(_ url: URL, to destination: URL, from offset: Int64,
                          progress: @escaping @Sendable (Int64) -> Void) async throws {
        let receiver = Receiver(to: destination, from: offset,
                                progress: progress, shouldStop: await stopRequested)
        try await receiver.receive(url, using: Self.transferConfiguration)
    }

    /// The same settings the rest of the app uses, minus the cache: a ten
    /// gigabyte image has nothing to gain from being remembered.
    nonisolated static var transferConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return configuration
    }

    nonisolated private func contentLength(_ url: URL) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        return response.expectedContentLength > 0 ? response.expectedContentLength : 0
    }

    /// How big the file is right now.
    ///
    /// Not through URL.resourceValues: a URL keeps the answers it has already
    /// been given, so a file this app had just deleted still reported its old
    /// size. The next download then asked for the bytes after the end of a
    /// file that was not there, got an empty answer, and wrote an empty file
    /// over the damaged one it was sent to replace.
    nonisolated func fileSize(_ url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    /// Hashing hundreds of gigabytes on every run is not affordable, so a file
    /// whose size and modification date still match what was verified before is
    /// taken on trust; anything else is hashed.
    /// Read every image in a folder against Apple's own SHA-1 — not the record
    /// of having done so, but the bytes. A daily run trusts that record so it
    /// need not read a terabyte every night; this is for when you want to know
    /// rather than to be told.
    func verify(_ platform: Platform, in folder: URL,
                report: @escaping @Sendable @MainActor (Transfer) -> Void,
                log: @escaping @Sendable @MainActor (LogEntry) -> Void) async throws {
        resetCancellation()
        try checkVolume(folder)
        let known = try await everyBuild(platform, channel: .release)
            + everyBuild(platform, channel: .beta)
        var sums: [String: String] = [:]
        for release in known {
            for firmware in release.firmwares where firmware.sha1 != nil {
                sums[firmware.filename] = firmware.sha1
            }
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
            .filter { $0.hasSuffix(".ipsw") }.sorted()
        guard !names.isEmpty else {
            await log(LogEntry(kind: .info, message: String(format: String(localized: "Nothing to check in %@"), folder.lastPathComponent)))
            return
        }
        var good = 0, bad = 0, unknown = 0
        for name in names {
            if isCancelled { break }
            let file = folder.appending(path: name)
            var transfer = Transfer(id: name, name: name, device: name)
            transfer.state = .verifying
            await report(transfer)
            guard let sha1 = sums[name] else {
                unknown += 1
                transfer.state = .done(alreadyHad: true)
                await report(transfer)
                await log(LogEntry(kind: .warning, message: String(format: String(localized: "%@ — Apple publishes no checksum for this one"), name)))
                continue
            }
            // Read the bytes rather than the note saying they were read.
            VerifiedStore.shared.forget(file)
            if await isIntact(file, sha1: sha1) {
                good += 1
                transfer.state = .done(alreadyHad: true)
                await report(transfer)
            } else {
                bad += 1
                transfer.state = .failed(String(localized: "does not match"))
                await report(transfer)
                await log(LogEntry(kind: .bad, message: String(format: String(localized: "%@ does not match Apple's checksum."), name)))
            }
        }
        await log(LogEntry(kind: bad == 0 ? .good : .bad,
                           message: String(format: String(localized: "Checked %1$lld: %2$lld matched, %3$lld did not, %4$lld had nothing to check against."),
                                           names.count, good, bad, unknown)))
    }

    nonisolated func isIntact(_ url: URL, sha1: String?) async -> Bool {
        guard let sha1, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return false }
        if VerifiedStore.shared.matches(url, sha1: sha1) { return true }
        guard let digest = try? sha1OfFile(url), digest == sha1.lowercased() else { return false }
        VerifiedStore.shared.remember(url, sha1: sha1)
        return true
    }

    nonisolated private func sha1OfFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Remove the build each newly present file replaces, and nothing else.
    nonisolated func removeReplacedBuilds(
        in folder: URL,
        keeping wanted: [Firmware],
        using index: DeviceIndex,
        log: @escaping @Sendable @MainActor (LogEntry) -> Void
    ) async {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in contents where file.pathExtension == "ipsw" {
            let name = file.lastPathComponent
            // Only a build whose every device has a newer one here is removed.
            guard Supersession.isReplaced(name, by: wanted, using: index) else { continue }
            do {
                try FileManager.default.removeItem(at: file)
                VerifiedStore.shared.forget(file)
                await log(LogEntry(kind: .info, message: String(format: String(localized: "Removed older build %@"), name)))
            } catch {
                await log(LogEntry(kind: .warning, message: String(format: String(localized: "Could not remove %1$@: %2$@"), name, error.localizedDescription)))
            }
        }
    }
}
