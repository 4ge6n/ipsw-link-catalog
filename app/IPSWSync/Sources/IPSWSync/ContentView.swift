import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var settings = Settings.shared
    @Environment(SyncController.self) private var controller
    @State private var showingDevices = false
    @State private var showingBuilds = false
    @State private var showingTransparency = false

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
                Section {
                    DeveloperAccountRow()
                } header: {
                    Text("New builds")
                } footer: {
                    Text("Apple's releases feed and restore catalog are read directly, so a build is known when it ships rather than when a catalog catches up. Betas are only listed on Apple's downloads page, which needs your developer account: you sign in on Apple's own page, and this app never sees your password — only the session Apple hands back.")
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
                    LanguageRow(settings: settings)
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
                Section {
                    LabeledContent("Everything on the drive") {
                        HStack {
                            Button("Check Now") { Task { await controller.verify() } }
                                .disabled(controller.running)
                            Spacer(minLength: 0)
                        }
                    }
                } header: {
                    Text("Checksums")
                } footer: {
                    Text("A run trusts what it checked before, so it need not read every byte each night. This reads them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("About this app") { showingTransparency = true }
                    UpdateRow()
                } header: {
                    Text("Updates")
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
        .sheet(isPresented: $showingTransparency) { TransparencyPanel() }
        // Said before it fetches anything, rather than when someone asks.
        .sheet(isPresented: Binding(
            get: { !settings.sawDisclosure },
            set: { _ in }
        )) {
            TransparencyPanel(firstRun: true)
        }
    }
}

/// Which language the app draws itself in. AppKit reads that once at launch,
/// so a change offers to start the app again rather than pretending to apply.
private struct LanguageRow: View {
    @Bindable var settings: Settings

    var body: some View {
        LabeledContent("Language") {
            HStack {
                Picker("", selection: $settings.language) {
                    ForEach(Language.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
                Spacer()
                if !settings.languageIsCurrent {
                    Button("Reopen Now") { reopen() }
                }
            }
        }
        if !settings.languageIsCurrent {
            Text("The new language appears when IPSW Sync is opened again.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func reopen() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

private struct FolderRow: View {
    let platform: Platform
    @Bindable var settings: Settings
    @State private var problem: String?

    var body: some View {
        LabeledContent(platform.title) {
            HStack {
                // One pop-up naming the folder, rather than a truncated path and
                // a row of buttons beside it — which is how the system offers a
                // place to put something everywhere else.
                Menu {
                    Button("Choose…") { choose() }
                    Button("New…") { create() }
                    if let folder = settings.folder(for: platform) {
                        Divider()
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                        Button("Forget") { settings.setFolder(nil, for: platform) }
                    }
                } label: {
                    Label(name, systemImage: settings.folder(for: platform) == nil ? "folder.badge.questionmark" : "folder")
                }
                .menuStyle(.button)
                .fixedSize()
                .help(settings.folder(for: platform)?.path(percentEncoded: false) ?? "")
                Spacer(minLength: 0)
            }
        }
        if let problem {
            Text(problem).font(.caption).foregroundStyle(.orange)
        }
    }

    /// The folder's own name is what identifies it; the path it sits at is long,
    /// and is a thing to point at rather than to read.
    private var name: String {
        settings.folder(for: platform)?.lastPathComponent ?? String(localized: "Not chosen")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Use This Folder")
        panel.message = String(format: String(localized: "Where %@ restore images should be kept"), platform.title)
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
        panel.nameFieldLabel = String(localized: "Folder:")
        panel.prompt = String(localized: "Create")
        panel.message = String(format: String(localized: "Create a folder for %@ restore images"), platform.title)
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
                     ? String(localized: "Every device in the latest release")
                     : String(format: String(localized: "%lld selected"), settings.selectedDevices.count))
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
        case .checking: String(localized: "Checking…")
        case .available(let version): String(format: String(localized: "%@ available"), version)
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
             ? String(localized: "One transfer has the whole connection to itself.")
             : String(format: String(localized: "%lld transfers share the connection; more is not always faster."),
                      settings.maxConcurrent))
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
