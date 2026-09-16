import SwiftUI

@main
struct IPSWBrowserApp: App {
    @State private var model = BrowserModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    model.refreshSaved()
                    await model.load()
                }
        }
    }
}

private struct RootView: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        TabView {
            Tab("Catalog", systemImage: "square.stack.3d.up") {
                BrowseView()
            }
            Tab("Saved", systemImage: "internaldrive") {
                LibraryView()
            }
        }
        // The bar steps out of the way while a long list of builds is read.
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
