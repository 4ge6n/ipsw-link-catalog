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

                // Somewhere for a transfer to say what happened to it. Without
                // this the app had opinions it never expressed.
                if !model.log.isEmpty {
                    Section("Activity") {
                        ForEach(model.log.reversed().prefix(40)) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: symbol(entry.kind))
                                    .foregroundStyle(colour(entry.kind))
                                    .font(.caption)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.message).font(.caption)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(entry.at.formatted(date: .omitted, time: .standard))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
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

    private func symbol(_ kind: LogEntry.Kind) -> String {
        switch kind {
        case .info: "info.circle"
        case .good: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .bad: "xmark.octagon"
        }
    }

    private func colour(_ kind: LogEntry.Kind) -> Color {
        switch kind {
        case .info: .secondary
        case .good: .green
        case .warning: .orange
        case .bad: .red
        }
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets {
            try? Library.remove(model.saved[index])
        }
        model.refreshSaved()
    }
}
