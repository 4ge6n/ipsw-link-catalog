import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct IPSWSyncApp: App {
    @State private var controller = SyncController()
    @Bindable private var settings = Settings.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("IPSW Sync", id: "main") {
            ContentView()
                .environment(controller)
                // Closing the window lets SwiftUI put it away, and the delegate
                // has no way to ask for it back. Handing the action over while
                // the window is up leaves one that still works once it is gone.
                .onAppear { delegate.showMainWindow = { openWindow(id: "main") } }
                .task {
                    // Each of these can wait on something outside the app — the
                    // notification service, the network — so none of them is
                    // allowed to hold up the ones after it.
                    Task.detached {
                        _ = try? await UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert])
                    }
                    controller.scheduleNext(catchUpIfMissed: true)
                    // Apple's page, watched from here on, so a build posted
                    // this afternoon is announced this afternoon.
                    controller.beginWatching()
                    // Left running for weeks, the app would otherwise only look
                    // for its own updates after a sync.
                    if Settings.shared.shouldCheckForUpdateAtLaunch() {
                        Task { await controller.updater.check(installAutomatically: true) }
                    }
                    Settings.shared.hasLaunchedBefore = true
                }
        }
        // The content's ideal size is not the window's opening size, and
        // without this it opened too short for its own settings.
        .defaultSize(width: 720, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Sync Now") { Task { await controller.run() } }
                    .keyboardShortcut("r")
            }
        }

        // SwiftUI reports the status item's own visibility back through this
        // binding, and after Go Silent it reports `true` — putting the item
        // straight back and overwriting the setting. Each write-back re-entered
        // the scene update that caused it, which on some Macs never settled and
        // spun the main thread until the app was killed. What the menu bar shows
        // is already the app's own decision, so the report is read, not obeyed.
        MenuBarExtra("IPSW Sync", systemImage: "arrow.down.circle",
                     isInserted: Binding(get: { settings.showInMenuBar }, set: { _ in })) {
            MenuBarContent().environment(controller)
        }
        // A panel rather than a list of menu items, so a run can show how far
        // along it is instead of only saying that it is going.
        .menuBarExtraStyle(.window)
    }
}

