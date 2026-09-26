import CryptoKit
import Foundation

extension SyncEngine {
    /// Download one file if the folder does not already hold it intact.
    /// What came of one attempt at one file.
    enum Outcome: Sendable, Equatable {
        /// On the drive and matching Apple's checksum, whether it arrived
        /// now or was already there.
        case landed
        /// Did not fit while other transfers were writing. Worth one more
        /// go once they have finished, when the only room in question is
        /// its own predecessor's.
        case noRoom
        /// The line gave out. Worth another go in a moment.
        case worthAnotherGo
        /// Not worth asking again this run: stopped, or Apple's own copy
        /// does not match Apple's own checksum.
        case settled
    }

    @discardableResult
    nonisolated func fetch(
        _ firmware: Firmware,
        into folder: URL,
        /// What the run will delete once this one is here, so the room it is
        /// about to give back counts as room. Nothing is reclaimed when the
        /// run is not pruning, because then nothing is deleted.
        reclaiming index: DeviceIndex? = nil,
        report: @escaping @Sendable @MainActor (Transfer) -> Void,
        log: @escaping @Sendable @MainActor (LogEntry) -> Void
    ) async -> Outcome {
        let destination = folder.appending(path: firmware.filename)
        var transfer = Transfer(id: firmware.id, name: firmware.filename, device: firmware.name)
        transfer.state = .checking
        await report(transfer)

        if await isIntact(destination, sha1: firmware.sha1) {
            transfer.state = .done(alreadyHad: true)
            await report(transfer)
            await log(LogEntry(kind: .info, message: String(format: String(localized: "Already have %@"), firmware.filename)))
            return .landed
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
                return .landed
            }
            // A file that is already the full length but hashes wrong is damaged,
            // not partial, so resuming would only append to the damage.
            if let size = onDisk, expected > 0, size >= expected {
                try? FileManager.default.removeItem(at: destination)
                await log(LogEntry(kind: .warning, message: String(format: String(localized: "Refetching %@: the copy on disk did not match"), firmware.filename)))
            }
            transfer.total = expected
            // Asked before a byte is fetched. Without this the run filled the
            // drive: every device Apple still signs is some two hundred images,
            // and nothing was counting them against the room left.
            let reclaimable = index.map { reclaimableSpace(replacedBy: firmware, in: folder, using: $0) } ?? 0
            guard hasRoom(for: expected, in: folder, alreadyHave: (onDisk ?? 0) + reclaimable) else {
                let free = freeSpace(at: folder) ?? 0
                transfer.state = .failed(String(localized: "not enough room"))
                await report(transfer)
                await log(LogEntry(kind: .bad, message: String(format: String(localized: "No room for %1$@: it needs %2$@ and %3$@ is free."),
                                                               firmware.filename,
                                                               ByteCountFormatter.string(fromByteCount: expected, countStyle: .file),
                                                               ByteCountFormatter.string(fromByteCount: free, countStyle: .file))))
                // Another go will find the same drive with the same room on it.
                return .noRoom
            }
            for attempt in 1...2 {
                transfer.resumedFrom = fileSize(destination) ?? 0
                transfer.received = transfer.resumedFrom
                transfer.startedAt = .now
                // The queue is here, not around the whole of this: a file
                // waits for a place on the line, gives it up the moment the
                // last byte lands, and is hashed outside it.
                transfer.state = .queued
                await report(transfer)
                await downloads.enter()
                // Room is claimed, not just looked at. Six transfers used to
                // look at the same free space, each see enough for itself,
                // and start together — and the drive filled under all six at
                // once, leaving six part-files that each held room the others
                // needed. What a transfer is about to write is set aside for
                // it while it writes, and counted against everyone else.
                let needed = max(0, expected - (fileSize(destination) ?? 0))
                // The builds this one replaces are going at the end of the run
                // anyway. When their room is what makes the difference, they
                // go now, and the room they leave is this transfer's: removed
                // and claimed in one step, so another transfer cannot take it
                // in between and leave this device with neither build.
                let replaced = index.map { replacedFiles(by: firmware, in: folder, using: $0) } ?? []
                let claim = await claimRoom(needed, in: folder, replacing: replaced)
                for name in claim.removed {
                    await log(LogEntry(kind: .info, message: String(format: String(localized: "Removed older build %1$@ first, to make room for %2$@"),
                                                                   name, firmware.filename)))
                }
                let roomHeld = claim.held
                guard roomHeld else {
                    await downloads.leave()
                    let free = freeSpace(at: folder) ?? 0
                    transfer.state = .failed(String(localized: "not enough room"))
                    await report(transfer)
                    await log(LogEntry(kind: .bad, message: String(format: String(localized: "No room for %1$@: it needs %2$@ and %3$@ is free."),
                                                                   firmware.filename,
                                                                   ByteCountFormatter.string(fromByteCount: needed, countStyle: .file),
                                                                   ByteCountFormatter.string(fromByteCount: free, countStyle: .file))))
                    return .noRoom
                }
                transfer.state = .downloading
                transfer.startedAt = .now
                await report(transfer)
                do {
                    try await carryOn(firmware, to: destination, from: &transfer, report: report, log: log)
                    await releaseRoom(needed, in: folder)
                    await downloads.leave()
                } catch {
                    await releaseRoom(needed, in: folder)
                    await downloads.leave()
                    // A drive that filled anyway — another program wrote to
                    // it — is not a line that dropped. The part-file cannot
                    // be finished and only holds room something else could
                    // use, and asking again in twenty seconds finds the same
                    // full drive.
                    if Self.isOutOfSpace(error) {
                        try? FileManager.default.removeItem(at: destination)
                        transfer.state = .failed(String(localized: "not enough room"))
                        await report(transfer)
                        await log(LogEntry(kind: .bad, message: String(format: String(localized: "The drive filled while %@ was arriving; what arrived was removed."), firmware.filename)))
                        return .noRoom
                    }
                    throw error
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
            return .landed
        } catch is CancellationError {
            transfer.state = .waiting
            await report(transfer)
            await log(LogEntry(kind: .warning, message: String(format: String(localized: "Stopped %@; what arrived is kept to carry on from"), firmware.filename)))
            return .settled
        } catch {
            transfer.state = .failed(error.localizedDescription)
            await report(transfer)
            await log(LogEntry(kind: .bad, message: error.localizedDescription))
            // A checksum that will not match is Apple's copy against Apple's
            // own number, and asking again in thirty seconds cannot change it;
            // anything else is the line, which can.
            if case SyncError.checksumMismatch = error { return .settled }
            return .worthAnotherGo
        }
    }

    /// Fetch it, and pick it up again if the connection gives out.
    ///
    /// A twelve gigabyte transfer is minutes long, and a connection that
    /// drops once in those minutes used to end it: the whole file was marked
    /// failed and left for the next day's run. What has arrived is on disk
    /// already, so carrying on from it costs nothing — and a transfer that is
    /// still making progress is not one to give up on.
    nonisolated private func carryOn(
        _ firmware: Firmware,
        to destination: URL,
        from transfer: inout Transfer,
        report: @escaping @Sendable @MainActor (Transfer) -> Void,
        log: @escaping @Sendable @MainActor (LogEntry) -> Void
    ) async throws {
        var lastFailure: Error?
        for attempt in 1...4 {
            var held = transfer
            do {
                try await download(firmware.url, to: destination, from: held.resumedFrom) { received in
                    held.received = received
                    Task { @MainActor in report(held) }
                }
                transfer = held
                return
            } catch is CancellationError {
                transfer = held
                throw CancellationError()
            } catch {
                lastFailure = error
                let sofar = fileSize(destination) ?? 0
                // Nothing arrived this time either: the connection is not
                // coming back within this run.
                guard attempt < 4 else { break }
                await log(LogEntry(kind: .warning, message: String(format: String(localized: "%1$@ stopped at %2$@; carrying on from there"),
                                                                   firmware.filename,
                                                                   ByteCountFormatter.string(fromByteCount: sofar, countStyle: .file))))
                try? await Task.sleep(for: .seconds(Double(attempt) * 2))
                if await isCancelled { throw CancellationError() }
                transfer.resumedFrom = sofar
                transfer.received = sofar
                transfer.startedAt = .now
            }
        }
        throw lastFailure ?? SyncError.http(0, firmware.filename)
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
    /// What the builds this one replaces are taking up. Once it is here they
    /// go, so what they hold is room this transfer may use — a drive with one
    /// old copy of everything has room for a new copy of everything.
    /// The files on the drive that this build replaces.
    nonisolated func replacedFiles(by firmware: Firmware, in folder: URL,
                                   using index: DeviceIndex) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents.filter {
            $0.pathExtension == "ipsw"
            && Supersession.isReplaced($0.lastPathComponent, by: [firmware], using: index)
        }
    }

    nonisolated func reclaimableSpace(replacedBy firmware: Firmware, in folder: URL,
                                      using index: DeviceIndex) -> Int64 {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.pathExtension == "ipsw" }
            .filter { Supersession.isReplaced($0.lastPathComponent, by: [firmware], using: index) }
            .compactMap { fileSize($0) }
            .reduce(0, +)
    }

