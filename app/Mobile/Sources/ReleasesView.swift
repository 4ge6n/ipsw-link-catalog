import SwiftUI

/// What came out, day by day, across every platform the catalog carries.
struct ReleasesView: View {
    @Environment(ReleaseFeed.self) private var feed
    @AppStorage("forecastPlatform") private var forecastPlatform: Platform = .ios
    @State private var showingTimeline = false

    var body: some View {
        @Bindable var feed = feed
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForecastCard { showingTimeline = true }
                        .padding(.bottom, 8)
                    ForEach(feed.days) { day in
                        DayRow(day: day)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .navigationTitle("Latest Releases")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle("Betas", systemImage: "testtube.2", isOn: $feed.includeBetas)
                        .toggleStyle(.button)
                }
            }
            .overlay {
                if feed.entries.isEmpty {
                    if feed.loading {
                        ProgressView()
                    } else if let failure = feed.failure {
                        ContentUnavailableView("Could not load", systemImage: "exclamationmark.triangle",
                                               description: Text(failure))
                    }
                }
            }
            .refreshable { await feed.load() }
            .task { if feed.entries.isEmpty { await feed.load() } }
            .navigationDestination(for: ReleaseFeed.Entry.self) { entry in
                DeviceList(release: entry.release)
            }
            // Held here, not inside the card: a sheet attached to a view in
            // a lazy stack is not reliably presented, and tapping did nothing.
            .sheet(isPresented: $showingTimeline) {
                ForecastTimeline(platform: forecastPlatform)
            }
        }
    }
}

private struct DayRow: View {
    let day: ReleaseFeed.Day

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // The date, large, the way a calendar shows it.
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    // "9月" in Japanese, "Sep" in English: the locale's own
                    // short month, beside the day in large type.
                    Text(day.date.formatted(Clocks.japanese(.dateTime.month(.abbreviated)))).font(.callout)
                        .foregroundStyle(.secondary)
                    // The bare number: the locale's day format adds "日" in
                    // Japanese, which wrapped onto a line of its own.
                    Text("\(Clocks.japan.component(.day, from: day.date))")
                        .font(.title.weight(.bold)).monospacedDigit()
                        .fixedSize()
                }
                Text(day.date.formatted(Clocks.japanese(.dateTime.weekday(.abbreviated))))
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
            }
            .frame(width: 66, alignment: .trailing)
            // The line that joins the days.
            VStack(spacing: 4) {
                Circle().fill(.tint.opacity(0.6)).frame(width: 9, height: 9).padding(.top, 10)
                Rectangle().fill(.tint.opacity(0.25)).frame(width: 2)
            }
            .frame(width: 10)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(day.groups, id: \.platform) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        PlatformChip(platform: group.platform)
                        ForEach(group.entries) { entry in
                            NavigationLink(value: entry) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("\(group.platform.title) \(entry.release.displayVersion)")
                                        .foregroundStyle(.primary)
                                    Text("(\(entry.release.build))").font(.callout.monospaced())
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.separator.opacity(0.5)))
            .padding(.vertical, 10)
        }
    }
}

/// A coloured tag for a platform, the same everywhere it appears.
struct PlatformChip: View {
    let platform: Platform

    var body: some View {
        Label(platform.title, systemImage: platform.symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(platform.tint)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(platform.tint.opacity(0.15), in: .capsule)
    }
}

extension Platform {
    var symbol: String {
        switch self {
        case .ios: "iphone"
        case .ipados: "ipad"
        case .ipod: "ipodtouch"
        case .tvos: "appletv"
        case .audioos: "homepod"
        case .visionos: "visionpro"
        case .macos: "laptopcomputer"
        }
    }

    var tint: Color {
        switch self {
        case .ios: .blue
        case .ipados: .green
        case .ipod: .teal
        case .tvos: .gray
        case .audioos: .pink
        case .visionos: .indigo
        case .macos: .purple
        }
    }
}

/// What might come next, worked out from what came before — and said to be
/// exactly that. Tapping it opens the same thing drawn on a timeline.
private struct ForecastCard: View {
    @Environment(ReleaseFeed.self) private var feed
    @AppStorage("forecastPlatform") private var platform: Platform = .ios
    let open: () -> Void

    var body: some View {
        let outlook = feed.outlook(for: platform)
        if !outlook.all.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Forecast", systemImage: "calendar.badge.clock").font(.headline)
                    Text("Japan time").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Picker("Platform", selection: $platform) {
                            ForEach(ReleaseFeed.platforms, id: \.self) { Text($0.title).tag($0) }
                        }
                    } label: {
                        PlatformChip(platform: platform)
                    }
                }
                ForEach(outlook.all) { ForecastRow(forecast: $0, platform: platform) }
                HStack {
                    Text("An estimate from the gaps between past builds, moved off Friday to Sunday since Apple almost always ships Monday to Thursday. Not anything Apple has announced.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Image(systemName: "chart.bar.xaxis").foregroundStyle(.tint)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.tint.opacity(0.08), in: .rect(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.tint.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(.rect(cornerRadius: 22))
            .onTapGesture(perform: open)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Shows the forecast on a timeline"))
        }
    }
}

/// The kind of a forecast, said with a colour and a word, so a release, the
/// next beta of a track and a new version's first beta are never confused.
struct ForecastBadge: View {
    let kind: Forecast.Kind

    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.15), in: .capsule)
    }

    var text: String {
        switch kind {
        case .release, .versionRelease: String(localized: "Release")
        case .beta: String(localized: "Beta")
        case .newVersion: String(localized: "New version")
        }
    }

    var tint: Color { kind.tint }
}

extension Forecast.Kind {
    var tint: Color {
        switch self {
        case .release, .versionRelease: .green
        case .beta: .orange
        case .newVersion: .purple
        }
    }
}

private struct ForecastRow: View {
    let forecast: Forecast
    let platform: Platform

    private var day: Date.FormatStyle { Clocks.japanese(.dateTime.month(.abbreviated).day().weekday(.abbreviated)) }
    private var short: Date.FormatStyle { Clocks.japanese(.dateTime.month(.abbreviated).day()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ForecastBadge(kind: forecast.kind)
                Text(forecast.title).font(.subheadline.weight(.semibold))
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: String(localized: "around %@"), forecast.expected.formatted(day)))
                    .font(.title3.weight(.bold))
                // A range only when there is one.
                if !Clocks.japan.isDate(forecast.earliest, inSameDayAs: forecast.latest) {
                    Text("\(forecast.earliest.formatted(short))–\(forecast.latest.formatted(short))")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if forecast.overdue {
                Text("Past the usual gap; could come any day.")
                    .font(.caption).foregroundStyle(.orange)
            }
            // The reasons, each with the day it points to, so the estimate
            // can be checked rather than taken on trust.
            // The strongest reason here; all of them, with their weights,
            // are a tap away on the timeline.
            if let lead = forecast.signals.first {
                Text("・\(lead.reason) → \(lead.date.formatted(short))"
                     + (forecast.signals.count > 1 ? String(format: String(localized: " (and %lld more)"), forecast.signals.count - 1) : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
