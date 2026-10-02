import Foundation

/// Transfers that carry on when the app is put away. A streamed request is ended
/// by iOS within seconds of the app leaving the screen, and a restore image is
/// not a seconds-long download; a background session is handed to the system
/// instead, which finishes it and wakes the app to say so — even if the app was
/// closed in the meantime.
final class BackgroundDownloads: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundDownloads()

    /// What the app needs to remember about a transfer to finish it later. The
    /// app may be gone and started again by the time this matters, so it is
    /// written down rather than held.
    private struct Pending: Codable {
        let id: String
        let filename: String
        let device: String
        let sha1: String?
        let platform: String?
    }

    /// Handed over when the system wakes the app to say a transfer finished, and
    /// called once what arrived has been dealt with.
    var whenWokenFinished: (() -> Void)?

    /// The interface listens through these.
    var report: (@Sendable @MainActor (Transfer) -> Void)?
    var log: (@Sendable @MainActor (LogEntry) -> Void)?
    var settled: (@Sendable @MainActor () -> Void)?

    private var session: URLSession!
    private let defaults = UserDefaults.standard
    private let pendingKey = "pendingDownloads"
    private let progressLock = NSLock()
    private var loggedProgress: [String: Int] = [:]
    /// The system's completion handler must wait for checksum and file landing,
    /// not merely for the delegate to hand us the temporary download URL.
    private let checks = DispatchGroup()

    private override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "com.github.4ge6n.ipsw-link-catalog.IPSWBrowser.downloads")
        // Asked for straight away rather than left to the system to schedule,
        // because it was asked for by someone looking at the screen.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Adopt whatever the system was still carrying, so the interface shows it.
    func resumeReporting() {
        session.getAllTasks { tasks in
            DiagnosticJournal.shared.record("detail", area: "background", event: "adopt",
                                            "URLSession has \(tasks.count) task(s)")
            for task in tasks {
                guard let url = task.originalRequest?.url, let pending = self.pending(for: url) else { continue }
                DiagnosticJournal.shared.record("info", area: "transfer", event: "resumed_reporting",
                                                "\(pending.filename): received=\(task.countOfBytesReceived), expected=\(task.countOfBytesExpectedToReceive) bytes",
                                                transferID: pending.id, platform: pending.platform)
                var transfer = Transfer(id: pending.id, name: pending.filename, device: pending.device)
                transfer.state = .downloading
                transfer.received = task.countOfBytesReceived
                transfer.total = task.countOfBytesExpectedToReceive
                self.tell(transfer)
            }
        }
    }

    var isRunning: Bool { !record.isEmpty }

    func isRunning(_ firmware: Firmware) -> Bool { pending(for: firmware.url) != nil }

    func start(_ firmware: Firmware) {
        guard pending(for: firmware.url) == nil else { return }
        let platform = Platform.allCases.first { $0.covers(firmware) }?.rawValue
        remember(Pending(id: firmware.id, filename: firmware.filename,
                         device: firmware.name, sha1: firmware.sha1,
                         platform: platform), for: firmware.url)
        DiagnosticJournal.shared.record("info", area: "transfer", event: "started",
                                        "\(firmware.filename): host=\(firmware.url.host() ?? "?"), checksum=\(firmware.sha1 == nil ? "none" : "SHA-1")",
                                        transferID: firmware.id, platform: platform)
        var transfer = Transfer(id: firmware.id, name: firmware.filename, device: firmware.name)
        transfer.state = .downloading
        tell(transfer)
        session.downloadTask(with: firmware.url).resume()
    }

    func stop(_ firmware: Firmware) {
        session.getAllTasks { tasks in
            for task in tasks where task.originalRequest?.url == firmware.url { task.cancel() }
        }
    }

    // MARK: - What the system hands back

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let url = downloadTask.originalRequest?.url, let pending = pending(for: url) else { return }
        var transfer = Transfer(id: pending.id, name: pending.filename, device: pending.device)
        transfer.state = .downloading
        transfer.received = totalBytesWritten
        transfer.total = totalBytesExpectedToWrite
        tell(transfer)
        let bucket = totalBytesExpectedToWrite > 0
            ? Int(min(10, totalBytesWritten * 10 / totalBytesExpectedToWrite))
            : Int(totalBytesWritten / (512 * 1024 * 1024))
        progressLock.lock()
        let previous = loggedProgress[pending.id] ?? 0
        if bucket > previous { loggedProgress[pending.id] = bucket }
        progressLock.unlock()
        if bucket > previous {
            DiagnosticJournal.shared.record("detail", area: "transfer", event: "progress",
                                            "\(pending.filename): \(totalBytesWritten)/\(totalBytesExpectedToWrite) bytes",
                                            transferID: pending.id, platform: pending.platform)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let url = downloadTask.originalRequest?.url, let pending = pending(for: url) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        DiagnosticJournal.shared.record((200...299).contains(status) ? "info" : "error",
                                        area: "transfer", event: "response",
                                        "\(pending.filename): HTTP \(status), received=\(downloadTask.countOfBytesReceived) bytes",
                                        transferID: pending.id, platform: pending.platform)
        guard (200...299).contains(status) else {
            finish(url, pending, failure: "HTTP \(status)")
            return
        }
        // What arrives here is swept away the moment this method returns, so it
        // is moved before anything else is done with it.
        let staged = Library.incoming.appending(path: pending.filename)
        try? FileManager.default.removeItem(at: staged)
        do {
            try FileManager.default.moveItem(at: location, to: staged)
        } catch {
            DiagnosticJournal.shared.recordError(error, area: "transfer", event: "stage_failed",
                                                 pending.filename, transferID: pending.id,
                                                 platform: pending.platform)
            finish(url, pending, failure: error.localizedDescription)
            return
        }
        checks.enter()
        Task.detached {
            await self.check(staged, url: url, pending: pending)
            self.checks.leave()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let url = task.originalRequest?.url, let pending = pending(for: url) else { return }
        guard let error else { return }   // success is dealt with above
        if (error as? URLError)?.code == .cancelled {
            forget(url)
            tellLog(.warning, String(format: String(localized: "Stopped %@; what arrived is kept to carry on from"), pending.filename),
                    event: "cancelled", pending: pending)
            settle()
        } else {
            DiagnosticJournal.shared.recordError(error, area: "transfer", event: "network_failed",
                                                 pending.filename, transferID: pending.id,
                                                 platform: pending.platform)
            finish(url, pending, failure: error.localizedDescription)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DiagnosticJournal.shared.record("detail", area: "background", event: "events_finished",
                                        "URLSession callbacks ended; waiting for file checks")
        checks.notify(queue: .main) {
            let handler = self.whenWokenFinished
            self.whenWokenFinished = nil
            DiagnosticJournal.shared.record("detail", area: "background", event: "completion",
                                            "File checks finished; releasing background wake")
            handler?()
        }
    }

    /// Read the file back against Apple's checksum before it is called saved.
    private func check(_ staged: URL, url: URL, pending: Pending) async {
        DiagnosticJournal.shared.record("detail", area: "transfer", event: "verify_started",
                                        "\(pending.filename): staged=\((try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) bytes, checksum=\(pending.sha1 == nil ? "none" : "SHA-1")",
                                        transferID: pending.id, platform: pending.platform)
        var transfer = Transfer(id: pending.id, name: pending.filename, device: pending.device)
        transfer.state = .verifying
        tell(transfer)
        if pending.sha1 != nil, await SyncEngine().isIntact(staged, sha1: pending.sha1) == false {
            DiagnosticJournal.shared.record("error", area: "transfer", event: "checksum_mismatch",
                                            pending.filename, transferID: pending.id,
                                            platform: pending.platform)
            try? FileManager.default.removeItem(at: staged)
            finish(url, pending, failure: SyncError.checksumMismatch(pending.filename).localizedDescription)
            return
        }
        do {
            try Library.accept(pending.filename)
            forget(url)
            transfer.state = .done(alreadyHad: false)
            tell(transfer)
            tellLog(.good, String(format: String(localized: pending.sha1 == nil ? "Downloaded %@" : "Downloaded %@, SHA-1 verified"), pending.filename),
                    event: "saved", pending: pending)
            settle()
        } catch {
            DiagnosticJournal.shared.recordError(error, area: "transfer", event: "save_failed",
                                                 pending.filename, transferID: pending.id,
                                                 platform: pending.platform)
            finish(url, pending, failure: error.localizedDescription)
        }
    }

    private func finish(_ url: URL, _ pending: Pending, failure: String) {
        forget(url)
        var transfer = Transfer(id: pending.id, name: pending.filename, device: pending.device)
        transfer.state = .failed(failure)
        tell(transfer)
        tellLog(.bad, "\(pending.filename): \(failure)", event: "failed", pending: pending)
        settle()
    }

    // MARK: - Telling the interface

    private func tell(_ transfer: Transfer) {
        guard let report else { return }
        Task { @MainActor in report(transfer) }
    }

    private func tellLog(_ kind: LogEntry.Kind, _ message: String,
                         event: String, pending: Pending) {
        let level: String
        switch kind {
        case .bad: level = "error"
        case .warning: level = "warning"
        case .good: level = "success"
        default: level = "info"
        }
        DiagnosticJournal.shared.record(level, area: "transfer", event: event, message,
                                        transferID: pending.id, platform: pending.platform)
        guard let log else { return }
        Task { @MainActor in log(LogEntry(kind: kind, message: message)) }
    }

    private func settle() {
        guard let settled else { return }
        Task { @MainActor in settled() }
    }

    // MARK: - What is written down

    private var record: [String: Pending] {
        guard let data = defaults.data(forKey: pendingKey),
              let known = try? JSONDecoder().decode([String: Pending].self, from: data) else { return [:] }
        return known
    }

    private func pending(for url: URL) -> Pending? { record[url.absoluteString] }

    private func remember(_ pending: Pending, for url: URL) {
        var known = record
        known[url.absoluteString] = pending
        defaults.set(try? JSONEncoder().encode(known), forKey: pendingKey)
    }

    private func forget(_ url: URL) {
        var known = record
        known.removeValue(forKey: url.absoluteString)
        defaults.set(try? JSONEncoder().encode(known), forKey: pendingKey)
    }
}
