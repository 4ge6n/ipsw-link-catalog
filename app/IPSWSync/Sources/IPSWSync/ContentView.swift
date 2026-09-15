import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var settings = Settings.shared
    @Environment(SyncController.self) private var controller
    @State private var showingDevices = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Folders") {
                    ForEach(Platform.allCases) { platform in
                        FolderRow(platform: platform, settings: settings)
                    }
                }
                Section("Devices") {
                    DeviceSummary(showingDevices: $showingDevices)
                    Toggle("Delete the build each new one replaces", isOn: $settings.prune)
                }
                Section("Transfers") {
                    ConcurrencyRow(settings: settings)
                }
                Section("Schedule") {
                    Toggle("Run every day", isOn: $settings.scheduleEnabled)
                    if settings.scheduleEnabled {
                        TimeRow(settings: settings)
                        if let next = controller.nextRun {
                            LabeledContent("Next run", value: next.formatted(date: .abbreviated, time: .shortened))
                        }
                        Text("A Mac that is asleep at that time runs it on waking instead.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            ActivityPane()
        }
        .frame(minWidth: 620, minHeight: 560)
        .task { await controller.loadDevices() }
        .onChange(of: settings.scheduleEnabled) { controller.scheduleNext() }
        .onChange(of: settings.hour) { controller.scheduleNext() }
        .onChange(of: settings.minute) { controller.scheduleNext() }
        .sheet(isPresented: $showingDevices) { DevicePicker() }
    }
}

private struct FolderRow: View {
    let platform: Platform
    @Bindable var settings: Settings

    var body: some View {
        LabeledContent(platform.title) {
            HStack {
                Text(settings.folder(for: platform)?.path(percentEncoded: false) ?? "Not chosen")
                    .foregroundStyle(settings.folder(for: platform) == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                Button("Choose…") { choose() }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Where \(platform.title) restore images should be kept"
        if panel.runModal() == .OK, let url = panel.url {
            settings.setFolder(url, for: platform)
        }
    }
}

private struct DeviceSummary: View {
    @Binding var showingDevices: Bool
    @Environment(SyncController.self) private var controller
    @Bindable private var settings = Settings.shared

    var body: some View {
        LabeledContent("Included") {
            HStack {
                Text(settings.selectedDevices.isEmpty
                     ? "Every device in the latest release"
                     : "\(settings.selectedDevices.count) selected")
                Spacer()
                Button("Choose…") { showingDevices = true }
                    .disabled(controller.knownDevices.isEmpty)
            }
        }
    }
}

private struct ConcurrencyRow: View {
    @Bindable var settings: Settings

    var body: some View {
        LabeledContent("Download at once") {
            HStack(spacing: 6) {
                TextField("", value: $settings.maxConcurrent, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                    .textFieldStyle(.roundedBorder)
                Stepper("", value: $settings.maxConcurrent, in: 1...16).labelsHidden()
            }
        }
        Text(settings.maxConcurrent == 1
             ? "One transfer has the whole connection to itself."
             : "\(settings.maxConcurrent) transfers share the connection; more is not always faster.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct TimeRow: View {
    @Bindable var settings: Settings

    private var time: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(hour: settings.hour, minute: settings.minute)) ?? .now
            },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                settings.hour = parts.hour ?? 4
                settings.minute = parts.minute ?? 0
            }
        )
    }

    var body: some View {
        DatePicker("At", selection: time, displayedComponents: .hourAndMinute)
    }
}
