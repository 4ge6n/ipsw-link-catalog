import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct IPSWSyncApp: App {
    @State private var controller = SyncController()
    @Bindable private var settings = Settings.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("IPSW Sync", id: "main") {
            ContentView()
                .environment(controller)
                .task {
                    // Ask once, so the daily result can be reported without the
                    // window being open.
                    _ = try? await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert])
                    controller.scheduleNext(catchUpIfMissed: true)
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Sync Now") { Task { await controller.run() } }
                    .keyboardShortcut("r")
            }
        }

        MenuBarExtra("IPSW Sync", systemImage: "arrow.down.circle", isInserted: $settings.showInMenuBar) {
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.shared.applyPresentation()
        // Started hidden — at login, say — so it should not put a window up.
        if Settings.shared.isHidden, !wasOpenedByHand {
            DispatchQueue.main.async { NSApp.windows.forEach { $0.close() } }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the window leaves the schedule running behind it.
        false
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
