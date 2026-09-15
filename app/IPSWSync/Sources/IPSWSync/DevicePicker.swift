import SwiftUI

/// Pick the devices to keep images for. Choosing none means every device.
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
                Button("Select All") { settings.selectedDevices = Set(every.flatMap(\.devices)) }
                Button("Every Device") { settings.selectedDevices = [] }
            }
            .padding(12)
            Divider()
            List {
                ForEach(Platform.allCases) { platform in
                    Section(platform.title) {
                        ForEach(matching(platform)) { firmware in
                            DeviceRow(firmware: firmware, settings: settings)
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar)
            Divider()
            HStack {
                Text(settings.selectedDevices.isEmpty
                     ? "Every device will be kept up to date."
                     : "\(settings.selectedDevices.count) device(s), about \(estimate) to hold.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 520)
    }

    private var every: [Firmware] { Platform.allCases.flatMap { controller.knownDevices[$0] ?? [] } }

    private func matching(_ platform: Platform) -> [Firmware] {
        let all = (controller.knownDevices[platform] ?? []).sorted(by: Firmware.newestFirst)
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(search)
            || $0.devices.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    /// Restore images run about nine gigabytes each; worth saying before a
    /// selection quietly turns into hundreds of them.
    private var estimate: String {
        let chosen = every.filter { !settings.selectedDevices.isDisjoint(with: $0.devices) }
        return (Int64(chosen.count) * 9_000_000_000).formatted(.byteCount(style: .file))
    }
}

private struct DeviceRow: View {
    let firmware: Firmware
    @Bindable var settings: Settings

    private var isOn: Binding<Bool> {
        Binding(
            get: { !settings.selectedDevices.isDisjoint(with: firmware.devices) },
            set: { keep in
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
