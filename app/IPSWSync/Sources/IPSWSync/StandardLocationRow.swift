import AppKit
import SwiftUI

/// Offers to point Finder's restore folder at the folder the images live in.
struct StandardLocationRow: View {
    let platform: Platform
    @Bindable var settings: Settings
    @State private var state: StandardLocation.State = .missing
    @State private var problem: String?
    @State private var confirmingMove = false
    /// Where the link should point. Normally the folder chosen above, but
    /// "Link to…" picks one without disturbing that setting.
    @State private var target: URL?

    var body: some View {
        LabeledContent(platform.title) {
            HStack(spacing: 8) {
                action
                // Left of the value column, so the three rows line up rather
                // than each sitting wherever its own text ends.
                Spacer(minLength: 0)
            }
        }
        .task { refresh() }
        .onChange(of: settings.folderMark) { refresh() }
        .alert("Move what is already there?", isPresented: $confirmingMove) {
            Button("Move and Link") { moveThenLink() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(String(format: String(localized: "The files in %1$@ will be moved into %2$@, then Finder will be pointed at it."),
                        StandardLocation.folderName(for: platform),
                        destination?.path(percentEncoded: false) ?? String(localized: "the folder you chose")))
        }
        if let problem {
            Text(problem).font(.caption).foregroundStyle(.orange)
        }
    }

    private var chosen: URL? { settings.folder(for: platform) }
    private var destination: URL? { target ?? chosen }

    private var description: String {
        switch state {
        case .missing, .emptyFolder: String(localized: "Not linked")
        case .folder(let count):
            String(format: String(localized: "Holds %lld file(s) of its own"), count)
        case .linked(let where_):
            where_ == chosen
            ? String(localized: "Linked to your folder")
            : String(format: String(localized: "Linked to %@"), where_.lastPathComponent)
        case .somethingElse(let why): why
        }
    }

    /// One pop-up rather than a pair of buttons on each of three rows. What can
    /// be done depends on what is there, so the menu says, and the row stays a
    /// row about where Finder is pointed.
    @ViewBuilder private var action: some View {
        switch state {
        case .somethingElse:
            EmptyView()
        default:
            Menu {
                switch state {
                case .linked:
                    Button("Unlink") { run { try StandardLocation.unlink(platform) } }
                    Divider()
                    Button("Link to…") { linkElsewhere() }
                case .folder:
                    Button("Move and Link…") { target = chosen; confirmingMove = true }
                        .disabled(chosen == nil)
                    Button("Link to…") { linkElsewhere() }
                default:
                    Button("Link") { target = chosen; run { try StandardLocation.link(platform, to: chosen!) } }
                        .disabled(chosen == nil)
                    Button("Link to…") { linkElsewhere() }
                }
            } label: {
                Label(description, systemImage: symbol)
            }
            .menuStyle(.button)
            .fixedSize()
        }
    }

    private var symbol: String {
        switch state {
        case .linked: "link"
        case .folder: "folder.fill"
        case .somethingElse: "exclamationmark.triangle"
        default: "link.badge.plus"
        }
    }

    /// Point Finder somewhere of its own. The folder the app syncs into is the
    /// usual answer, but it is not the only one worth linking to.
    private func linkElsewhere() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Link Here")
        panel.message = String(format: String(localized: "Where Finder should look for %@ restore images"), platform.title)
        panel.directoryURL = chosen
        guard panel.runModal() == .OK, let url = panel.url else { return }
        target = url
        if case .folder = state {
            confirmingMove = true
        } else {
            run { try StandardLocation.link(platform, to: url) }
        }
    }

    private func moveThenLink() {
        guard let destination else { return }
        run { try StandardLocation.moveContentsThenLink(platform, to: destination) }
    }

    private func run(_ work: () throws -> Void) {
        problem = nil
        do { try work() } catch { problem = error.localizedDescription }
        refresh()
    }

    private func refresh() { state = StandardLocation.state(for: platform) }
}
