import AppKit
import Foundation
import Observation
import WebKit

/// Apple's own downloads page, read with your developer account rather than
/// through the catalog. It lists what Apple is offering right now — including
/// the builds that are not public yet — which no catalog can know sooner.
///
/// Signing in happens on Apple's own page, shown in a web view. This app never
/// sees the password: what it keeps afterwards is the session cookie Apple set,
/// the same one Safari would be holding.
@MainActor
@Observable
final class DeveloperPortal {
    static let shared = DeveloperPortal()

    /// Where the sign-in lands once Apple is satisfied.
    private static let landing = URL(string: "https://developer.apple.com/download/os/")!
    /// The private endpoint the page itself reads. Undocumented, and Apple may
    /// change it without saying so; a failure here is not a failure of the app.
    private static let listing = URL(string: "https://developer.apple.com/services-account/QH65B2/downloadws/listDownloads.action")!
    /// Apple sets this once a session exists.
    private static let sessionCookie = "myacinfo"

    private(set) var signedIn = false
    private(set) var busy = false
    private(set) var failure: String?
    /// What the portal last said, kept so the shape can be looked at when a
    /// field turns out not to be where it was expected.
    private(set) var lastResponse: URL?

    private var window: NSWindow?

    func refreshSignedIn() async {
        signedIn = await cookies().contains { $0.name == Self.sessionCookie }
    }

    /// Show Apple's sign-in page and wait for it to finish.
    func signIn() {
        guard window == nil else { window?.makeKeyAndOrderFront(nil); return }
        failure = nil
        let configuration = WKWebViewConfiguration()
        // The same cookie jar the fetch below uses, so signing in here is what
        // signs in there.
        configuration.websiteDataStore = .default()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 720), configuration: configuration)
        let watcher = Watcher { [weak self] in
            Task { @MainActor in
                await self?.refreshSignedIn()
                if self?.signedIn == true { self?.closeWindow() }
            }
        }
        web.navigationDelegate = watcher
        objc_setAssociatedObject(web, &Watcher.key, watcher, .OBJC_ASSOCIATION_RETAIN)
        web.load(URLRequest(url: Self.landing))

        let panel = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
        panel.title = String(localized: "Sign in to Apple Developer")
        panel.contentView = web
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = panel
    }

    /// Forget the session. Apple's own cookies go with it.
    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let types: Set<String> = [WKWebsiteDataTypeCookies]
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.domain.contains("apple.com") {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
        signedIn = false
    }

    private func closeWindow() {
        window?.close()
        window = nil
    }

    /// What Apple is offering this account, as Apple's own page reads it.
    func downloads() async throws -> [PortalDownload] {
        busy = true
        defer { busy = false }
        let session = URLSession(configuration: await sessionConfiguration())
        var request = URLRequest(url: Self.listing)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://developer.apple.com/download/os/", forHTTPHeaderField: "Referer")
        request.httpBody = Data()
        request.timeoutInterval = 30
        let (data, _) = try await session.data(for: request)
        // Kept before it is read, so a shape that is not what was expected can
        // be looked at rather than guessed at twice.
        let saved = URL.temporaryDirectory.appending(path: "ipsw-portal-listing.json")
        try? data.write(to: saved)
        lastResponse = saved
        return try PortalDownload.parse(data)
    }

    /// A session carrying the cookies the web view was given.
    private func sessionConfiguration() async -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        let jar = HTTPCookieStorage.shared
        for cookie in await cookies() { jar.setCookie(cookie) }
        configuration.httpCookieStorage = jar
        configuration.httpShouldSetCookies = true
        return configuration
    }

    func cookies() async -> [HTTPCookie] {
        await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            .filter { $0.domain.contains("apple.com") }
    }

    /// Watches for the page to come back to Apple's own site with a session.
    private final class Watcher: NSObject, WKNavigationDelegate {
        nonisolated(unsafe) static var key = 0
        let settled: () -> Void
        init(settled: @escaping () -> Void) { self.settled = settled }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { settled() }
    }
}
