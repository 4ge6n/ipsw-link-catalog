import SwiftUI

/// What the current run is doing, and what the last one said.
struct ActivityPane: View {
    @Environment(SyncController.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if controller.running {
                    ProgressView().controlSize(.small)
                    Text("Syncing…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { controller.cancel() }
                } else {
                    Text(Settings.shared.lastRun.map {
                        "Last run \($0.formatted(date: .abbreviated, time: .shortened))"
                    } ?? "Not run yet").foregroundStyle(.secondary)
                    Spacer()
                    Button("Sync Now") { Task { await controller.run() } }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            Divider()
            List {
                ForEach(controller.transfers.filter { $0.state != .waiting }) { transfer in
                    TransferRow(transfer: transfer)
                }
                ForEach(controller.log.suffix(40).reversed()) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: entry.kind.symbol).foregroundStyle(entry.kind.tint)
                            .font(.caption)
                        Text(entry.message).font(.callout)
                        Spacer()
                        Text(entry.at.formatted(date: .omitted, time: .standard))
                            .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(minHeight: 220)
    }
}

private struct TransferRow: View {
    let transfer: Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(transfer.device).fontWeight(.medium)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if case .downloading = transfer.state {
                ProgressView(value: transfer.fraction)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        switch transfer.state {
        case .waiting: "waiting"
        case .checking: "checking what is already here"
        case .verifying: "verifying checksum"
        case .done(let had): had ? "already had it" : "done"
        case .failed(let why): why
        case .downloading:
            "\(format(transfer.received)) / \(format(transfer.total))"
            + "  ·  \(format(Int64(transfer.bytesPerSecond)))/s"
            + (transfer.eta.map { "  ·  \(Duration.seconds($0).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))) left" } ?? "")
        }
    }

    private func format(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}

extension LogEntry.Kind {
    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .good: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .bad: "xmark.octagon"
        }
    }
    var tint: Color {
        switch self {
        case .info: .secondary
        case .good: .green
        case .warning: .orange
        case .bad: .red
        }
    }
}
