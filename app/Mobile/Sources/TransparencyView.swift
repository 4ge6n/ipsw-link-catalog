import SwiftUI

/// The first thing the app says, and the same thing it will say again later.
struct TransparencyView: View {
    /// Shown as a sheet the first time, and as a screen after that.
    var firstRun = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Before you start")
                            .font(.title2.weight(.semibold))
                        Text("This app fetches large files from Apple and can be told to notify you. Here is everything it does with the network and with this phone.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .listRowSeparator(.hidden)
                }

                ForEach(Transparency.phone) { point in
                    Section {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: point.symbol)
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(point.title).font(.callout.weight(.semibold))
                                Text(point.detail).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle(firstRun ? "" : "About this app")
            .navigationBarTitleDisplayMode(firstRun ? .inline : .large)
            .toolbar {
                if firstRun {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Continue") {
                            UserDefaults.standard.set(true, forKey: "sawDisclosure")
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                    }
                }
            }
            .interactiveDismissDisabled(firstRun)
        }
    }
}
