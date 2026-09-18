import SwiftUI

/// What is happening, without having to find the row it is happening on.
///
/// Carried over from the Mac, where the menu bar showed the first transfer of
/// however many were running and so reported a fraction of the work. Here the
/// only sign of a transfer was the row it started from, which on a catalog of
/// two hundred builds is somewhere up the list — start three and there was
/// nowhere at all that said so.
struct ActivityBar: View {
    @Environment(BrowserModel.self) private var model
    @State private var showingDetail = false

    /// Coming down or being hashed. Finished ones drop out: the Saved tab is
    /// the record of those.
    private var active: [Transfer] {
        model.transfers.filter {
            switch $0.state {
            case .checking, .downloading, .verifying: true
            case .waiting, .queued, .done, .failed: false
            }
        }
    }

    private var overall: (received: Int64, expected: Int64, fraction: Double) {
        let expected = active.reduce(Int64(0)) { $0 + max($1.total, $1.received) }
        let received = active.reduce(Int64(0)) { $0 + $1.received }
        return (received, expected, expected > 0 ? min(1, Double(received) / Double(expected)) : 0)
    }

    var body: some View {
        if !active.isEmpty {
            Button { showingDetail = true } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(caption).fontWeight(.medium)
                        Spacer(minLength: 8)
                        Text(volume).foregroundStyle(.secondary).monospacedDigit()
                        Image(systemName: "chevron.up").foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                    ProgressView(value: overall.fraction)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.bar)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingDetail) { ActivityDetail() }
        }
    }

    private var caption: String {
        let downloading = active.count { $0.state == .downloading }
        let checking = active.count { $0.state == .verifying }
        if checking > 0, downloading > 0 {
            return String(format: String(localized: "%1$lld downloading · %2$lld checking"), downloading, checking)
        }
        if checking > 0 {
            return String(format: String(localized: "%lld checking"), checking)
        }
        return String(format: String(localized: "%lld downloading"), max(downloading, active.count))
    }

    private var volume: String {
        let state = overall
        guard state.expected > 0 else { return "" }
        return "\(state.received.formatted(.byteCount(style: .file)))"
            + " / \(state.expected.formatted(.byteCount(style: .file)))"
    }
}

/// Every transfer at once, which is the thing the bar is a summary of.
private struct ActivityDetail: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Now") {
                    ForEach(model.transfers.filter { $0.state == .downloading || $0.state == .verifying || $0.state == .checking }) { transfer in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(transfer.device).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(detail(transfer)).font(.caption)
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            if transfer.state == .downloading {
                                ProgressView(value: transfer.fraction)
                            }
                        }
                    }
                }
                let waiting = model.transfers.filter { $0.state == .queued || $0.state == .waiting }
                if !waiting.isEmpty {
                    Section("Queue") {
                        ForEach(waiting) { transfer in
                            Text(transfer.device).lineLimit(1)
                        }
                    }
                }
                let recent = model.log.suffix(40).reversed()
                if !recent.isEmpty {
                    Section("Log") {
                        ForEach(recent) { entry in
                            Text(entry.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func detail(_ transfer: Transfer) -> String {
        switch transfer.state {
        case .downloading:
            transfer.total > 0
                ? "\(Int(transfer.fraction * 100))%"
                : transfer.received.formatted(.byteCount(style: .file))
        case .verifying: String(localized: "checking")
        default: "…"
        }
    }
}
