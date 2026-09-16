import SwiftUI

/// What the current run is doing, and what the last one said. Below a certain
/// width the row stacks and the per-file lines drop their detail, so the bar and
/// the percentage survive at any size the window is dragged to.
struct ActivityPane: View {
    @Environment(SyncController.self) private var controller
    @State private var width: CGFloat = 700

    private var narrow: Bool { width < 470 }

    private var shortCaption: String {
        let state = controller.overall
        return "\(state.done)/\(state.total)  ·  \(Int(state.fraction * 100))%"
    }

    private var progressCaption: String {
        let state = controller.overall
        let files = "\(state.done) of \(state.total) file(s)"
        guard state.expected > 0 else { return files }
        return files + "  ·  \(state.received.formatted(.byteCount(style: .file)))"
            + " of \(state.expected.formatted(.byteCount(style: .file)))"
            + "  ·  \(Int(state.fraction * 100))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if controller.running {
                    VStack(alignment: .leading, spacing: 4) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                Text("Syncing").fontWeight(.medium)
                                Text(progressCaption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            // Too narrow for the whole caption: keep the counts.
                            HStack(spacing: 8) {
                                Text("Syncing").fontWeight(.medium)
                                Text(shortCaption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Text(shortCaption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.callout)
                        .lineLimit(1)
                        ProgressView(value: controller.overall.fraction)
                    }
                    Spacer(minLength: 8)
                    Button("Stop") { controller.cancel() }
                        .buttonStyle(.glass)
                        .controlSize(narrow ? .small : .regular)
                } else {
                    Text(Settings.shared.lastRun.map {
                        narrow ? $0.formatted(date: .omitted, time: .shortened)
                               : String(format: String(localized: "Last run %@"), $0.formatted(date: .abbreviated, time: .shortened))
                    } ?? String(localized: "Not run yet"))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Button(narrow ? String(localized: "Sync") : String(localized: "Sync Now")) { Task { await controller.run() } }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(narrow ? .small : .regular)
                }
            }
            .padding(narrow ? 10 : 12)
            // An empty list is just a black slab; the strip stays the height of
            // its own row until a run has something to show in it.
            if !controller.transfers.isEmpty || !controller.log.isEmpty {
                Divider()
                List {
                    ForEach(controller.transfers.filter { $0.state != .waiting }) { transfer in
                        TransferRow(transfer: transfer, narrow: narrow)
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
                .frame(minHeight: 120, idealHeight: 240)
            }
        }
        .background(
            GeometryReader { proxy in
                // Writing state from inside layout can feed back into layout, so
                // the measurement is handed over after the pass has finished.
                Color.clear.task(id: proxy.size.width) {
                    let measured = proxy.size.width
                    if abs(measured - width) > 1 { width = measured }
                }
            }
        )
    }
}

private struct TransferRow: View {
    let transfer: Transfer
    var narrow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(transfer.device).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(narrow ? shortDetail : detail)
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1)
            }
            if case .downloading = transfer.state {
                ProgressView(value: transfer.fraction)
            }
        }
        .padding(.vertical, 2)
    }

    /// Enough to follow the transfer when the window is only a few hundred points wide.
    private var shortDetail: String {
        switch transfer.state {
        case .downloading: "\(Int(transfer.fraction * 100))%"
        case .verifying: String(localized: "checking")
        case .checking: "…"
        case .done(let had): had ? String(localized: "have") : String(localized: "done")
        case .failed: String(localized: "failed")
        case .waiting: ""
        }
    }

    private var detail: String {
        switch transfer.state {
        case .waiting: String(localized: "waiting")
        case .checking: String(localized: "checking what is already here")
        case .verifying: String(localized: "verifying checksum")
        case .done(let had): had ? String(localized: "already had it") : String(localized: "done")
        case .failed(let why): why
        case .downloading:
            "\(format(transfer.received)) / \(format(transfer.total))"
            + "  ·  \(format(Int64(transfer.bytesPerSecond)))/s"
            + (transfer.eta.map { "  ·  \(Self.remaining($0)) left" } ?? "")
        }
    }

    /// The rest of the interface is in English, so the time is too rather than
    /// following whatever locale the Mac is set to.
    static func remaining(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .narrow)
                .locale(Locale(identifier: "en_US")))
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
