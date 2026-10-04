import SwiftUI

/// What came out, day by day, across every platform the catalog carries.
struct ReleasesView: View {
    @Environment(ReleaseFeed.self) private var feed

    var body: some View {
        @Bindable var feed = feed
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForecastCard()
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
                    Text(day.date.formatted(.dateTime.month(.abbreviated))).font(.callout)
                        .foregroundStyle(.secondary)
                    // The bare number: the locale's day format adds "日" in
                    // Japanese, which wrapped onto a line of its own.
                    Text("\(Calendar.current.component(.day, from: day.date))")
                        .font(.title.weight(.bold)).monospacedDigit()
                        .fixedSize()
                }
                Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
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
/// exactly that.
private struct ForecastCard: View {
    @Environment(ReleaseFeed.self) private var feed
    @AppStorage("forecastPlatform") private var platform: Platform = .ios

    var body: some View {
        let forecast = feed.forecast(for: platform)
        if forecast.release != nil || forecast.beta != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Forecast", systemImage: "calendar.badge.clock")
                        .font(.headline)
                    Spacer()
                    Menu {
                        Picker("Platform", selection: $platform) {
                            ForEach(ReleaseFeed.platforms, id: \.self) { Text($0.title).tag($0) }
                        }
                    } label: {
                        PlatformChip(platform: platform)
                    }
                }
                if let release = forecast.release { ForecastRow(forecast: release, platform: platform) }
                if let beta = forecast.beta { ForecastRow(forecast: beta, platform: platform) }
                Text("An estimate from the gaps between past builds, moved off Friday to Sunday since Apple almost always ships Monday to Thursday. Not anything Apple has announced.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.tint.opacity(0.08), in: .rect(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.tint.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
    }
}

private struct ForecastRow: View {
    let forecast: Forecast
    let platform: Platform

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(forecast.title).font(.subheadline.weight(.semibold))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: String(localized: "around %@"),
                            forecast.expected.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated))))
                    .font(.title3.weight(.bold))
                // A range only when there is one: gaps that were all the same
                // made "28 Sep–28 Sep".
                if !Calendar.current.isDate(forecast.earliest, inSameDayAs: forecast.latest) {
                    Text("\(forecast.earliest.formatted(.dateTime.month(.abbreviated).day()))–\(forecast.latest.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if forecast.overdue {
                Text("Past the usual gap; could come any day.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(String(format: String(localized: "Typical gap %1$lld days, from the last %2$lld; last was %3$@ on %4$@."),
                        forecast.typicalDays, forecast.samples,
                        "\(platform.title) \(forecast.after.release.displayVersion)",
                        (forecast.after.release.releasedAt ?? .now).formatted(.dateTime.month(.abbreviated).day())))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
