import SwiftUI
import UIKit

@main
struct IPSWBrowserApp: App {
    @State private var model = BrowserModel()
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
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
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
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
    @Environment(BrowserModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            Tab("Catalog", systemImage: "square.stack.3d.up") {
                BrowseView()
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
        // Said before anything is fetched, rather than when someone asks.
        .sheet(isPresented: Binding(
            get: { !UserDefaults.standard.bool(forKey: "sawDisclosure") },
            set: { _ in }
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
