import Foundation

/// What the app does, said plainly and in one place. Shown once when the app is
/// first opened and kept somewhere it can be read again, because an app that
/// reaches the network and writes to a drive should say so before it does
/// either rather than when asked.
///
/// Every line here is a claim about the code in this repository. If the code
/// changes, this changes with it.
enum Transparency {
    struct Point: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    /// Where the catalog is read from, in both apps.
    static let catalogHost = "raw.githubusercontent.com"
    /// Where restore images come from. The catalog refuses to publish a link on
    /// any other host, so nothing else is ever fetched.
    static let imageHosts = ["updates.cdn-apple.com", "secure-appldnld.apple.com", "appldnld.apple.com"]
    /// Only the iPhone and iPad app, and only while notifications are on.
    static let relayHost = "ipsw-link-catalog-feed-relay.shigelon.workers.dev"

    static var mac: [Point] {
        [
            Point(symbol: "network",
                  title: String(localized: "What it connects to"),
                  detail: String(format: String(localized: "The catalog at %1$@, Apple's own servers for the images themselves (%2$@), and GitHub to see whether a newer copy of this app exists."),
                                 catalogHost, imageHosts.joined(separator: ", "))),
            Point(symbol: "person.badge.key",
                  title: String(localized: "Your Apple Developer account, if you sign in"),
                  detail: String(localized: "Signing in is optional and happens on Apple's own page, shown in a window. This app never sees your password. What it keeps afterwards is the session cookie Apple sets — the same one Safari would hold — used only to read Apple's downloads page and to fetch from it.")),
            Point(symbol: "hand.raised",
                  title: String(localized: "What it sends about you"),
                  detail: String(localized: "Nothing, to anyone but Apple. There is no account of ours, no identifier, and no analytics or telemetry of any kind in this app.")),
            Point(symbol: "internaldrive",
                  title: String(localized: "What it writes"),
                  detail: String(localized: "Restore images into the folders you choose, and beside them a small file recording which ones have already been checked against Apple's SHA-1, so a daily run need not read every byte again.")),
            Point(symbol: "link",
                  title: String(localized: "What it changes outside its own folders"),
                  detail: String(localized: "Only if you ask: the folder Finder restores from, in ~/Library/iTunes, can be replaced with a link to yours. Nothing else on the disk is touched.")),
            Point(symbol: "trash",
                  title: String(localized: "What it deletes"),
                  detail: String(localized: "Only a build that a newer one has replaced, and only while that switch is on. A build you fetched by hand is never pruned.")),
        ]
    }

    static var phone: [Point] {
        [
            Point(symbol: "network",
                  title: String(localized: "What it connects to"),
                  detail: String(format: String(localized: "The catalog at %1$@, and Apple's own servers for the images themselves (%2$@)."),
                                 catalogHost, imageHosts.joined(separator: ", "))),
            Point(symbol: "bell",
                  title: String(localized: "What it sends, and only if you turn notifications on"),
                  detail: String(format: String(localized: "This phone's notification address from Apple, which platforms you chose, and whether you want betas — to %@ and nowhere else. Turn notifications off and it is deleted."), relayHost)),
            Point(symbol: "hand.raised",
                  title: String(localized: "What it never sends"),
                  detail: String(localized: "There is no account, no advertising identifier, and no analytics or telemetry of any kind in this app. What you look at is not reported anywhere.")),
            Point(symbol: "internaldrive",
                  title: String(localized: "What it writes"),
                  detail: String(localized: "Images you save go in this app's own folder, which the Files app shows. Deleting the app deletes them. Nothing is written anywhere else on the phone.")),
            Point(symbol: "checkmark.seal",
                  title: String(localized: "What it checks"),
                  detail: String(localized: "Every image is read back against Apple's SHA-1 before it is called saved. One that does not match is discarded rather than kept.")),
        ]
    }
}
