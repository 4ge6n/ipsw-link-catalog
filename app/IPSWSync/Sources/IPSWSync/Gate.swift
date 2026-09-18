import Foundation

/// Lets a fixed number of things run at once, and no more.
///
/// The number in Settings is a number of *downloads*. Checking a file's
/// checksum is not a download — it touches the disk, not the line — so it does
/// not hold a place here: hashing the file that has just arrived runs while the
/// next one is already coming down. Before this, a twelve-gigabyte hash stalled
/// a transfer slot for the minute it took, and with the usual three slots that
/// was a third of the line standing still.
actor Gate {
    private var limit: Int
    private var busy = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int = 1) { self.limit = max(1, limit) }

    /// Set before a run, when nothing is through the gate yet.
    func setLimit(_ newLimit: Int) {
        limit = max(1, newLimit)
        admit()
    }

    func enter() async {
        guard busy >= limit else { busy += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        busy -= 1
        admit()
    }

    /// Let through as many as the raised limit now allows.
    private func admit() {
        while busy < limit, !waiting.isEmpty {
            busy += 1
            waiting.removeFirst().resume()
        }
    }
}
