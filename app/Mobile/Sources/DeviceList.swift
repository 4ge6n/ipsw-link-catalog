import SwiftUI

/// The devices one build covers, and what can be done with each image.
struct DeviceList: View {
    let release: Release
    @Environment(BrowserModel.self) private var model
    @State private var search = ""
    @State private var signedOnly = false

    var body: some View {
        List {
            ForEach(shown) { firmware in
                FirmwareRow(firmware: firmware)
            }
        }
        .listStyle(.plain)
        .navigationTitle("\(release.version) (\(release.build))")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: Text("Search devices"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle("Signed only", systemImage: "checkmark.seal", isOn: $signedOnly)
                    .toggleStyle(.button)
            }
        }
        .overlay {
            if shown.isEmpty {
                ContentUnavailableView("Nothing here", systemImage: "tray")
            }
        }
    }

    private var shown: [Firmware] {
        release.firmwares
            .filter { firmware in
                (!signedOnly || firmware.signed)
                && (search.isEmpty
                    || firmware.name.localizedCaseInsensitiveContains(search)
                    || firmware.devices.contains { $0.localizedCaseInsensitiveContains(search) })
            }
            .sorted(by: Firmware.newestFirst)
    }
}

private struct FirmwareRow: View {
    let firmware: Firmware
    @Environment(BrowserModel.self) private var model
    @Environment(\.horizontalSizeClass) private var width

    private var wide: Bool { width == .regular }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Side by side where the window is wide enough for it — an iPad
            // leaves a whole column empty otherwise — and stacked where it is not.
            if wide {
                HStack(spacing: 16) {
                    naming
                    Spacer(minLength: 16)
                    controls
                }
            } else {
                naming
                controls
            }

            if let transfer = model.transfer(for: firmware) {
                if model.isRunning(firmware) {
                    ProgressView(value: transfer.fraction)
                    Text(detail(transfer))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else if case .failed(let why) = transfer.state {
                    // Said out loud rather than leaving the button to go quietly
                    // back to how it looked before anything was pressed.
                    Label(why, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var naming: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(firmware.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(firmware.devices.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !firmware.signed {
                Text("not signed")
                    .font(.caption2)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)
            }
        }
    }

    /// One container, so the controls beside each other read as a single pane of
    /// glass rather than several.
    private var controls: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                action
                ShareLink(item: firmware.url) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass)
            }
        }
    }

    @ViewBuilder private var action: some View {
        if model.isRunning(firmware) {
            Button("Stop", systemImage: "stop.fill") { model.cancel(firmware) }
                .buttonStyle(.glass)
        } else if model.alreadySaved(firmware) {
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .glassEffect(.regular.tint(.green.opacity(0.3)), in: .capsule)
        } else {
            Button("Save to Files", systemImage: "arrow.down.circle") {
                Task { await model.download(firmware) }
            }
            .buttonStyle(.glassProminent)
            .disabled(model.isBusy)
        }
    }

    private func detail(_ transfer: Transfer) -> String {
        let received = transfer.received.formatted(.byteCount(style: .file))
        guard transfer.total > 0 else { return received }
        return "\(received) / \(transfer.total.formatted(.byteCount(style: .file)))"
    }
}
