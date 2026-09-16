import SwiftUI

/// Every build the catalog knows, down to the image for one device.
struct BrowseView: View {
    @Environment(BrowserModel.self) private var model
    @State private var search = ""

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                ForEach(shown) { release in
                    NavigationLink(value: release) {
                        ReleaseRow(release: release)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Catalog")
            .navigationDestination(for: Release.self) { release in
                DeviceList(release: release)
            }
            .searchable(text: $search, prompt: Text("Version or build"))
            .overlay {
                if let failure = model.failure {
                    ContentUnavailableView("Could not load", systemImage: "exclamationmark.triangle",
                                           description: Text(failure))
                } else if model.releases.isEmpty, !model.loading {
                    ContentUnavailableView("Nothing here", systemImage: "tray")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("", selection: $model.platform) {
                        ForEach(Platform.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                ToolbarSpacer(.flexible, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("", selection: $model.channel) {
                        ForEach(Channel.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            }
            .refreshable { await model.load() }
        }
    }

    private var shown: [Release] {
        guard !search.isEmpty else { return model.releases }
        return model.releases.filter {
            $0.version.localizedCaseInsensitiveContains(search)
            || $0.build.localizedCaseInsensitiveContains(search)
        }
    }
}

private struct ReleaseRow: View {
    let release: Release

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(release.version) (\(release.build))")
                    .font(.headline)
                HStack(spacing: 8) {
                    if let date = release.releasedAt {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                    }
                    Text(String(format: String(localized: "%lld file(s)"), release.firmwares.count))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if release.firmwares.contains(where: \.signed) {
                Text("signed")
                    .font(.caption2).fontWeight(.medium)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .glassEffect(.regular.tint(.green.opacity(0.35)), in: .capsule)
            }
        }
        .padding(.vertical, 4)
    }
}
