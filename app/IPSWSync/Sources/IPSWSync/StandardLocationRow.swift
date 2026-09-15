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
                Text(description).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                action
            }
        }
        .task { refresh() }
        .onChange(of: settings.folderMark) { refresh() }
        .alert("Move what is already there?", isPresented: $confirmingMove) {
            Button("Move and Link") { moveThenLink() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files in \(StandardLocation.folderName(for: platform)) will be moved into \(destination?.path(percentEncoded: false) ?? "the folder you chose"), then Finder will be pointed at it.")
        }
        if let problem {
            Text(problem).font(.caption).foregroundStyle(.orange)
        }
    }

    private var chosen: URL? { settings.folder(for: platform) }
    private var destination: URL? { target ?? chosen }

    private var description: String {
        switch state {
        case .missing, .emptyFolder: "Not linked"
        case .folder(let count): "Holds \(count) file(s) of its own"
        case .linked(let where_):
            where_ == chosen ? "Linked to your folder" : "Linked to \(where_.path(percentEncoded: false))"
        case .somethingElse(let why): why
        }
    }

    @ViewBuilder private var action: some View {
        switch state {
        case .linked:
            Button("Unlink") { run { try StandardLocation.unlink(platform) } }
        case .folder:
            Button("Move and Link…") { target = chosen; confirmingMove = true }.disabled(chosen == nil)
            Button("Link to…") { linkElsewhere() }
        case .missing, .emptyFolder:
            Button("Link") { target = chosen; run { try StandardLocation.link(platform, to: chosen!) } }
                .disabled(chosen == nil)
            Button("Link to…") { linkElsewhere() }
        case .somethingElse:
            EmptyView()
        }
    }

    /// Point Finder somewhere of its own. The folder the app syncs into is the
    /// usual answer, but it is not the only one worth linking to.
    private func linkElsewhere() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Link Here"
        panel.message = "Where Finder should look for \(platform.title) restore images"
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
