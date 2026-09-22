import SwiftUI

/// The devices one build covers. A row is a device first and a download second,
/// so the name leads and the action is the small capsule Apple puts at the
/// trailing edge rather than a bar across the row.
struct DeviceList: View {
    let release: Release
    /// Set when the list was opened from "This iPhone": the one device is
    /// what was asked for, and the other sixty are not.
    var only: String? = nil
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
                Toggle("Hide unsigned", systemImage: "checkmark.seal", isOn: $signedOnly)
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
            .filter { only == nil || $0.devices.contains(only!) }
            .filter { firmware in
                (!signedOnly || firmware.mightBeSigned)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(firmware.name)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)
                action
            }

            if let transfer = model.transfer(for: firmware) {
                if model.isRunning(firmware) {
                    ProgressView(value: transfer.fraction)
                        .progressViewStyle(.linear)
                    Text(detail(transfer))
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                } else if case .failed(let why) = transfer.state {
                    Text(why)
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        // The link is worth having and not worth a button on every row.
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            ShareLink(item: firmware.url) {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }
            .tint(.accentColor)
        }
        .contextMenu {
            ShareLink(item: firmware.url) {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var symbol: String {
        let identifier = firmware.devices.first ?? ""
        if identifier.hasPrefix("iPad") { return "ipad" }
        if identifier.hasPrefix("iPod") { return "ipodtouch" }
        return "iphone"
    }

    /// Three states, not two. A beta is published before anyone has asked
    /// Apple's signing server about it, and every one of them was being
    /// labelled "not signed" — which was not something anything had checked.
    /// Nothing is said until there is something to say.
    private var subtitle: String {
        let devices = firmware.devices.joined(separator: ", ")
        switch firmware.signed {
        case .some(true), .none: return devices
        case .some(false): return devices + " · " + String(localized: "not signed")
        }
    }

    /// Small and at the trailing edge, the way a download is offered everywhere
    /// else on the system.
    @ViewBuilder private var action: some View {
        if model.isRunning(firmware) {
            Button("Stop", systemImage: "stop.fill") { model.cancel(firmware) }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        } else if model.alreadySaved(firmware) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel(Text("Saved"))
        } else {
            // Tinted text on a quiet capsule rather than a solid block of
            // colour: there is one of these on every row, and the App Store
            // does not shout on every row either.
            Button("Save") { Task { await model.download(firmware) } }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .font(.footnote.weight(.semibold))
        }
    }

    private func detail(_ transfer: Transfer) -> String {
        let received = transfer.received.formatted(.byteCount(style: .file))
        guard transfer.total > 0 else { return received }
        return "\(received) / \(transfer.total.formatted(.byteCount(style: .file)))"
    }
}
