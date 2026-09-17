import SwiftUI

/// Every build the catalog knows, arranged the way they are spoken of: the
/// major version, then the point release, then the build, then the image for
/// one device. Three columns where there is room and the same thing pushing a
/// screen at a time where there is not — which is what a split view collapses
/// to on a phone.
struct BrowseView: View {
    @Environment(BrowserModel.self) private var model
    @State private var search = ""
    @State private var major: VersionTree.Major.ID?
    @State private var selected: Release.ID?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            majorList
        } content: {
            versionList
        } detail: {
            if let release = model.releases.first(where: { $0.id == selected }) {
                DeviceList(release: release)
            } else {
                ContentUnavailableView("Choose a build", systemImage: "square.stack.3d.up",
                                       description: Text("Its devices appear here."))
            }
        }
    }

    // MARK: The major version

    private var majorList: some View {
        @Bindable var model = model
        return List(shown, selection: $major) { group in
            LabeledContent {
                Text(group.buildCount.formatted()).foregroundStyle(.secondary)
            } label: {
                Text("\(model.platform.title) \(group.name)")
            }
            .tag(group.id)
        }
        .listStyle(.sidebar)
        .navigationTitle("Catalog")
        .searchable(text: $search, prompt: Text("Version or build"))
        .overlay {
            if let failure = model.failure {
                ContentUnavailableView("Could not load", systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
            } else if model.tree.isEmpty, !model.loading {
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

    // MARK: Its point releases, and the builds under each

    @ViewBuilder private var versionList: some View {
        if let group = shown.first(where: { $0.id == major }) {
            List(selection: $selected) {
                ForEach(group.versions) { version in
                    Section(version.name) {
                        ForEach(version.builds) { release in
                            BuildRow(release: release, label: model.label(for: release))
                                .tag(release.id)
                        }
                    }
                }
            }
            .navigationTitle("\(model.platform.title) \(group.name)")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Choose a version", systemImage: "square.stack.3d.up",
                                   description: Text("Its builds appear here."))
        }
    }

    /// Searching reaches through the whole tree rather than the level being
    /// looked at, so a build number typed in finds the version holding it.
    private var shown: [VersionTree.Major] {
        guard !search.isEmpty else { return model.tree }
        return VersionTree.of(model.releases.filter {
            $0.version.localizedCaseInsensitiveContains(search)
            || $0.build.localizedCaseInsensitiveContains(search)
        })
    }
}

private struct BuildRow: View {
    let release: Release
    /// What Apple called it, where Apple has said so lately.
    let label: String?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(release.build).font(.body.monospaced())
                    if let label {
                        Text(label)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                    // A seal rather than a coloured pill: it is a state, not a
                    // label, and the list is long enough without one on each row.
                    if release.firmwares.contains(where: \.signed) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .accessibilityLabel(Text("signed"))
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let date = release.releasedAt {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        parts.append(String(format: String(localized: "%lld file(s)"), release.firmwares.count))
        return parts.joined(separator: "  ·  ")
    }
}
