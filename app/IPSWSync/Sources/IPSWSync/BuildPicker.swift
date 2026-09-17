import AppKit
import SwiftUI

/// Pick a build by hand and fetch it, rather than waiting for the daily run to
/// bring whatever is current.
struct BuildPicker: View {
    @Environment(SyncController.self) private var controller
    @Environment(\.dismiss) private var dismiss

    /// Where the list comes from. The catalog is every build ever published;
    /// Apple is what it is offering this minute, which is the only place a
    /// build posted an hour ago can be found.
    private enum Source: String, CaseIterable, Identifiable {
        case catalog, live
        var id: String { rawValue }
        var title: String {
            self == .catalog ? String(localized: "Catalog") : String(localized: "From Apple")
        }
    }

    @State private var platform: Platform = .ios
    @State private var source: Source = .catalog
    @State private var channel: Channel = .release
    @State private var releases: [Release] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var selectedRelease: Release.ID?
    @State private var chosenDevices: Set<String> = []
    @State private var search = ""
    @State private var signedOnly = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                releaseList
                    .frame(minWidth: 200, idealWidth: 250)
                deviceList
                    .frame(minWidth: 260)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 760, minHeight: 420, idealHeight: 560)
        .task(id: reloadKey) { await load() }
    }

    private var reloadKey: String { "\(platform.rawValue)-\(source.rawValue)-\(channel.rawValue)" }

    private var header: some View {
        HStack(spacing: 10) {
            // A pop-up rather than a row of segments: seven platforms across a
            // segmented control left each one a few letters wide and the labels
            // running into each other. Two choices stay segmented, which is
            // what a segmented control is for.
            Picker("Platform", selection: $platform) {
                ForEach(Platform.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Picker("", selection: $source) {
                ForEach(Source.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if source == .catalog {
                Picker("", selection: $channel) {
                    ForEach(Channel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Spacer(minLength: 8)
            if loading { ProgressView().controlSize(.small) }
        }
        .padding(12)
    }

    private var releaseList: some View {
        List(releases, selection: $selectedRelease) { release in
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(release.version) (\(release.build))").fontWeight(.medium)
                    // Apple's own numbering of the build, where the catalog
                    // recorded it. Never worked out from the order here.
                    if let prerelease = release.prerelease {
                        Text(prerelease)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .glassEffect(.regular, in: .capsule)
                    }
                }
                HStack(spacing: 6) {
                    if let date = release.releasedAt {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                    }
                    Text(String(format: String(localized: "%lld file(s)"), release.firmwares.count))
                    if release.firmwares.contains(where: \.signed) {
                        Text("signed")
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .glassEffect(.regular.tint(.green.opacity(0.35)), in: .capsule)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .tag(release.id)
        }
        .overlay {
            if let failure { ContentUnavailableView("Could not load", systemImage: "exclamationmark.triangle", description: Text(failure)) }
            else if releases.isEmpty, !loading { ContentUnavailableView("Nothing here", systemImage: "tray") }
        }
    }

    private var current: Release? { releases.first { $0.id == selectedRelease } }

    private var shown: [Firmware] {
        let all = current?.firmwares ?? []
        return all.filter { firmware in
            (!signedOnly || firmware.signed)
            && (search.isEmpty
                || firmware.name.localizedCaseInsensitiveContains(search)
                || firmware.devices.contains { $0.localizedCaseInsensitiveContains(search) })
        }
        .sorted(by: Firmware.newestFirst)
    }

    private var deviceList: some View {
        VStack(spacing: 0) {
            if current == nil {
                ContentUnavailableView("Choose a build", systemImage: "square.stack.3d.up",
                                       description: Text("Its devices appear here."))
            } else {
                // An explicit field rather than .searchable, which in a sheet
                // puts a second one above the panel.
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search devices", text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                Divider()
                List {
                    ForEach(shown) { firmware in
                        Toggle(isOn: binding(for: firmware)) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(firmware.name)
                                    if !firmware.signed {
                                        Text("not signed").font(.caption2)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .glassEffect(.regular, in: .capsule)
                                    }
                                }
                                Text(firmware.devices.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func binding(for firmware: Firmware) -> Binding<Bool> {
        Binding(
            get: { chosenDevices.contains(firmware.id) },
            set: { keep in
                if keep { chosenDevices.insert(firmware.id) } else { chosenDevices.remove(firmware.id) }
            }
        )
    }

    private var footer: some View {
        // One container, so the row of controls reads as a single pane rather
        // than as several sheets of glass sitting beside each other.
        GlassEffectContainer(spacing: 8) {
            HStack {
                Button("Close") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Toggle("Signed only", isOn: $signedOnly)
                Button("Select All") { chosenDevices.formUnion(shown.map(\.id)) }
                    .buttonStyle(.glass)
                    .disabled(shown.isEmpty)
                Button("None") { chosenDevices.removeAll() }
                    .buttonStyle(.glass)
                    .disabled(chosenDevices.isEmpty)
                Spacer()
                Text(chosenDevices.isEmpty
                     ? ""
                     : String(format: String(localized: "%lld selected"), chosenDevices.count))
                    .font(.caption).foregroundStyle(.secondary)
                Button("Download…") { download() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosenDevices.isEmpty || controller.running)
            }
            .padding(12)
        }
    }

    private func load() async {
        loading = true
        failure = nil
        defer { loading = false }
        do {
            switch source {
            case .catalog:
                releases = try await controller.everyBuild(platform, channel: channel)
            case .live:
                releases = await controller.liveReleases(platform)
                // Something answered, but not with anything for this platform.
                if releases.isEmpty, let said = controller.watch.failure { failure = said }
            }
            selectedRelease = releases.first?.id
            chosenDevices = []
        } catch {
            releases = []
            failure = error.localizedDescription
        }
    }

    private func download() {
        let picked = (current?.firmwares ?? []).filter { chosenDevices.contains($0.id) }
        guard !picked.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Download Here")
        panel.message = String(format: String(localized: "Where to put %lld file(s)"), picked.count)
        panel.directoryURL = Settings.shared.folder(for: platform)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        dismiss()
        Task { await controller.download(picked, into: folder) }
    }
}
