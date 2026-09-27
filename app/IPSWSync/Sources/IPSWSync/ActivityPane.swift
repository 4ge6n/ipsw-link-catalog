import SwiftUI

/// What the app is doing, and what it did.
///
/// One summary always at the top — how far a run has got, or how the last one
/// ended and when the next is due — and under it one list at a time: what is
/// moving now, what is waiting, or the log. The three used to be stacked in a
/// strip a few rows tall, which made each of them too short to read and the
/// log a wall of identical warnings with no telling where one run ended.
struct ActivityPane: View {
    @Environment(SyncController.self) private var controller
    @AppStorage("activityPaneHeight") private var paneHeight = 260.0
    @AppStorage("activityShowsProblemsOnly") private var problemsOnly = false
    @State private var tab: Tab = .log
    @State private var dragStart: Double?

    enum Tab: Hashable { case now, queue, log }

    var body: some View {
        VStack(spacing: 0) {
            resizeEdge
            header
                .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            Picker("", selection: $tab) {
                Text(String(format: String(localized: "Now (%lld)"), active.count)).tag(Tab.now)
                Text(String(format: String(localized: "Queue (%lld)"), waiting.count)).tag(Tab.queue)
                Text("Log").tag(Tab.log)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14).padding(.vertical, 8)
            Group {
                switch tab {
                case .now: nowList
                case .queue: queueList
                case .log: logList
                }
            }
            .frame(height: paneHeight)
        }
        .background(.background)
        // A run starting is what someone opening the window wants to watch;
        // one ending leaves the log, which says how it went.
        .onChange(of: controller.running) { _, running in tab = running ? .now : .log }
        .onAppear { tab = controller.running ? .now : .log }
    }

    // MARK: The edge that sizes the pane

