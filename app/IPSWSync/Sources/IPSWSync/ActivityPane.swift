import SwiftUI

/// What the current run is doing, and what the last one said. Below a certain
/// width the row stacks and the per-file lines drop their detail, so the bar and
/// the percentage survive at any size the window is dragged to.
struct ActivityPane: View {
    @Environment(SyncController.self) private var controller
    @State private var width: CGFloat = 700

    @State private var showingQueue = false
    /// Dragged by the handles below, and remembered: someone who wants a tall
    /// log and a short list of transfers should not have to say so every time.
    @AppStorage("activityHeight") private var activityHeight = 150.0
    @AppStorage("logHeight") private var logHeight = 96.0

    private var narrow: Bool { width < 470 }

    /// What is actually moving: being looked at, coming down, or being hashed.
    private var active: [Transfer] {
        controller.transfers.filter {
            switch $0.state {
            case .checking, .downloading, .verifying: true
            case .waiting, .queued, .done, .failed: false
            }
        }
    }

    /// Everything that has not started yet, whether or not it has reached the
    /// line for the wire.
    private var queued: Int {
        controller.transfers.count {
            $0.state == .queued || $0.state == .waiting
        }
    }

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
            // Only what is happening. A finished file leaves the list —
            // its line in the log below is the record of it — so the middle
            // of the window stays the size of the work in hand rather than
            // growing to two hundred rows by the end of a run.
            if !active.isEmpty || queued > 0 {
                Divider()
                List {
                    ForEach(active) { transfer in
                        TransferRow(transfer: transfer, narrow: narrow)
                    }
                    if queued > 0 {
                        DisclosureGroup(isExpanded: $showingQueue) {
                            ForEach(controller.transfers.filter { $0.state == .queued || $0.state == .waiting }) { transfer in
                                HStack {
                                    Text(transfer.device).lineLimit(1).truncationMode(.tail)
                                    Spacer(minLength: 8)
                                    Text(transfer.state == .queued
                                         ? String(localized: "in line")
                                         : String(localized: "waiting"))
                                        .foregroundStyle(.tertiary)
                                }
                                .font(.caption)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "list.bullet")
                                Text(String(format: String(localized: "Queue — %lld to go"), queued))
                                Spacer()
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
                .frame(height: activityHeight)
            }
            // The log is the record, not the work, so it gets a strip rather
            // than half the window — and it keeps its own scroll, newest first.
            if !controller.log.isEmpty {
                // The handle is the line between the two, and it moves that
                // line: what is above it grows as what is below it shrinks.
                // It used to sit under the log, at the very bottom of the
                // window, where dragging it down asked for room that is not
                // there — the place it was in had nothing to do with the edge
                // it moved.
                if !active.isEmpty || queued > 0 {
                    SplitHandle(above: $activityHeight, below: $logHeight,
                                leastAbove: 60, leastBelow: 40)
                } else {
                    Divider()
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(controller.log.suffix(200).reversed()) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: entry.kind.symbol).foregroundStyle(entry.kind.tint)
                                Text(entry.at.formatted(date: .omitted, time: .standard))
                                    .foregroundStyle(.tertiary).monospacedDigit()
                                Text(entry.message).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .font(.caption2)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .frame(height: logHeight)
                .background(.quaternary.opacity(0.25))
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

/// The line between the transfer list and the log, which can be dragged.
///
/// Whatever it takes from one it gives to the other, so the pair keeps the
/// height it had and the edge that moves is the one under the cursor.
private struct SplitHandle: View {
    @Binding var above: Double
    @Binding var below: Double
    let leastAbove: Double
    let leastBelow: Double
    @State private var startedAt: (above: Double, below: Double)?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary).frame(height: 1)
            // A one-point line is not something anyone can catch with a mouse.
            Rectangle().fill(.clear).frame(height: 10).contentShape(.rect)
            Capsule().fill(.tertiary).frame(width: 28, height: 3)
        }
        .frame(height: 10)
        .onHover { inside in
            // The cursor is what says it can be dragged at all.
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { move in
                    let from = startedAt ?? (above, below)
                    if startedAt == nil { startedAt = from }
                    // Clamped on both sides before either is written, so the
                    // pair always adds up to what it did before the drag.
                    let total = from.above + from.below
                    let wanted = min(max(from.above + move.translation.height, leastAbove),
                                     total - leastBelow)
                    above = wanted
                    below = total - wanted
                }
                .onEnded { _ in startedAt = nil }
        )
        .accessibilityLabel(Text("Resize"))
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
        case .queued: String(localized: "in line")
        case .done(let had): had ? String(localized: "have") : String(localized: "done")
        case .failed: String(localized: "failed")
        case .waiting: ""
        }
    }

    private var detail: String {
        switch transfer.state {
        case .waiting: String(localized: "waiting")
        case .queued: String(localized: "waiting for a slot")
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
