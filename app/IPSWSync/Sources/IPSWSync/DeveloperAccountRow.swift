import SwiftUI

/// Signing in to Apple, and what that is for.
struct DeveloperAccountRow: View {
    @Environment(SyncController.self) private var controller
    @Bindable private var portal = DeveloperPortal.shared
    @State private var found: [PortalCatalog.Entry] = []
    @State private var problem: String?

    var body: some View {
        LabeledContent("Apple Developer") {
            HStack {
                if portal.signedIn {
                    Label("Signed in", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                    Spacer(minLength: 8)
                    Button("Check Now") { look() }.disabled(portal.busy)
                    Button("Sign Out") { Task { await portal.signOut(); found = []; problem = nil } }
                } else {
                    Button("Sign In…") { portal.signIn() }
                    Spacer(minLength: 0)
                }
            }
        }
        .task { await portal.refreshSignedIn() }

        if portal.signedIn, !found.isEmpty {
            Text(String(format: String(localized: "%1$lld build(s) and %2$lld restore image(s), %3$lld of them pre-release."),
                        found.count, found.reduce(0) { $0 + $1.firmwares.count },
                        found.filter(\.isBeta).count))
                .font(.caption).foregroundStyle(.secondary)
        }
        if let problem {
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

    private func look() {
        Task {
            problem = nil
            do { found = try await controller.portalDownloads() }
            catch { found = []; problem = error.localizedDescription }
        }
    }
}
