import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct IPSWSyncApp: App {
    @State private var controller = SyncController()
    @Bindable private var settings = Settings.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private func goSilent() {
        settings.goSilent()
        NSApp.windows.forEach { $0.close() }
    }

    var body: some Scene {
        Window("IPSW Sync", id: "main") {
            ContentView()
                .environment(controller)
                .task {
                    // Each of these can wait on something outside the app — the
                    // notification service, the network — so none of them is
                    // allowed to hold up the ones after it.
                    Task.detached {
                        _ = try? await UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert])
                    }
                    controller.scheduleNext(catchUpIfMissed: true)
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
                Button("Go Silent") { goSilent() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .disabled(settings.isHidden)
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
    }
}

private struct MenuBarContent: View {
    @Environment(SyncController.self) private var controller
    @Environment(\.openWindow) private var openWindow
    @Bindable private var settings = Settings.shared

    var body: some View {
        if controller.running {
            Text("Syncing…")
            Button("Stop") { controller.cancel() }
        } else {
            Text(settings.lastRun.map { "Last run \($0.formatted(date: .abbreviated, time: .shortened))" }
                 ?? "Not run yet")
            Button("Sync Now") { Task { await controller.run() } }
        }
        if let next = controller.nextRun {
            Text("Next \(next.formatted(date: .abbreviated, time: .shortened))")
        }
        Divider()
        Button("Go Silent") { Settings.shared.goSilent(); NSApp.windows.forEach { $0.close() } }
        Button("Settings…") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Toggle("Open at Login", isOn: Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { wanted in
                // A daily run needs the app to be there when the day comes.
                try? wanted ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            }
        ))
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
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
        let sync = NSMenuItem(title: "Sync Now", action: #selector(syncNow), keyEquivalent: "")
        sync.target = self
        menu.addItem(sync)
        if !Settings.shared.isHidden {
            let silent = NSMenuItem(title: "Go Silent", action: #selector(goSilentFromDock), keyEquivalent: "")
            silent.target = self
            menu.addItem(silent)
        }
        return menu
    }

    @objc private func syncNow() { NotificationCenter.default.post(name: .ipswSyncNow, object: nil) }

    @objc private func goSilentFromDock() {
        Settings.shared.goSilent()
        NSApp.windows.forEach { $0.close() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.shared.applyPresentation()
        sizeFirstWindow()
        // Started hidden — at login, say — so it should not put a window up.
        if Settings.shared.isHidden, !wasOpenedByHand {
            DispatchQueue.main.async { NSApp.windows.forEach { $0.close() } }
        }
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
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
        // Put the Dock icon back the way the setting asks once the window is up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Settings.shared.applyPresentation() }
    }
}
