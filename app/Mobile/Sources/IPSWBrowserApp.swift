import SwiftUI
import UIKit

@main
struct IPSWBrowserApp: App {
    @State private var model = BrowserModel()
    @State private var feed = ReleaseFeed()
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(feed)
                .task {
                    Notifications.shared.start()
                    model.listen()
                    model.refreshSaved()
                    await model.load()
                }
        }
    }
}

/// The system starts the app again in the background when a transfer it was
/// carrying finishes, and this is where it says so.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        DiagnosticJournal.shared.record("info", area: "app", event: "launch",
                                        "IPSW Browser \(version) (\(build)); iOS \(ProcessInfo.processInfo.operatingSystemVersionString); device=\(ThisDevice.current.identifier)")
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DiagnosticJournal.shared.record("info", area: "background", event: "wake",
                                        "Background URLSession events delivered")
        BackgroundDownloads.shared.whenWokenFinished = completionHandler
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in Notifications.shared.accept(deviceToken) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in Notifications.shared.reject(error) }
    }
}

private struct RootView: View {
    /// Observed rather than read: a plain UserDefaults write notifies nobody.
    @AppStorage("sawDisclosure") private var sawDisclosure = false
    @Environment(BrowserModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            // The device in hand and the ones starred, then what came out
            // when, then every device — the order IPSW Go uses, which is the
            // order the questions come in. The version tree is still a button
            // away on the Devices tab.
            Tab("My Devices", systemImage: "iphone") {
                MyDevicesView()
            }
            Tab("Latest Releases", systemImage: "sparkles") {
                ReleasesView()
            }
            Tab("Devices", systemImage: "laptopcomputer.and.iphone") {
                DevicesView()
            }
            Tab("Saved", systemImage: "internaldrive") {
                LibraryView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
        // The bar steps out of the way while a long list of builds is read.
        .tabBarMinimizeBehavior(.onScrollDown)
        // Above the tab bar on every tab, because a transfer belongs to the
        // app rather than to the screen it was started from.
        .safeAreaInset(edge: .bottom) { ActivityBar() }
        // Said before anything is fetched, rather than when someone asks.
        // Read through AppStorage rather than straight out of UserDefaults:
        // writing a default notifies nobody, so the sheet stayed up after
        // Continue was pressed and the app could not be reached at all.
        .sheet(isPresented: Binding(
            get: { !sawDisclosure },
            set: { if !$0 { sawDisclosure = true } }
        )) {
            TransparencyView(firstRun: true)
        }
        .alert("Not enough room", isPresented: Binding(
            get: { model.noRoom != nil },
            set: { if !$0 { model.noRoom = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.noRoom ?? "")
        }
    }
}
