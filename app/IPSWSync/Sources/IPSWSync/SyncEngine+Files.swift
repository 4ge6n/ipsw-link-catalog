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
                          progress: @escaping (Int64) -> Void) async throws {
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SyncError.http(code, destination.lastPathComponent)
        }
        // A server that ignores the range restarts the file, so the partial copy goes.
        let appending = offset > 0 && http.statusCode == 206
        if !appending { try? FileManager.default.removeItem(at: destination) }
        FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        if appending { try handle.seekToEnd() }

        var buffer = Data(capacity: 1 << 20)
        var written: Int64 = appending ? offset : 0
        var lastReport = Date.distantPast
        for try await byte in stream {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if Date.now.timeIntervalSince(lastReport) > 0.2 {
                    lastReport = .now
                    progress(written)
                }
                // Asked once a megabyte rather than once a byte. Stop had been
                // read only between files, so it did nothing at all to the one
                // transfer a person was actually watching.
                if await isCancelled {
                    progress(written)
                    throw CancellationError()
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        progress(written)
    }

    nonisolated private func contentLength(_ url: URL) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        return response.expectedContentLength > 0 ? response.expectedContentLength : 0
    }

    nonisolated func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init)
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
        log: @escaping @Sendable @MainActor (LogEntry) -> Void
    ) async {
        let keepNames = Set(wanted.map(\.filename))
        let keepKeys = Set(wanted.map(\.modelKey))
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in contents where file.pathExtension == "ipsw" {
            let name = file.lastPathComponent
            guard !keepNames.contains(name) else { continue }
            let key = name.replacing(#/_[0-9][^_]*_[A-Za-z0-9]+_Restore\.ipsw$/#, with: "")
            // Only a device whose replacement is actually here loses its old build.
            guard key != name, keepKeys.contains(key) else { continue }
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
