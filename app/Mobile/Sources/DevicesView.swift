import UIKit
import SwiftUI

/// Every device the catalog knows, each opening onto what it can be
/// restored to and what it can no longer.
struct DevicesView: View {
    @Environment(ReleaseFeed.self) private var feed
    @State private var search = ""
    @State private var showingVersions = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(shown, id: \.platform) { group in
                    Section(group.platform.title) {
                        ForEach(group.identifiers, id: \.self) { identifier in
                            NavigationLink(value: identifier) {
                                DeviceRow(identifier: identifier)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Devices")
            .searchable(text: $search, prompt: Text("Name or identifier"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // The version tree is still here, for looking at a build
                    // rather than at a device.
                    Button("By version", systemImage: "square.stack.3d.up") { showingVersions = true }
                }
            }
            .overlay {
                if feed.entries.isEmpty, feed.loading { ProgressView() }
            }
            .navigationDestination(for: String.self) { DeviceDetailView(identifier: $0) }
            .refreshable { await feed.load() }
            .task { if feed.entries.isEmpty { await feed.load() } }
            .sheet(isPresented: $showingVersions) { BrowseView() }
        }
    }

    private var shown: [(platform: Platform, identifiers: [String])] {
        guard !search.isEmpty else { return feed.devices }
        return feed.devices.compactMap { group -> (platform: Platform, identifiers: [String])? in
            let ids = group.identifiers.filter {
                $0.localizedCaseInsensitiveContains(search)
                || DeviceNames.name($0).localizedCaseInsensitiveContains(search)
            }
            return ids.isEmpty ? nil : (group.platform, ids)
        }
    }
}

private struct DeviceRow: View {
    @Environment(ReleaseFeed.self) private var feed
    let identifier: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(DeviceNames.name(identifier))
                Text(identifier).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let newest = feed.newestSigned(identifier) {
                Text(newest.entry.release.displayVersion)
                    .font(.callout.monospacedDigit()).foregroundStyle(.green)
            }
        }
    }
}

/// One device: what Apple will restore it to now, and what it no longer will.
struct DeviceDetailView: View {
    @Environment(ReleaseFeed.self) private var feed
    let identifier: String

