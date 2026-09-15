import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct IPSWSyncApp: App {
    @State private var controller = SyncController()
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

        MenuBarExtra("IPSW Sync", systemImage: "arrow.down.circle") {
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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the window leaves the schedule running in the menu bar.
        false
    }
}
