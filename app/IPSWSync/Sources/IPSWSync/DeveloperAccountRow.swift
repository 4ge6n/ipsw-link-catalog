import SwiftUI

/// What the app watches for new builds, how closely, and the account that is
/// needed for the one part of it that cannot work without one.
struct DeveloperAccountRow: View {
    @Environment(SyncController.self) private var controller
    @Bindable private var portal = DeveloperPortal.shared
    @Bindable private var settings = Settings.shared
    @State private var problem: String?

    private var watch: ReleaseWatch { controller.watch }

    var body: some View {
        Toggle("Tell me when Apple posts a build", isOn: $settings.portalWatch)
            .onChange(of: settings.portalWatch) { watch.reschedule() }
        if settings.portalWatch {
            Picker("Look every", selection: $settings.portalMinutes) {
                Text("Minute").tag(1)
                Text("5 minutes").tag(5)
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("Hour").tag(60)
                Text("6 hours").tag(360)
            }
            .onChange(of: settings.portalMinutes) { watch.reschedule() }
        }
        Toggle("Include beta and RC builds", isOn: $settings.portalIncludesBetas)
        Toggle("Download what appears", isOn: $settings.portalFeedsSync)
        Toggle("Fill in missing checksums from ipsw.me", isOn: $settings.useChecksumFallback)

        // The account, which only the beta builds need. Everything else here
        // works without one.
        LabeledContent("Apple Developer") {
            HStack {
                if portal.signedIn {
                    Label("Signed in", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                    Spacer(minLength: 8)
                    Button("Sign Out") { Task { await portal.signOut(); problem = nil } }
                } else {
                    Button("Sign In…") { portal.signIn() }
                    Text("Needed only for beta and RC builds.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .task { await portal.refreshSignedIn() }

        LabeledContent {
            Button("Check Now") { look() }.disabled(portal.busy || watch.looking)
        } label: {
            summary
        }

        if let problem = problem ?? watch.failure {
            VStack(alignment: .leading, spacing: 4) {
                Text(problem).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if let kept = portal.lastResponse {
                    Button("Show the Reply") { NSWorkspace.shared.activateFileViewerSelecting([kept]) }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    @ViewBuilder private var summary: some View {
        let found = watch.builds
        VStack(alignment: .leading, spacing: 2) {
            if found.isEmpty {
                Text("Nothing read yet.")
            } else {
                Text(String(format: String(localized: "%1$lld build(s) and %2$lld restore image(s), %3$lld of them pre-release."),
                            found.count, found.reduce(0) { $0 + $1.firmwares.count },
                            found.filter(\.isBeta).count))
                if let newest = found.first {
                    Text(String(format: String(localized: "Newest: %1$@ (%2$@)"), newest.title, newest.build))
                }
            }
            if let looked = watch.lastLooked {
                Text(String(format: String(localized: "Looked %@"), looked.formatted(date: .omitted, time: .shortened)))
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func look() {
        Task {
            problem = nil
            // Announcing from a look asked for by hand would be a notification
            // about what is already on the screen.
            await watch.look(announce: false, force: true)
            problem = watch.failure
        }
    }
}
