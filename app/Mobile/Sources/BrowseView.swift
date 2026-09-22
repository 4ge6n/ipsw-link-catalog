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
    @State private var showingThisDevice = false

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
        return List(selection: $major) {
            // The device in your hand is somewhere in a list of every device
            // Apple has shipped. It is easier to start from it.
            if search.isEmpty, let mine = forThisDevice {
                Section(String(format: String(localized: "This %@"), ThisDevice.current.kindName)) {
                    // A button and a sheet rather than a NavigationLink: this
                    // list drives the split view's other columns through its
                    // selection, and a link inside it is swallowed by that.
                    Button { showingThisDevice = true } label: {
                        HStack {
                            ThisDeviceRow(release: mine.release, images: mine.images,
                                          name: ThisDevice.current.name(from: model.releases))
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                ForEach(shown) { group in
                    LabeledContent {
                        Text(group.buildCount.formatted()).foregroundStyle(.secondary)
                    } label: {
                        Text("\(model.platform.title) \(group.name)")
                    }
                    .tag(group.id)
                }
            }
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
        .sheet(isPresented: $showingThisDevice) {
            if let mine = forThisDevice {
                NavigationStack {
                    DeviceList(release: mine.release, only: ThisDevice.current.identifier)
                }
            }
        }
    }

    // MARK: Its point releases, and the builds under each

    @ViewBuilder private var versionList: some View {
        if let group = shown.first(where: { $0.id == major }) {
            List(selection: $selected) {
                ForEach(group.versions) { version in
                    Section(version.name) {
                        ForEach(version.builds) { release in
                            BuildRow(release: release)
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

    /// The newest build in the catalog that this very device can be restored
    /// with — which is not always the newest build there is, since one image
    /// does not cover every device.
    private var forThisDevice: (release: Release, images: [Firmware])? {
        let mine = ThisDevice.current
        guard !mine.identifier.isEmpty else { return nil }
        for release in model.releases {
            let images = mine.images(in: release)
            if !images.isEmpty { return (release, images) }
        }
        return nil
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

/// What this device is on, and what it could be put on.
private struct ThisDeviceRow: View {
    let release: Release
    let images: [Firmware]
    let name: String
    private let mine = ThisDevice.current

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.body)
            HStack(spacing: 6) {
                Text(mine.identifier)
                Text("·")
                // What it is running now, said in the same words as the
                // catalog: a version is not a build, and a restore is keyed
                // by the build.
                Text(mine.build.isEmpty ? mine.version : "\(mine.version) (\(mine.build))")
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if mine.isInstalled(release) {
                    Text("up to date")
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                } else {
                    Text(String(format: String(localized: "%1$@ (%2$@) available"),
                                release.versionLabel ?? release.version, release.build))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.tint.opacity(0.15), in: .capsule)
                }
                if images.contains(where: { $0.signed == true }) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        .accessibilityLabel(Text("signed"))
                }
            }
            .font(.caption2)
        }
        .padding(.vertical, 2)
    }
}

private struct BuildRow: View {
    let release: Release

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // Not a monospaced face: a build number is a name, and a
                    // list of names set in code type reads as output rather
                    // than as something to choose from. Monospaced digits keep
                    // the numbers lining up down the column.
                    Text(release.build).font(.body.monospacedDigit())
                    if let label = release.prerelease {
                        Text(label)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                    // A seal rather than a coloured pill: it is a state, not a
                    // label, and the list is long enough without one on each row.
                    // Only where Apple has actually been asked. "Not checked" shown
                    // as signed is the same defect as showing it as unsigned.
                    if release.firmwares.contains(where: { $0.signed == true }) {
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
