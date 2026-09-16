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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(firmware.name).font(.headline)
                    Text(firmware.devices.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !firmware.signed {
                    Text("not signed")
                        .font(.caption2)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .glassEffect(.regular, in: .capsule)
                }
            }

            // One container, so the controls beside each other read as a single
            // pane of glass rather than several.
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

            if let transfer = model.transfer(for: firmware), model.isRunning(firmware) {
                ProgressView(value: transfer.fraction)
                Text(detail(transfer))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var action: some View {
        if model.isRunning(firmware) {
            Button("Stop", systemImage: "stop.fill") { model.cancel() }
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
