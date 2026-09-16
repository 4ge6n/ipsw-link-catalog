import SwiftUI

/// Every build the catalog knows, down to the image for one device. Two columns
/// where there is room for them, and the same list pushing a screen where there
/// is not — which is what a split view collapses to on a phone.
struct BrowseView: View {
    @Environment(BrowserModel.self) private var model
    @State private var search = ""
    @State private var selected: Release.ID?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(shown, selection: $selected) { release in
                ReleaseRow(release: release).tag(release.id)
            }
            .listStyle(.sidebar)
            .navigationTitle("Catalog")
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
        } detail: {
            if let release = model.releases.first(where: { $0.id == selected }) {
                DeviceList(release: release)
            } else {
                ContentUnavailableView("Choose a build", systemImage: "square.stack.3d.up",
                                       description: Text("Its devices appear here."))
            }
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
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(release.version)
                        .font(.body)
                    // A seal rather than a coloured pill: it is a state, not a
                    // label, and the list is long enough without one on each row.
                    if release.firmwares.contains(where: \.signed) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .accessibilityLabel(Text("signed"))
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [release.build]
        if let date = release.releasedAt {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        parts.append(String(format: String(localized: "%lld file(s)"), release.firmwares.count))
        return parts.joined(separator: "  ·  ")
    }
}