    /// The pane's own top edge, dragged: up makes it taller. It sits on the
    /// line it moves.
    private var resizeEdge: some View {
        ZStack {
            Rectangle().fill(.separator).frame(height: 1)
            Capsule().fill(.tertiary).frame(width: 34, height: 4)
        }
        .frame(height: 10)
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    let from = dragStart ?? paneHeight
                    if dragStart == nil { dragStart = from }
                    paneHeight = min(max(from - drag.translation.height, 90), 700)
                }
                .onEnded { _ in dragStart = nil }
        )
        .accessibilityLabel(Text("Resize"))
    }

    // MARK: The summary

    @ViewBuilder private var header: some View {
        if controller.running {
            let state = controller.overall
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Syncing", systemImage: "arrow.down.circle.fill")
                        .font(.headline).foregroundStyle(.tint)
                    Text(String(format: String(localized: "%1$lld of %2$lld"), state.done, state.total))
                        .font(.headline).monospacedDigit()
                    Spacer()
                    Button("Stop", role: .destructive) { controller.cancel() }
                        .controlSize(.small)
                }
                ProgressView(value: state.fraction)
                Text(breakdown).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        } else {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: lastResult.symbol)
                    .font(.title2).foregroundStyle(lastResult.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lastResult.text).font(.headline).lineLimit(2)
                    Text(when).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sync Now") { Task { await controller.run() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// "48.3 GB of 120 GB · 3 downloading · 2 checking · 60 waiting · about 1 h 20 min"
    private var breakdown: String {
        let state = controller.overall
        var parts: [String] = []
        if state.expected > 0 {
            parts.append(String(format: String(localized: "%1$@ of %2$@"),
                                state.received.formatted(.byteCount(style: .file)),
                                state.expected.formatted(.byteCount(style: .file))))
        }
        let downloading = active.count { $0.state == .downloading }
        let checking = active.count { $0.state == .verifying || $0.state == .checking }
        if downloading > 0 { parts.append(String(format: String(localized: "%lld downloading"), downloading)) }
        if checking > 0 { parts.append(String(format: String(localized: "%lld checking"), checking)) }
        if !waiting.isEmpty { parts.append(String(format: String(localized: "%lld waiting"), waiting.count)) }
        if let eta = overallETA { parts.append(String(format: String(localized: "about %@ left"), TransferRow.remaining(eta))) }
        return parts.joined(separator: "  ·  ")
    }

    /// From the combined rate of what is coming down now.
    private var overallETA: TimeInterval? {
        let state = controller.overall
        let rate = active.reduce(0.0) { $0 + $1.bytesPerSecond }
        guard rate > 0, state.expected > state.received else { return nil }
        return Double(state.expected - state.received) / rate
    }

    /// How the last run ended, read from the log it left — which survives a
    /// relaunch, so a run made while the app was silent is reported too.
    private var lastResult: (text: String, symbol: String, tint: Color) {
        let lastStart = controller.log.lastIndex { $0.kind == .start }
        let after = lastStart.map { controller.log[controller.log.index(after: $0)...] } ?? controller.log[...]
        if let ending = after.last(where: { $0.kind == .good || $0.kind == .bad }) {
            return ending.kind == .good
                ? (ending.message, "checkmark.circle.fill", .green)
                : (ending.message, "exclamationmark.triangle.fill", .orange)
        }
        return (String(localized: "Not run yet"), "circle.dashed", .secondary)
    }

    private var when: String {
        var parts: [String] = []
        if let last = Settings.shared.lastRun {
            parts.append(String(format: String(localized: "Last run %@"),
                                last.formatted(date: .abbreviated, time: .shortened)))
        }
        if let next = controller.nextRun {
            parts.append(String(format: String(localized: "next %@"),
                                next.formatted(date: .abbreviated, time: .shortened)))
        } else {
            parts.append(String(localized: "No daily run"))
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Now

    private var active: [Transfer] {
        controller.transfers.filter {
            switch $0.state {
            case .checking, .downloading, .verifying: true
            case .waiting, .queued, .done, .failed: false
            }
        }
    }

    private var waiting: [Transfer] {
        controller.transfers.filter { $0.state == .queued || $0.state == .waiting }
    }

    @ViewBuilder private var nowList: some View {
        if active.isEmpty {
            ContentUnavailableView(controller.running ? "Getting ready" : "Nothing running",
                                   systemImage: "arrow.down.circle")
        } else {
            List(active) { transfer in TransferRow(transfer: transfer) }
                .listStyle(.plain)
        }
    }

    // MARK: Queue

    @ViewBuilder private var queueList: some View {
        if waiting.isEmpty {
            ContentUnavailableView("Nothing waiting", systemImage: "tray")
        } else {
            List(Array(waiting.enumerated()), id: \.element.id) { index, transfer in
                HStack(spacing: 10) {
                    Text("\(index + 1)").font(.caption).monospacedDigit()
                        .foregroundStyle(.tertiary).frame(width: 26, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(transfer.device).lineLimit(1)
                        Text(transfer.name).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if transfer.total > 0 {
                        Text(transfer.total.formatted(.byteCount(style: .file)))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: Log

    /// Runs, newest first, each with its lines in order and repeats folded.
    private var runs: [LogRun] { LogRun.group(controller.log, problemsOnly: problemsOnly) }

    private var logList: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Problems only", isOn: $problemsOnly).toggleStyle(.checkbox).controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.bottom, 4)
            if runs.isEmpty {
                ContentUnavailableView(problemsOnly ? "No problems" : "Nothing logged yet",
                                       systemImage: "text.alignleft")
            } else {
                List {
                    ForEach(runs) { run in
                        Section {
                            ForEach(run.lines) { line in LogLine(line: line) }
                        } header: {
                            HStack {
                                Text(run.title).font(.subheadline.weight(.semibold))
                                Spacer()
                                if let outcome = run.outcome {
                                    Text(outcome).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

/// One run's worth of log, for the grouped view.
struct LogRun: Identifiable {
    struct Line: Identifiable {
        let id: UUID
        let entry: LogEntry
        let repeats: Int
    }
    let id: UUID
    let started: Date?
    let lines: [Line]
    let outcome: String?

    var title: String {
        guard let started else { return String(localized: "Earlier") }
        return String(format: String(localized: "Run at %@"), started.formatted(date: .abbreviated, time: .shortened))
    }

    static func group(_ log: [LogEntry], problemsOnly: Bool) -> [LogRun] {
        var runs: [LogRun] = []
        var current: [LogEntry] = []
        var started: Date?
        var anchor = UUID()
        func close() {
            guard !current.isEmpty else { return }
            let outcome = current.last { $0.kind == .good || $0.kind == .bad }?.message
            var shown = current
            if problemsOnly { shown = shown.filter { $0.kind == .warning || $0.kind == .bad } }
            // Repeats folded: four platforms saying the same thing is one line.
            var lines: [Line] = []
            for entry in shown {
                if let last = lines.last, last.entry.kind == entry.kind, last.entry.message == entry.message {
                    lines[lines.count - 1] = Line(id: last.id, entry: last.entry, repeats: last.repeats + 1)
                } else {
                    lines.append(Line(id: entry.id, entry: entry, repeats: 1))
                }
            }
            if !lines.isEmpty || !problemsOnly {
                runs.append(LogRun(id: anchor, started: started, lines: lines, outcome: outcome))
            }
        }
        for entry in log {
            if entry.kind == .start {
                close()
                current = []
                started = entry.at
                anchor = entry.id
                continue
            }
            current.append(entry)
        }
        close()
        return runs.reversed()
    }
}

private struct LogLine: View {
    let line: LogRun.Line

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: line.entry.kind.symbol)
                .foregroundStyle(line.entry.kind.tint).font(.caption)
                .frame(width: 14)
            Text(line.entry.at.formatted(date: .omitted, time: .standard))
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            Text(line.entry.message).font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
            if line.repeats > 1 {
                Text("×\(line.repeats)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: .capsule)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }
}

struct TransferRow: View {
    let transfer: Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(transfer.device).font(.body.weight(.medium)).lineLimit(1)
                Spacer(minLength: 6)
                status
            }
            if transfer.state == .downloading {
                ProgressView(value: transfer.fraction)
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text(transfer.name).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var status: some View {
        switch transfer.state {
        case .downloading:
            Text("\(Int(transfer.fraction * 100))%").font(.callout.monospacedDigit()).foregroundStyle(.tint)
        case .verifying:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Checking SHA-1").font(.caption).foregroundStyle(.secondary)
            }
        default:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Looking").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var detail: String {
        var parts = ["\(format(transfer.received)) / \(format(transfer.total))"]
        if transfer.bytesPerSecond > 0 { parts.append("\(format(Int64(transfer.bytesPerSecond)))/s") }
        if let eta = transfer.eta { parts.append(String(format: String(localized: "%@ left"), Self.remaining(eta))) }
        return parts.joined(separator: "  ·  ")
    }

    static func remaining(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private func format(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file)) }
}

extension LogEntry.Kind {
    var symbol: String {
        switch self {
        case .start: "play.circle"
        case .info: "info.circle"
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .bad: "xmark.octagon.fill"
        }
    }
    var tint: Color {
        switch self {
        case .start, .info: .secondary
        case .good: .green
        case .warning: .orange
        case .bad: .red
        }
    }
}
