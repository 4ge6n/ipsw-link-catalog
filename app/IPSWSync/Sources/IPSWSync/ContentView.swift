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
                Section {
                    ForEach(Platform.allCases) { platform in
                        FolderRow(platform: platform, settings: settings)
                    }
                } header: {
                    Text("Folders")
                } footer: {
                    Text("Each platform keeps to its own folder. One left unchosen is skipped, so a Mac that only holds iPhone images need choose only that. Finder has a name for each — “iPhone Software Updates” and the rest — and a folder called that works whether it is linked or simply put where Finder looks.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(StandardLocation.linkable) { platform in
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
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(platform.title) {
                HStack(spacing: 8) {
                    chooser
                    Spacer(minLength: 0)
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            } else if let mismatch {
                Text(mismatch).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Said when the folder is not called what Finder calls it.
    ///
    /// Nothing is wrong: a link works whatever the folder underneath is named.
    /// But a folder that already has Finder's name works whether it is linked
    /// or simply sitting where Finder looks, and a drive full of them reads as
    /// what it is. Worth saying once, quietly, rather than never.
    private var mismatch: String? {
        guard let folder = settings.folder(for: platform),
              let wanted = StandardLocation.folderName(for: platform),
              folder.lastPathComponent != wanted
        else { return nil }
        return String(format: String(localized: "Finder calls this folder %@."), wanted)
    }

    /// One pop-up naming the folder, rather than a truncated path and a row of
    /// buttons beside it — which is how the system offers a place to put
    /// something everywhere else.
    ///
    /// Known defect: whichever platform is last in this section draws its
    /// pop-up bordered and sits outside the section's background, while every
    /// row above it is plain and inside it. It followed the iPod when the iPod
    /// was last and follows the Mac now, so it is the position and not the
    /// platform. The section beneath, built the same way, does not do it.
    /// Pulling the menu out here, giving the section a header and a footer,
    /// dropping `fixedSize`, and matching the neighbouring row's shape all left
    /// it unchanged; the trigger is still unidentified.
    @ViewBuilder private var chooser: some View {
        Menu {
            Button("Choose…") { choose() }
            // Named rather than "New…", so the one name that matters is on
            // screen before the panel opens rather than only inside it.
            Button(newFolderName) { create() }
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
    }

    /// What the menu item says it will make.
    private var newFolderName: String {
        String(format: String(localized: "New \u{201C}%@\u{201D}…"), suggestedName)
    }

    /// Finder's own name where there is one, and the same shape of name where
    /// there is not, so a drive laid out by hand reads consistently.
    private var suggestedName: String {
        StandardLocation.folderName(for: platform)
            ?? String(format: String(localized: "%@ Software Updates"), platform.title)
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
        panel.message = String(format: String(localized: "Where %1$@ restore images should be kept. Finder looks for a folder called \u{201C}%2$@\u{201D}, so one named that works whether it is linked or simply put where Finder looks."),
                               platform.title, suggestedName)
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
        // Finder's own name where there is one, and the same shape of name
        // where there is not, so a drive laid out by hand reads consistently.
        panel.nameFieldStringValue = suggestedName
        panel.nameFieldLabel = String(localized: "Folder:")
        panel.prompt = String(localized: "Create")
        panel.message = String(format: String(localized: "Create a folder for %1$@ restore images. %2$@ is the name Finder itself uses; keeping it means the folder works whether it is linked or simply put where Finder looks."),
                               platform.title, suggestedName)
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
                Text(settings.everyDevice
                     ? String(localized: "Every device in the latest release")
                     : settings.selectedDevices.isEmpty
                       ? String(localized: "None")
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