    /// How much room is left where these are being kept.
    /// What can be written to the folder's drive right now.
    ///
    /// Asked of the file system each time. A URL keeps the answers it has
    /// been given, so the same folder asked twice reported the room it had
    /// the first time, however much had been written since. And it is the
    /// room actually free, not the "important usage" figure, which counts
    /// space the system could purge — a promise, on an external drive, that
    /// the write does not get to cash.
    nonisolated func freeSpace(at folder: URL) -> Int64? {
        var stats = statfs()
        guard statfs(folder.path(percentEncoded: false), &stats) == 0 else { return nil }
        return Int64(stats.f_bavail) * Int64(stats.f_bsize)
    }

    /// Which drive a folder is on, so two folders on one drive share one
    /// account of what has been set aside.
    nonisolated func volume(of folder: URL) -> String {
        var stats = statfs()
        guard statfs(folder.path(percentEncoded: false), &stats) == 0 else {
            return folder.path(percentEncoded: false)
        }
        return withUnsafeBytes(of: stats.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// Whether an error is the drive being full, however it was phrased.
    nonisolated static func isOutOfSpace(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(underlying) }
        return false
    }

    /// Whether one more image of this size can be taken without filling the
    /// drive. A little is always left: a volume with nothing free at all stops
    /// being a volume that anything — this app included — can work on.
    nonisolated func hasRoom(for bytes: Int64, in folder: URL, alreadyHave onDisk: Int64 = 0) -> Bool {
        guard bytes > 0, let free = freeSpace(at: folder) else { return true }
        return bytes - onDisk + Self.spareRoom <= free
    }

    /// Kept free whatever happens.
    nonisolated static let spareRoom: Int64 = 2 << 30

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
        var done = false
        while !done {
            // Each chunk comes back autoreleased, and nothing drains the pool
            // inside a loop of one's own making. Hashing a ten gigabyte image
            // therefore held all ten of them at once — and the daily run hashes
            // whatever is already on the drive, which is why this only showed
            // itself on a drive that already had something on it.
            try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty else {
                    done = true
                    return
                }
                hasher.update(data: chunk)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Remove the build each newly present file replaces, and nothing else.
    /// Clear away what a failed transfer left behind.
    ///
    /// A file that is not wanted is normally left alone — someone may have put
    /// it there on purpose, and this app does not tidy other people's drives.
    /// The exception is its own wreckage: a part-file from a device that was
    /// later unticked stayed for ever, counted against the room, and looked
    /// from the outside exactly like an image that was already there.
    ///
    /// Only a file the catalog can name and measure is touched, and only when
    /// it is short of the length Apple gives for it. A file of the right
    /// length is a real image, wanted or not, and is left where it is.
    nonisolated func removeFailedRemnants(
        in folder: URL,
        keeping wanted: [Firmware],
        using index: DeviceIndex,
        log: @escaping @Sendable @MainActor (LogEntry) -> Void
    ) async {
        let manager = FileManager.default
        let contents = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let keep = Set(wanted.map(\.filename))
        for file in contents {
            let name = file.lastPathComponent
            // A quarantined copy is damaged by definition: it was fetched
            // twice and hashed wrong both times.
            if file.pathExtension == "sha1-mismatch" {
                try? manager.removeItem(at: file)
                await log(LogEntry(kind: .info, message: String(format: String(localized: "Removed the damaged copy left behind by %@"), name)))
                continue
            }
            guard file.pathExtension == "ipsw", !keep.contains(name),
                  let link = index.link(for: name), let onDisk = fileSize(file),
                  let expected = try? await contentLength(link), expected > 0,
                  onDisk < expected
            else { continue }
            do {
                try manager.removeItem(at: file)
                VerifiedStore.shared.forget(file)
                await log(LogEntry(kind: .info, message: String(format: String(localized: "Removed an unfinished %1$@ (%2$@ of %3$@) that is no longer wanted"),
                                                               name,
                                                               ByteCountFormatter.string(fromByteCount: onDisk, countStyle: .file),
                                                               ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))))
            } catch {
                await log(LogEntry(kind: .warning, message: String(format: String(localized: "Could not remove %1$@: %2$@"), name, error.localizedDescription)))
            }
        }
    }

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
