import AppKit
import SwiftUI

/// Offers to point Finder's restore folder at the folder the images live in.
struct StandardLocationRow: View {
    let platform: Platform
    @Bindable var settings: Settings
    @State private var state: StandardLocation.State = .missing
    @State private var problem: String?
    @State private var confirmingMove = false

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
        .onChange(of: settings.folder(for: platform)) { refresh() }
        .alert("Move what is already there?", isPresented: $confirmingMove) {
            Button("Move and Link") { moveThenLink() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files in \(StandardLocation.folderName(for: platform)) will be moved into the folder you chose, then Finder will be pointed at it.")
        }
        if let problem {
            Text(problem).font(.caption).foregroundStyle(.orange)
        }
    }

    private var chosen: URL? { settings.folder(for: platform) }

    private var description: String {
        switch state {
        case .missing, .emptyFolder: "Not linked"
        case .folder(let count): "Holds \(count) file(s) of its own"
        case .linked(let destination):
            destination == chosen ? "Linked to your folder" : "Linked to \(destination.path(percentEncoded: false))"
        case .somethingElse(let why): why
        }
    }

    @ViewBuilder private var action: some View {
        switch state {
        case .linked:
            Button("Unlink") { run { try StandardLocation.unlink(platform) } }
        case .folder:
            Button("Move and Link…") { confirmingMove = true }.disabled(chosen == nil)
        case .missing, .emptyFolder:
            Button("Link") { run { try StandardLocation.link(platform, to: chosen!) } }
                .disabled(chosen == nil)
        case .somethingElse:
            EmptyView()
        }
    }

    private func moveThenLink() {
        run { try StandardLocation.moveContentsThenLink(platform, to: chosen!) }
    }

    private func run(_ work: () throws -> Void) {
        problem = nil
        do { try work() } catch { problem = error.localizedDescription }
        refresh()
    }

    private func refresh() { state = StandardLocation.state(for: platform) }
}
