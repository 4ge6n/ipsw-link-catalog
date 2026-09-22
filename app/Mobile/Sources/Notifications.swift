import Foundation
import Observation
import UIKit
import UserNotifications

/// Being told when a build turns up, rather than going to look. The relay keeps
/// the address of this phone and what it asked to hear about; Apple carries the
/// message the moment the catalog changes.
@MainActor
@Observable
final class Notifications: NSObject {
    static let shared = Notifications()

    private override init() {
        let defaults = UserDefaults.standard
        on = defaults.bool(forKey: "notificationsOn")
        platforms = Set(defaults.stringArray(forKey: "notifyPlatforms") ?? [])
        betas = defaults.bool(forKey: "notifyBetas")
        watchThisDevice = defaults.object(forKey: "watchThisDevice") as? Bool ?? true
        super.init()
    }

    private let relay = URL(string: "https://ipsw-link-catalog-feed-relay.shigelon.workers.dev")!
    private let defaults = UserDefaults.standard

    /// Whether this phone is registered. Nothing is sent until it is asked for.
    private(set) var authorised = false
    private(set) var token: String?
    private(set) var failure: String?

    /// These are stored and then written through, rather than read straight
    /// out of UserDefaults on each access. Observation tracks stored
    /// properties; a computed one reading defaults is invisible to it, so the
    /// switch moved under the finger and sprang back — the setting did change,
    /// and nothing on screen ever said so.
    var on: Bool {
        didSet {
            guard on != oldValue else { return }
            defaults.set(on, forKey: "notificationsOn")
            Task { await apply() }
        }
    }

    /// Which platforms are worth waking the phone for. Empty means all of them.
    var platforms: Set<String> {
        didSet {
            guard platforms != oldValue else { return }
            defaults.set(Array(platforms).sorted(), forKey: "notifyPlatforms")
            Task { await send() }
        }
    }

    var betas: Bool {
        didSet {
            guard betas != oldValue else { return }
            defaults.set(betas, forKey: "notifyBetas")
            Task { await send() }
        }
    }

    /// Whether to be told when this very device loses a signing window.
    ///
    /// Apple stops signing a build without announcing it, and the catalog
    /// cannot say so afterwards: the build simply leaves the list of what can
    /// be restored, and by then it is too late to have wanted it. The only
    /// thing sent is what this device is — iPhone18,4 — and only while this
    /// is on.
    var watchThisDevice: Bool {
        didSet {
            guard watchThisDevice != oldValue else { return }
            defaults.set(watchThisDevice, forKey: "watchThisDevice")
            Task { await send() }
        }
    }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshAuthorisation() }
        if on { Task { await apply() } }
    }

    private func refreshAuthorisation() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorised = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    /// Ask, then register with Apple. The token arrives at the delegate below.
    private func apply() async {
        guard on else {
            if let token { await forget(token) }
            return
        }
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            authorised = granted
            guard granted else { failure = String(localized: "Notifications are turned off for IPSW Browser in Settings."); return }
            failure = nil
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            failure = error.localizedDescription
        }
    }

    func accept(_ deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await send() }
    }

    func reject(_ error: Error) { failure = error.localizedDescription }

    /// Tell the relay where to reach this phone and what it wants.
    private func send() async {
        guard on, let token else { return }
        var request = URLRequest(url: relay.appending(path: "device-tokens"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": token,
            // A build signed for development talks to Apple's sandbox; one from
            // the App Store does not, and they are different hosts.
            "sandbox": Self.isDevelopmentBuild,
            "platforms": Array(platforms).sorted(),
            "betas": betas,
            "watching": watchThisDevice ? ThisDevice.current.identifier : "",
            "bundle": Bundle.main.bundleIdentifier ?? "",
        ])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                failure = String(format: String(localized: "The notification service answered %lld."), http.statusCode)
            } else {
                failure = nil
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func forget(_ token: String) async {
        var request = URLRequest(url: relay.appending(path: "device-tokens"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Which APNs host will be able to reach this copy.
    static var isDevelopmentBuild: Bool {
        #if DEBUG
        return true
        #else
        // A build signed for development carries its profile inside the bundle;
        // one from the App Store does not.
        return Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil
        #endif
    }
}

extension Notifications: UNUserNotificationCenterDelegate {
    /// Shown even while the app is open: the point is to hear about it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
