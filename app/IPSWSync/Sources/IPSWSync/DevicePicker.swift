import SwiftUI

/// Pick the devices to keep images for. Choosing none keeps none: whether
/// every device is wanted is its own switch, not the absence of a choice.
struct DevicePicker: View {
    @Environment(SyncController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = Settings.shared
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Devices").font(.headline)
                Spacer()
                Button("Select All") {
                    settings.everyDevice = false
                    settings.selectedDevices = Set(every.flatMap(\.devices))
                }
                Button("None") {
                    settings.everyDevice = false
                    settings.selectedDevices = []
                }
            }
            .padding(12)
            Divider()
            Toggle("Keep an image for every signed device", isOn: $settings.everyDevice)
                .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            List {
                ForEach(Platform.allCases) { platform in
                    Section(platform.title) {
                        ForEach(matching(platform)) { firmware in
                            DeviceRow(firmware: firmware, settings: settings,
                                      allDevices: allDevices)
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar)
            Divider()
            HStack {
                Text(summary)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 520)
    }

    /// What "every device" means as a list, so unticking one row while it is
    /// on leaves the other hundred-odd on rather than clearing the lot.
    private var allDevices: Set<String> { Set(every.flatMap(\.devices)) }

    private var every: [Firmware] { Platform.allCases.flatMap { controller.knownDevices[$0] ?? [] } }

    private func matching(_ platform: Platform) -> [Firmware] {
        let all = (controller.knownDevices[platform] ?? []).sorted(by: Firmware.newestFirst)
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(search)
            || $0.devices.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    /// What the choice above actually means, in devices and in gigabytes.
    private var summary: String {
        if settings.everyDevice {
            return String(format: String(localized: "Every device: %1$lld image(s), about %2$@ to hold."),
                          every.count, estimate)
        }
        if settings.selectedDevices.isEmpty {
            return String(localized: "Nothing chosen, so nothing will be kept.")
        }
        return String(format: String(localized: "%1$lld device(s), about %2$@ to hold."),
                      settings.selectedDevices.count, estimate)
    }

    /// Restore images run about nine gigabytes each; worth saying before a
    /// selection quietly turns into hundreds of them.
    private var estimate: String {
        let chosen = settings.everyDevice
            ? every
            : every.filter { !settings.selectedDevices.isDisjoint(with: $0.devices) }
        return (Int64(chosen.count) * 9_000_000_000).formatted(.byteCount(style: .file))
    }
}

private struct DeviceRow: View {
    let firmware: Firmware
    @Bindable var settings: Settings
    let allDevices: Set<String>

    private var isOn: Binding<Bool> {
        Binding(
            get: { settings.everyDevice || !settings.selectedDevices.isDisjoint(with: firmware.devices) },
            set: { keep in
                if settings.everyDevice {
                    settings.everyDevice = false
                    settings.selectedDevices = allDevices
                }
                if keep { settings.selectedDevices.formUnion(firmware.devices) }
                else { settings.selectedDevices.subtract(firmware.devices) }
            }
        )
    }

    var body: some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(firmware.name)
                Text(firmware.devices.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
