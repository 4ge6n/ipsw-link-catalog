import SwiftUI

/// What the phone should be woken for.
struct NotificationsView: View {
    @Bindable private var notifications = Notifications.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Tell me about new builds", isOn: $notifications.on)
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
            }
            .navigationTitle("Notifications")
        }
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
