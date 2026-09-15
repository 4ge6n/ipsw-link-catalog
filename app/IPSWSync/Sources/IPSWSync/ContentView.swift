import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var settings = Settings.shared
    @Environment(SyncController.self) private var controller
    @State private var showingDevices = false
    @State private var showingBuilds = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Folders") {
                    ForEach(Platform.allCases) { platform in
                        FolderRow(platform: platform, settings: settings)
                    }
                }
                Section {
                    ForEach(Platform.allCases) { platform in
                        StandardLocationRow(platform: platform, settings: settings)
                    }
                } header: {
                    Text("Finder's restore folder")
                } footer: {
                    Text("Finder looks in ~/Library/iTunes for restore images. Linking it to your folder lets a restore use what is on the drive without copying it there.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Devices") {
                    DeviceSummary(showingDevices: $showingDevices)
                    Toggle("Delete the build each new one replaces", isOn: $settings.prune)
                }
                Section("Transfers") {
                    ConcurrencyRow(settings: settings)
                }
                Section("One-off downloads") {
                    LabeledContent("Any build") {
                        HStack {
                            Text("Pick a version and devices, including older or beta builds")
                                .foregroundStyle(.secondary).lineLimit(2)
                            Spacer()
                            Button("Browse…") { showingBuilds = true }
                        }
                    }
                }
                Section("Appearance") {
                    Toggle("Show in the Dock", isOn: $settings.showInDock)
                    Toggle("Show in the menu bar", isOn: $settings.showInMenuBar)
                    if settings.isHidden {
                        Label(
                            "The app will run with nothing on screen. Opening IPSW Sync again from Finder brings this window back and turns both switches on.",
                            systemImage: "eye.slash"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Updates") {
                    UpdateRow()
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
            .frame(maxHeight: .infinity)
            Divider()
            ActivityPane()
        }
        // Small enough to park in a corner, with the layout adapting rather
        // than the settings being cut off.
        .frame(minWidth: 320, minHeight: 260)
        .task { await controller.loadDevices() }
        .onChange(of: settings.scheduleEnabled) { controller.scheduleNext() }
        .onChange(of: settings.hour) { controller.scheduleNext() }
        .onChange(of: settings.minute) { controller.scheduleNext() }
        .sheet(isPresented: $showingDevices) { DevicePicker() }
        .sheet(isPresented: $showingBuilds) { BuildPicker().environment(controller) }
    }
}

private struct FolderRow: View {
    let platform: Platform
    @Bindable var settings: Settings
    @State private var problem: String?

    var body: some View {
        LabeledContent(platform.title) {
            HStack {
                Text(settings.folder(for: platform)?.path(percentEncoded: false) ?? "Not chosen")
                    .foregroundStyle(settings.folder(for: platform) == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                Button("New…") { create() }
                Button("Choose…") { choose() }
            }
        }
        if let problem {
            Text(problem).font(.caption).foregroundStyle(.orange)
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
            problem = nil
            settings.setFolder(url, for: platform)
        }
    }

    /// A save panel rather than an open one, because only that offers a name to
    /// fill in — and the name worth offering is the one Finder restores from,
    /// so a drive laid out by hand matches what a link would point at anyway.
    private func create() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = StandardLocation.folderName(for: platform)
        panel.nameFieldLabel = "Folder:"
        panel.prompt = "Create"
        panel.message = "Create a folder for \(platform.title) restore images"
        panel.directoryURL = settings.folder(for: platform)?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            problem = nil
            settings.setFolder(url, for: platform)
        } catch {
            problem = error.localizedDescription
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

private struct UpdateRow: View {
    @Environment(SyncController.self) private var controller
    @Bindable private var settings = Settings.shared

    var body: some View {
        Toggle("Keep IPSW Sync up to date", isOn: $settings.autoUpdate)
        LabeledContent("Version") {
            HStack {
                Text(status).foregroundStyle(.secondary)
                Spacer()
                Button("Check Now") {
                    Task { await controller.updater.check(installAutomatically: true) }
                }
                .disabled(busy)
            }
        }
    }

    private var busy: Bool {
        switch controller.updater.state {
        case .checking, .downloading: true
        default: false
        }
    }

    private var status: String {
        switch controller.updater.state {
        case .idle: "\(controller.updater.currentVersion) — up to date"
        case .checking: "Checking…"
        case .available(let version): "\(version) available"
        case .downloading(let fraction): "Downloading \(Int(fraction * 100))%"
        case .installed(let version): "Updated to \(version); restarting"
        case .failed(let why): why
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
