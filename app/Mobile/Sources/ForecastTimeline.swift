import Charts
import SwiftUI

/// The forecast drawn out: what came when, lane by lane, and where the next
/// one is expected — each estimate as a band from its earliest to its latest
/// day, with a mark at the likeliest. Dates are Japan time.
struct ForecastTimeline: View {
    @Environment(ReleaseFeed.self) private var feed
    @Environment(\.dismiss) private var dismiss
    let platform: Platform

    /// One dot: a build that came out.
    private struct Past: Identifiable {
        let id: String
        let lane: String
        let at: Date
        var label: String
        let tint: Color
        var below = false
    }

    /// Labels that do not sit on one another. Two builds a few days apart
    /// printed their names in the same place; now a label is dropped when it
    /// would land within ten days of a newer one in its lane, and the
    /// ones kept alternate above and below.
    private func labelled(_ points: [Past]) -> [Past] {
        var out: [Past] = []
        var lastLabelled: [String: Date] = [:]
        var flip: [String: Bool] = [:]
        // Newest first, so it is the latest build in a cluster that keeps
        // its name.
        for var point in points.sorted(by: { $0.at > $1.at }) {
            if let previous = lastLabelled[point.lane], previous.timeIntervalSince(point.at) < 10 * 86_400 {
                point.label = ""
            } else {
                lastLabelled[point.lane] = point.at
                point.below = flip[point.lane, default: false]
                flip[point.lane] = !point.below
            }
            out.append(point)
        }
        return out
    }

    var body: some View {
        let outlook = feed.outlook(for: platform)
        let lanes = lanes(outlook)
        let past = history(outlook)
        let start = Clocks.japan.date(byAdding: .day, value: -100, to: .now) ?? .now
        // Room past the last estimate for its label, which was cut off.
        let lastEstimate = outlook.all.map(\.latest).max() ?? .now
        let end = Clocks.japan.date(byAdding: .day, value: 12,
                                    to: max(lastEstimate, Clocks.japan.date(byAdding: .day, value: 30, to: .now) ?? .now)) ?? .now
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Chart {
                        // Today, so "overdue" can be seen rather than read.
                        RuleMark(x: .value("Today", Date.now))
                            .foregroundStyle(.red.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .top, alignment: .leading) {
                                Text("Today").font(.caption2).foregroundStyle(.red)
                            }
                        ForEach(labelled(past.filter { $0.at >= start })) { point in
                            PointMark(x: .value("Date", point.at), y: .value("Lane", point.lane))
                                .foregroundStyle(point.tint)
                                .symbolSize(40)
                                .annotation(position: point.below ? .bottom : .top, spacing: 2) {
                                    Text(point.label).font(.system(size: 9)).foregroundStyle(.secondary)
                                        .fixedSize()
                                }
                        }
                        ForEach(outlook.all) { forecast in
                            let lane = laneName(forecast)
                            BarMark(xStart: .value("From", forecast.earliest),
                                    xEnd: .value("To", max(forecast.latest, forecast.earliest.addingTimeInterval(86_400))),
                                    y: .value("Lane", lane), height: 14)
                                .foregroundStyle(forecast.kind.tint.opacity(0.25))
                                .clipShape(.capsule)
                            PointMark(x: .value("Expected", forecast.expected), y: .value("Lane", lane))
                                .symbol(.diamond)
                                .symbolSize(90)
                                .foregroundStyle(forecast.kind.tint)
                                .annotation(position: .bottom, spacing: 2) {
                                    Text(forecast.expected.formatted(Clocks.japanese(.dateTime.month(.defaultDigits).day())))
                                        .font(.caption2.weight(.semibold)).foregroundStyle(forecast.kind.tint)
                                }
                        }
                    }
                    .chartXScale(domain: start...end)
                    .chartYScale(domain: lanes)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .month)) { value in
                            AxisGridLine()
                            AxisValueLabel(format: Clocks.japanese(.dateTime.month(.abbreviated)))
                        }
                    }
                    .frame(height: CGFloat(max(lanes.count, 2)) * 70 + 40)
                    .padding(.top, 8)

                    // The same, in words, with every reason behind each.
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(outlook.all) { forecast in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    ForecastBadge(kind: forecast.kind)
                                    Text(forecast.title).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(forecast.expected.formatted(Clocks.japanese(.dateTime.month(.abbreviated).day().weekday(.abbreviated))))
                                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                                }
                                ForEach(forecast.signals) { signal in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("・\(signal.reason)")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(signal.date.formatted(Clocks.japanese(.dateTime.month(.defaultDigits).day())))
                                            .monospacedDigit().fixedSize()
                                        Text(String(format: "×%.1f", signal.weight)).foregroundStyle(.tertiary).fixedSize()
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                                if let note = forecast.note {
                                    Text(note).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    Text("Diamonds are the likeliest day, bands the spread of the reasons, dots the builds that came out. Each reason counts by its weight (×). Japan time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle(String(format: String(localized: "%@ forecast"), platform.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private func laneName(_ forecast: Forecast) -> String {
        switch forecast.kind {
        case .release, .versionRelease: String(localized: "Releases")
        case .beta(let track): String(format: String(localized: "%@ betas"), track)
        case .newVersion: String(localized: "New versions")
        }
    }

    private func lanes(_ outlook: ReleaseFeed.Outlook) -> [String] {
        var names = [String(localized: "Releases")]
        names += outlook.tracks.map { laneName($0) }
        if outlook.newVersion != nil { names.append(String(localized: "New versions")) }
        return names
    }

    private func history(_ outlook: ReleaseFeed.Outlook) -> [Past] {
        var points: [Past] = []
        for entry in feed.releases(for: platform) {
            guard let at = entry.release.releasedAt else { continue }
            points.append(Past(id: "r-\(entry.id)", lane: String(localized: "Releases"), at: at,
                               label: entry.release.version, tint: Forecast.Kind.release.tint))
        }
        let tracks = feed.betaTracks(for: platform)
        let open = Set(outlook.tracks.compactMap { forecast -> String? in
            if case .beta(let track) = forecast.kind { return track } else { return nil }
        })
        for track in tracks where open.contains(track.version) {
            for entry in track.builds {
                guard let at = entry.release.releasedAt else { continue }
                points.append(Past(id: "b-\(entry.id)", lane: String(format: String(localized: "%@ betas"), track.version),
                                   at: at, label: (entry.release.prerelease ?? "").replacingOccurrences(of: "beta ", with: "b").replacingOccurrences(of: "beta", with: "b1"), tint: Forecast.Kind.beta(track: "").tint))
            }
        }
        if outlook.newVersion != nil {
            for track in tracks where track.builds.count >= 2 {
                guard let first = track.builds.first, let at = first.release.releasedAt else { continue }
                points.append(Past(id: "n-\(first.id)", lane: String(localized: "New versions"), at: at,
                                   label: track.version, tint: Forecast.Kind.newVersion.tint))
            }
        }
        return points
    }
}
