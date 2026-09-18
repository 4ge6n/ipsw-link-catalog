import Foundation

/// Writes a download to a file as it arrives.
///
/// The transfer used to be read a byte at a time from URLSession's async byte
/// sequence. That is about as slow as reading gets — thirty-odd megabytes a
/// second on a loopback connection, all of it spent in the loop rather than on
/// the network — and it is slower than the connection Apple's servers offer.
/// Nothing throws away what has arrived and cannot yet be read, so a transfer
/// that could not keep up simply grew: three ten-gigabyte images at once, and
/// the memory they were waiting in, is tens of gigabytes.
///
/// A delegate is handed whole chunks and writes each one straight to the file,
/// which is both the fast way and the way that holds nothing.
final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let offset: Int64
    private let progress: @Sendable (Int64) -> Void
    /// Asked between chunks rather than between files, so Stop stops this one.
    private let shouldStop: @Sendable () -> Bool

    private let lock = NSLock()
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var lastReport = Date.distantPast
    private var failure: Error?
    private var finished: CheckedContinuation<Void, Error>?

    init(to destination: URL, from offset: Int64,
         progress: @escaping @Sendable (Int64) -> Void,
         shouldStop: @escaping @Sendable () -> Bool) {
        self.destination = destination
        self.offset = offset
        self.progress = progress
        self.shouldStop = shouldStop
    }

    /// Run the request to its end, or to the first thing that goes wrong.
    func receive(_ url: URL, using configuration: URLSessionConfiguration) async throws {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                finished = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: The delegate

    /// The completion-handler form rather than the async one: this takes a
    /// lock, and a lock is not something to hold across a suspension point.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(open(for: response))
    }

    private func open(for response: URLResponse) -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            settle(SyncError.http((response as? HTTPURLResponse)?.statusCode ?? 0,
                                  destination.lastPathComponent))
            return .cancel
        }
        // A server that ignores the range restarts the file, so the partial
        // copy goes rather than having the whole file appended to it.
        let appending = offset > 0 && http.statusCode == 206
        do {
            if !appending {
                try? FileManager.default.removeItem(at: destination)
                // Only then: createFile truncates whatever is already there.
                FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
            }
            let opened = try FileHandle(forWritingTo: destination)
            if appending { try opened.seekToEnd() }
            lock.lock()
            handle = opened
            written = appending ? offset : 0
            lock.unlock()
        } catch {
            settle(error)
            return .cancel
        }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let handle else { lock.unlock(); return }
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
        } catch {
            lock.unlock()
            settle(error)
            dataTask.cancel()
            return
        }
        let now = Date.now
        let due = now.timeIntervalSince(lastReport) > 0.2
        if due { lastReport = now }
        let sofar = written
        lock.unlock()
        if due { progress(sofar) }
        if shouldStop() {
            settle(CancellationError())
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let sofar = written
        try? handle?.close()
        handle = nil
        lock.unlock()
        progress(sofar)
        if let error, (error as? URLError)?.code != .cancelled { settle(error) }
        else { settle(nil) }
    }

    /// The first answer wins: a failure recorded while the body was arriving
    /// must not be replaced by the cancellation it causes.
    private func settle(_ error: Error?) {
        lock.lock()
        guard let continuation = finished else { lock.unlock(); return }
        finished = nil
        let recorded = failure ?? error
        if failure == nil { failure = error }
        lock.unlock()
        if let recorded { continuation.resume(throwing: recorded) }
        else { continuation.resume() }
    }
}
