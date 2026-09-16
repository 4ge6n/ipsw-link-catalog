import SwiftUI

/// The first thing the app says, and the same thing it will say again later.
struct TransparencyPanel: View {
    var firstRun = false
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(firstRun ? "Before you start" : "About this app")
                    .font(.title2.weight(.semibold))
                Text("This app fetches large files from Apple and writes to a drive you choose. Here is everything it does with the network and with your disk.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Transparency.mac) { point in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: point.symbol)
                                .font(.title3).foregroundStyle(.tint).frame(width: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(point.title).font(.callout.weight(.semibold))
                                Text(point.detail).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button(firstRun ? "Continue" : "Done") {
                    settings.sawDisclosure = true
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 560)
        .interactiveDismissDisabled(firstRun)
    }
}
