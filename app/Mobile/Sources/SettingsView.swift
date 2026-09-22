import SwiftUI

/// Everything about the app rather than about the catalog: what it tells you,
/// what it is holding, and what it does.
struct SettingsView: View {
    @Environment(BrowserModel.self) private var model
    @Bindable private var notifications = Notifications.shared
    @State private var showingTransparency = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Tell me about new builds", isOn: $notifications.on)
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("A notification arrives within minutes of Apple publishing, rather than when the app is next opened.")
                }

                if notifications.on {
                    Section("Platforms") {
                        ForEach(Platform.allCases) { platform in
                            Toggle(platform.title, isOn: binding(for: platform))
                        }
                    }
                    Section {
                        Toggle(String(format: String(localized: "Tell me when this %@ loses its signing window"),
                                      ThisDevice.current.kindName),
                               isOn: $notifications.watchThisDevice)
                        Text(String(format: String(localized: "Apple stops signing a build without saying so. Only %@ is sent."),
                                    ThisDevice.current.identifier))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Toggle("Beta and RC", isOn: $notifications.betas)
                    } footer: {
                        Text("Betas arrive far more often than releases do.")
                    }
                }

                if let failure = notifications.failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }

                Section {
                    LabeledContent("Saved images", value: "\(model.saved.count)")
                    if let free = Library.freeSpace {
                        LabeledContent("Free space", value: free.formatted(.byteCount(style: .file)))
                    }
                    LabeledContent("Held", value: held.formatted(.byteCount(style: .file)))
                } header: {
                    Text("Storage")
                }

                Section {
                    Button("About this app") { showingTransparency = true }
                    LabeledContent("Version", value: version)
                } footer: {
                    Text("What this app connects to, sends and writes — the same note it showed when it was first opened.")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingTransparency) { TransparencyView() }
        }
    }

    private var held: Int64 { model.saved.reduce(0) { $0 + $1.size } }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// Nothing chosen means everything, which is what a person who has just
    /// turned this on almost certainly means.
    private func binding(for platform: Platform) -> Binding<Bool> {
        Binding(
            get: { notifications.platforms.isEmpty || notifications.platforms.contains(platform.rawValue) },
            set: { wanted in
                var chosen = notifications.platforms.isEmpty
                    ? Set(Platform.allCases.map(\.rawValue))
                    : notifications.platforms
                if wanted { chosen.insert(platform.rawValue) } else { chosen.remove(platform.rawValue) }
                notifications.platforms = chosen.count == Platform.allCases.count ? [] : chosen
            }
        )
    }
}
