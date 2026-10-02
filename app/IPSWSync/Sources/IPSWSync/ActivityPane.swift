import AppKit
import SwiftUI

/// What the app is doing, and what it did.
///
/// One summary always at the top — how far a run has got, or how the last one
/// ended and when the next is due — and under it one list at a time: what is
/// moving now, what is waiting and what has finished, or the log.
struct ActivityPane: View {
    @Environment(SyncController.self) private var controller
    @AppStorage("activityPaneHeight") private var paneHeight = 260.0
    @AppStorage("activityLogFilter") private var filter: LogFilter = .summary
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
        // one ending leaves what finished, which is what they then ask about.
        .onChange(of: controller.running) { _, running in tab = running ? .now : .queue }
        .onAppear { tab = controller.running ? .now : .log }
    }

    // MARK: The edge that sizes the pane

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
                    Text(String(format: String(localized: "%1$lld of %2$lld"), finished.count, controller.transfers.count))
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

    private var overallETA: TimeInterval? {
        let state = controller.overall
        let rate = active.reduce(0.0) { $0 + ($1.state == .downloading ? $1.bytesPerSecond : 0) }
        guard rate > 0, state.expected > state.received else { return nil }
        return Double(state.expected - state.received) / rate
    }

    private var lastResult: (text: String, symbol: String, tint: Color) {
        let lastStart = controller.log.lastIndex { $0.kind == .start }
        let after = lastStart.map { controller.log[controller.log.index(after: $0)...] } ?? controller.log[...]
        if let ending = after.last(where: { $0.kind == .good || $0.kind == .bad }) {
            return ending.kind == .good
                ? (Pretty.message(ending.message), "checkmark.circle.fill", .green)
                : (Pretty.message(ending.message), "exclamationmark.triangle.fill", .orange)
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

    // MARK: What is where

    private var active: [Transfer] {
        controller.transfers.filter {
            switch $0.state {
            case .checking, .downloading, .verifying: true
            case .waiting, .queued, .done, .failed, .skipped: false
            }
        }
    }

    private var waiting: [Transfer] {
        controller.transfers.filter { $0.state == .queued || $0.state == .waiting }
    }

    /// Done, failed or skipped, the most recent first.
    private var finished: [Transfer] {
        controller.transfers
            .filter { $0.finishedAt != nil }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
    }

    // MARK: Now

    @ViewBuilder private var nowList: some View {
        if active.isEmpty {
            ContentUnavailableView(controller.running ? "Getting ready" : "Nothing running",
                                   systemImage: "arrow.down.circle")
        } else {
            List(active) { transfer in TransferRow(transfer: transfer) }
                .listStyle(.plain)
        }
    }

    // MARK: Queue, and what has finished

    @ViewBuilder private var queueList: some View {
        if waiting.isEmpty && finished.isEmpty {
            ContentUnavailableView("Nothing waiting", systemImage: "tray")
        } else {
            List {
                if !waiting.isEmpty {
                    Section {
                        ForEach(Array(waiting.enumerated()), id: \.element.id) { index, transfer in
                            HStack(spacing: 10) {
                                Text("\(index + 1)").font(.caption).monospacedDigit()
                                    .foregroundStyle(.tertiary).frame(width: 26, alignment: .trailing)
                                FileLabel(transfer: transfer)
                                Spacer()
                                if transfer.total > 0 {
                                    Text(transfer.total.formatted(.byteCount(style: .file)))
                                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    } header: {
                        Text(String(format: String(localized: "Waiting (%lld)"), waiting.count))
                    }
                }
                if !finished.isEmpty {
                    Section {
                        ForEach(finished) { transfer in FinishedRow(transfer: transfer) }
                    } header: {
                        HStack {
                            Text(String(format: String(localized: "Finished (%lld)"), finished.count))
                            Spacer()
                            Text(finishedSummary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    /// "3 downloaded · 72 already here · 1 failed · 2 skipped"
    private var finishedSummary: String {
        var got = 0, had = 0, failed = 0, skipped = 0
        for transfer in finished {
            switch transfer.state {
            case .done(let already): if already { had += 1 } else { got += 1 }
            case .failed: failed += 1
            case .skipped: skipped += 1
            default: break
            }
        }
        var parts: [String] = []
        if got > 0 { parts.append(String(format: String(localized: "%lld downloaded"), got)) }
        if had > 0 { parts.append(String(format: String(localized: "%lld already here"), had)) }
        if failed > 0 { parts.append(String(format: String(localized: "%lld failed"), failed)) }
        if skipped > 0 { parts.append(String(format: String(localized: "%lld skipped"), skipped)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Log

    enum LogFilter: String, CaseIterable {
        /// Everything but the routine.
        case summary
        case everything
        case problems
    }

    private var runs: [LogRun] { LogRun.group(controller.log, filter: filter) }

    private var logList: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $filter) {
                    Text("Summary").tag(LogFilter.summary)
                    Text("Everything").tag(LogFilter.everything)
                    Text("Problems").tag(LogFilter.problems)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .controlSize(.small)
                Spacer()
                Button("Export Diagnostic Log") { exportLog() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.bottom, 4)
            if runs.isEmpty {
                ContentUnavailableView(filter == .problems ? "No problems" : "Nothing logged yet",
                                       systemImage: "text.alignleft")
            } else {
                List {
                    ForEach(runs) { run in
                        Section {
                            ForEach(run.lines) { line in LogLine(line: line) }
                        } header: {
                            HStack(alignment: .firstTextBaseline) {
                                Text(run.title).font(.subheadline.weight(.semibold))
                                Spacer()
                                if let outcome = run.outcome {
                                    Label(Pretty.message(outcome.message),
                                          systemImage: outcome.kind.symbol)
                                        .font(.caption).foregroundStyle(outcome.kind.tint).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ipsw-sync-diagnostics.jsonl"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try RunJournal.shared.export(to: destination)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

/// Long machine names made readable: the image file becomes the device and
/// the build, and a folder path becomes the folder's name.
enum Pretty {
    private static let image = try! NSRegularExpression(
        pattern: #"([A-Za-z][A-Za-z0-9_,.]*?)_([0-9]+(?:\.[0-9]+)*)_([0-9]+[A-Za-z][0-9A-Za-z]*)_Restore\.ipsw(?:\.part)?"#)
    private static let path = try! NSRegularExpression(pattern: #"(?:/[^/\s]+)+/([^/\s][^/]*?)/?(?=$|\s|\))"#)

    static func message(_ text: String) -> String {
        var out = text
        out = image.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                             withTemplate: "$1 · $2 ($3)")
        out = path.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                            withTemplate: "$1")
        return out
    }

    /// "iPhone12,1_27.0.1_24A446_Restore.ipsw" → "27.0.1 (24A446)"
    static func build(of filename: String) -> String? {
        let range = NSRange(filename.startIndex..., in: filename)
        guard let match = image.firstMatch(in: filename, range: range),
              let version = Range(match.range(at: 2), in: filename),
              let build = Range(match.range(at: 3), in: filename) else { return nil }
        return "\(filename[version]) (\(filename[build]))"
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
    let outcome: LogEntry?

    var title: String {
        guard let started else { return String(localized: "Earlier") }
        return String(format: String(localized: "Run at %@"), started.formatted(date: .abbreviated, time: .shortened))
    }

    static func group(_ log: [LogEntry], filter: ActivityPane.LogFilter) -> [LogRun] {
        var runs: [LogRun] = []
        var current: [LogEntry] = []
        var started: Date?
        var anchor = UUID()
        func close() {
            guard !current.isEmpty || started != nil else { return }
            let outcome = current.last { $0.kind == .good || $0.kind == .bad }
            let shown = current.filter { entry in
                switch filter {
                case .everything: true
                case .summary: entry.kind != .detail
                case .problems: entry.kind == .warning || entry.kind == .bad
                }
            }
            // Repeats folded: four platforms saying the same thing is one line.
            var lines: [Line] = []
            for entry in shown {
                if let last = lines.last, last.entry.kind == entry.kind, last.entry.message == entry.message {
                    lines[lines.count - 1] = Line(id: last.id, entry: last.entry, repeats: last.repeats + 1)
                } else {
                    lines.append(Line(id: entry.id, entry: entry, repeats: 1))
                }
            }
            if !lines.isEmpty || filter != .problems {
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
            Text(line.entry.at.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .leading)
            if let platform = line.entry.platform {
                Text(platform.title).font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: .capsule)
            }
            Text(Pretty.message(line.entry.message))
                .font(.callout)
                .foregroundStyle(line.entry.kind == .detail ? .secondary : .primary)
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

/// The device, and under it the build the file is — not the file's name.
private struct FileLabel: View {
    let transfer: Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(transfer.device).lineLimit(1)
            Text(Pretty.build(of: transfer.name) ?? transfer.name)
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

private struct FinishedRow: View {
    let transfer: Transfer

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
            FileLabel(transfer: transfer)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(outcome).font(.caption).foregroundStyle(tint).lineLimit(1)
                if let at = transfer.finishedAt {
                    Text(at.formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
        }
    }

    private var symbol: String {
        switch transfer.state {
        case .done(let had): had ? "checkmark.circle" : "arrow.down.circle.fill"
        case .failed: "xmark.circle.fill"
        case .skipped: "forward.circle"
        default: "circle"
        }
    }

    private var tint: Color {
        switch transfer.state {
        case .done(let had): had ? .secondary : .green
        case .failed: .red
        default: .secondary
        }
    }

    private var outcome: String {
        switch transfer.state {
        case .done(let had): had ? String(localized: "already here") : String(localized: "downloaded")
        case .failed(let why): Pretty.message(why)
        case .skipped(let why): why
        default: ""
        }
    }
}

struct TransferRow: View {
    let transfer: Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                FileLabel(transfer: transfer)
                Spacer(minLength: 6)
                status
            }
            if transfer.state == .downloading || (transfer.state == .verifying && transfer.total > 0) {
                ProgressView(value: transfer.fraction)
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
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
                Text("Checking SHA-1").font(.caption).foregroundStyle(.secondary)
                if transfer.total > 0 {
                    Text("\(Int(transfer.fraction * 100))%").font(.callout.monospacedDigit()).foregroundStyle(.tint)
                } else {
                    ProgressView().controlSize(.mini)
                }
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
        case .detail: "minus"
        case .info: "info.circle"
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .bad: "xmark.octagon.fill"
        }
    }
    var tint: Color {
        switch self {
        case .start, .detail, .info: .secondary
        case .good: .green
        case .warning: .orange
        case .bad: .red
        }
    }
}
