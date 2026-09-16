import SwiftUI

/// What has been fetched, where the Files app can reach it.
struct LibraryView: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.saved) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.subheadline).lineLimit(2)
                            Text("\(item.size.formatted(.byteCount(style: .file)))  ·  \(item.saved.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete(perform: delete)
                } footer: {
                    if let free = Library.freeSpace {
                        Text(String(format: String(localized: "%@ free on this device"),
                                    free.formatted(.byteCount(style: .file))))
                    }
                }
            }
            .navigationTitle("Saved")
            .overlay {
                if model.saved.isEmpty {
                    ContentUnavailableView(
                        "Nothing saved yet", systemImage: "internaldrive",
                        description: Text("Images you save appear here, and in the Files app under IPSW Browser."))
                }
            }
            .toolbar { EditButton() }
            .refreshable { model.refreshSaved() }
        }
        .onAppear { model.refreshSaved() }
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets {
            try? Library.remove(model.saved[index])
        }
        model.refreshSaved()
    }
}