/// What is in the menu bar: how the run is going, the one thing worth doing
/// about it, and the settings that used to sit in the same list as everything
/// else tucked behind a menu of their own.
private struct MenuBarContent: View {
    @Environment(SyncController.self) private var controller
    @Environment(\.openWindow) private var openWindow
    @Bindable private var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if controller.running { progress }
            Divider()
            schedule
            Divider()
            actions
        }
        .padding(12)
        .frame(width: 280)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.running ? String(localized: "Syncing") : String(localized: "IPSW Sync"))
                    .font(.headline)
                Text(status)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if controller.running {
                Button("Stop") { controller.cancel() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            } else {
                Button("Sync Now") { Task { await controller.run() } }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
            }
        }
    }

    private var status: String {
        guard controller.running else {
            return settings.lastRun.map {
                String(format: String(localized: "Last run %@"), $0.formatted(date: .abbreviated, time: .shortened))
            } ?? String(localized: "Not run yet")
        }
        let state = controller.overall
        return String(format: String(localized: "%1$lld of %2$lld file(s)"), state.done, state.total)
    }

    /// Enough to see it moving without opening the window.
    ///
    /// Every transfer, not the first of them: three run at once by default, and
    /// showing one meant the menu bar reported a third of what was happening
    /// and stalled whenever that particular file was the one being hashed.
    @ViewBuilder private var progress: some View {
        let state = controller.overall
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: state.fraction)
            HStack {
                Text(String(format: String(localized: "%1$lld of %2$lld file(s)"), state.done, state.total))
                Spacer(minLength: 8)
                Text(volume).monospacedDigit()
            }
            .font(.caption2).foregroundStyle(.secondary)
            ForEach(running) { transfer in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(transfer.device).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(detail(of: transfer)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.caption2)
                    if transfer.state == .downloading {
                        ProgressView(value: transfer.fraction).controlSize(.small)
                    }
                }
            }
            if queued > 0 {
                Text(String(format: String(localized: "%lld more in the queue"), queued))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// What is moving right now — coming down, or being hashed.
    private var running: [Transfer] {
        controller.transfers.filter {
            $0.state == .downloading || $0.state == .verifying || $0.state == .checking
        }
    }

    private var queued: Int {
        controller.transfers.count { $0.state == .queued || $0.state == .waiting }
    }

    private func detail(of transfer: Transfer) -> String {
        switch transfer.state {
        case .downloading: "\(Int(transfer.fraction * 100))%"
        case .verifying: String(localized: "checking")
        default: "…"
        }
    }

    private var volume: String {
        let state = controller.overall
        guard state.expected > 0 else { return "\(Int(state.fraction * 100))%" }
        return "\(state.received.formatted(.byteCount(style: .file)))"
            + " / \(state.expected.formatted(.byteCount(style: .file)))"
    }

    @ViewBuilder private var schedule: some View {
        if let next = controller.nextRun {
            Label(String(format: String(localized: "Next %@"),
                         next.formatted(date: .abbreviated, time: .shortened)),
                  systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Label("No daily run", systemImage: "clock.badge.xmark")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            Button("Settings…") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            Spacer()
            // The switches belong to the app rather than to this moment, so they
            // are behind a menu instead of in the way of what is.
            Menu {
                Toggle("Show in the menu bar", isOn: $settings.showInMenuBar)
                Toggle("Open at Login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { wanted in
                        // A daily run needs the app to be there when the day comes.
                        try? wanted ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
                ))
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            } label: {
                Label("More", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .controlSize(.small)
            .fixedSize()
        }
    }
}

/// The Dock icon's menu, so a sync or a retreat into silence is one click away
/// without the window.
extension Notification.Name {
    static let ipswSyncNow = Notification.Name("ipswSyncNow")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let sync = NSMenuItem(title: String(localized: "Sync Now"), action: #selector(syncNow), keyEquivalent: "")
        sync.target = self
        menu.addItem(sync)
        // The Dock icon is here to be seen, so this switch is always on; turning
        // it off takes the icon away and nothing else.
        let dock = NSMenuItem(title: String(localized: "Show in the Dock"), action: #selector(hideDockIcon), keyEquivalent: "")
        dock.target = self
        dock.state = .on
        menu.addItem(dock)
        return menu
    }

    @objc private func syncNow() { NotificationCenter.default.post(name: .ipswSyncNow, object: nil) }

    @objc private func hideDockIcon() { Settings.shared.showInDock = false }

    /// Set while the window is up, so it can be asked for again after it closes.
    var showMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI puts its own object between the app and this one, and it keeps
        // the reopen event to itself — applicationShouldHandleReopen is never
        // called here, which is what left an invisible copy with no way back.
        // Asking for the event directly is what actually arrives.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleReopen(_:with:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEReopenApplication))
        sizeFirstWindow()
        if Settings.shared.isHidden, wasOpenedByHand {
            // Launched from the Finder with nothing on screen: that is someone
            // asking for it back.
            Settings.shared.comeBack()
        } else if Settings.shared.isHidden {
            // Started hidden at login, so it should not put a window up.
            DispatchQueue.main.async { NSApp.windows.forEach { $0.close() } }
        }
        Settings.shared.applyPresentation()
    }

    @objc private func handleReopen(_ event: NSAppleEventDescriptor, with reply: NSAppleEventDescriptor) {
        showSettings()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the window leaves the schedule running behind it.
        false
    }

    /// SwiftUI's defaultSize does not reach this window, which otherwise opens
    /// too short for its own settings. Only the first launch is sized; after
    /// that the window is wherever it was left.
    private func sizeFirstWindow() {
        guard UserDefaults.standard.object(forKey: "NSWindow Frame main") == nil else { return }
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
            var frame = window.frame
            let wanted = CGSize(width: 720, height: 780)
            let visible = window.screen?.visibleFrame ?? .zero
            frame.size = CGSize(width: wanted.width, height: min(wanted.height, visible.height))
            frame.origin.y = max(visible.minY, frame.maxY - frame.height)
            window.setFrame(frame, display: true)
        }
    }

    /// Opening the app again is how an invisible copy is brought back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    private var wasOpenedByHand: Bool {
        // A login item is launched by the service, not from the Finder.
        !(ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]?.contains("application") ?? false)
    }

    func showSettings() {
        // Both switches go back on, so the policy this asks for is .regular and
        // the window it puts up is not taken away again a moment later.
        Settings.shared.comeBack()
        Settings.shared.applyPresentation()
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            showMainWindow?()
        }
    }
}