    var body: some View {
        let history = feed.history(of: identifier)
        let signed = history.filter { $0.firmware.signed == true }
        let stopped = history.filter { $0.firmware.signed == false }
        let unknown = history.filter { $0.firmware.signed == nil }
        List {
            if !signed.isEmpty {
                Section {
                    ForEach(signed) { BuildRow(build: $0, signed: true) }
                } header: {
                    Label("Signed", systemImage: "circle.fill").foregroundStyle(.green)
                }
                .listRowBackground(Color.green.opacity(0.08))
            }
            // A build nobody has asked Apple about yet is neither, and is
            // said to be neither.
            if !unknown.isEmpty {
                Section {
                    ForEach(unknown) { BuildRow(build: $0, signed: nil) }
                } header: {
                    Label("Not checked", systemImage: "circle.dashed").foregroundStyle(.orange)
                }
            }
            if !stopped.isEmpty {
                Section {
                    ForEach(stopped) { BuildRow(build: $0, signed: false) }
                } header: {
                    Label("No longer signed", systemImage: "circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(DeviceNames.name(identifier))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let starred = Favorites.shared.contains(identifier)
                Button(starred ? "Remove from My Devices" : "Add to My Devices",
                       systemImage: starred ? "star.fill" : "star") {
                    Favorites.shared.toggle(identifier)
                }
            }
        }
        .overlay {
            if history.isEmpty {
                if feed.loading { ProgressView() }
                else { ContentUnavailableView("Nothing in the catalog for this device", systemImage: "tray") }
            }
        }
    }
}

private struct BuildRow: View {
    @Environment(BrowserModel.self) private var model
    let build: ReleaseFeed.DeviceBuild
    let signed: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(build.entry.release.displayVersion)
                    .font(.body.weight(signed == true ? .semibold : .regular))
                    .foregroundStyle(signed == false ? .secondary : .primary)
                Text("(\(build.entry.release.build))").font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                action
            }
            if let transfer = model.transfer(for: build.firmware), model.isRunning(build.firmware) {
                ProgressView(value: transfer.fraction)
            }
            if build.firmware.devices.count > 1 {
                Text(String(format: String(localized: "One file for %lld devices"), build.firmware.devices.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .linkMenu(for: build.firmware)
    }

    @ViewBuilder private var action: some View {
        if model.saved.contains(where: { $0.name == build.firmware.filename }) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .accessibilityLabel(Text("Saved"))
        } else if model.isRunning(build.firmware) {
            Button("Stop", systemImage: "stop.circle.fill") { model.cancel(build.firmware) }
                .labelStyle(.iconOnly).font(.title2)
        } else if signed != false {
            // Saving one Apple no longer signs is allowed — it is still a real
            // file — but the button is only offered where it is likely useful.
            Button("Save", systemImage: "arrow.down.circle.fill") {
                Task { await model.download(build.firmware) }
            }
            .labelStyle(.iconOnly).font(.title2)
        }
    }
}

/// This device first, then the ones starred.
struct MyDevicesView: View {
    @Environment(ReleaseFeed.self) private var feed
    @State private var favorites = Favorites.shared

    var body: some View {
        NavigationStack {
            List {
                Section(String(format: String(localized: "This %@"), ThisDevice.current.kindName)) {
                    NavigationLink(value: ThisDevice.current.identifier) {
                        ThisDeviceSummary()
                    }
                }
                Section("Starred") {
                    if favorites.identifiers.isEmpty {
                        Text("Star a device from Devices to keep it here.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(favorites.identifiers, id: \.self) { identifier in
                        NavigationLink(value: identifier) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(DeviceNames.name(identifier))
                                HStack(spacing: 6) {
                                    Text(identifier)
                                    if let newest = feed.newestSigned(identifier) {
                                        Text("·")
                                        Text(newest.entry.release.displayVersion).foregroundStyle(.green)
                                    }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { favorites.toggle(favorites.identifiers[index]) }
                    }
                }
            }
            .navigationTitle("My Devices")
            .navigationDestination(for: String.self) { DeviceDetailView(identifier: $0) }
            .refreshable { await feed.load() }
            .task { if feed.entries.isEmpty { await feed.load() } }
        }
    }
}

private struct ThisDeviceSummary: View {
    @Environment(ReleaseFeed.self) private var feed
    private let mine = ThisDevice.current

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(DeviceNames.name(mine.identifier)).font(.headline)
            Text(mine.build.isEmpty ? "\(mine.identifier) · \(mine.version)"
                                     : "\(mine.identifier) · \(mine.version) (\(mine.build))")
                .font(.caption).foregroundStyle(.secondary)
            if let newest = feed.newestSigned(mine.identifier) {
                if newest.entry.release.build.caseInsensitiveCompare(mine.build) == .orderedSame {
                    Text("up to date").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                } else {
                    Text(String(format: String(localized: "%1$@ (%2$@) available"),
                                newest.entry.release.displayVersion, newest.entry.release.build))
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.tint.opacity(0.15), in: .capsule)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Long-press on any build: copy its IPSW link, or share it. The link is
/// Apple's own, straight from the catalog.
struct LinkMenu: ViewModifier {
    let firmware: Firmware

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Copy Link", systemImage: "doc.on.doc") {
                UIPasteboard.general.url = firmware.url
                UIPasteboard.general.string = firmware.url.absoluteString
            }
            ShareLink(item: firmware.url) {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }
        } preview: {
            VStack(alignment: .leading, spacing: 4) {
                Text(firmware.name).font(.headline)
                Text(firmware.filename).font(.caption.monospaced())
                Text(firmware.url.host() ?? "").font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

extension View {
    func linkMenu(for firmware: Firmware) -> some View { modifier(LinkMenu(firmware: firmware)) }
}
