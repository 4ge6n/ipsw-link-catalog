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
    /// The page itself. It is rendered on the server, so what comes back is
    /// what Apple shows rather than a feed behind it.
    private static let listing = landing
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

    /// What Apple is offering this account, read from Apple's own page.
    func downloads(resolvingWith engine: SyncEngine) async throws -> [PortalCatalog.Entry] {
        busy = true
        defer { busy = false }
        let session = URLSession(configuration: await sessionConfiguration())
        var request = URLRequest(url: Self.listing)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        // Signed out, Apple answers the sign-in page rather than an error.
        if let http = response as? HTTPURLResponse,
           http.url?.host()?.contains("idmsa.apple.com") == true {
            signedIn = false
            throw PortalError.signedOut
        }
        guard let page = String(data: data, encoding: .utf8) else { throw PortalError.unreadable }
        // Kept before it is read, so a page that is not what was expected can be
        // looked at rather than guessed at twice.
        let saved = URL.temporaryDirectory.appending(path: "ipsw-portal-page.html")
        try? data.write(to: saved)
        lastResponse = saved
        // Apple names some images after the model and gives their identifiers
        // nowhere on the page. What each covered before is what it covers now.
        var index = DeviceIndex()
        for platform in Platform.allCases {
            if let known = try? await engine.deviceIndex(platform) { index.formUnion(known) }
        }
        let entries = PortalCatalog.parse(page, identifiers: index)
        guard !entries.isEmpty else { throw PortalError.nothingRecognised }
        return entries
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
