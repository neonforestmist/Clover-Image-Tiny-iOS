import SwiftUI

struct AppShell: View {
    enum Tab: Hashable {
        case create
        case library
    }

    let library: ArtworkLibrary
    let generator: any ImageGenerating
    let modelManager: ModelManager

    @State private var selectedTab: Tab = .create

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                CreateView(
                    generator: generator,
                    library: library,
                    modelManager: modelManager
                )
            }
            .tabItem {
                Label("Create", systemImage: "wand.and.stars")
            }
            .tag(Tab.create)

            NavigationStack {
                LibraryView(library: library)
            }
            .tabItem {
                Label("Library", systemImage: "square.grid.2x2")
            }
            .tag(Tab.library)
        }
        .tint(.cloverGreen)
        .onChange(of: selectedTab) {
            HapticManager.selection()
        }
    }
}

#Preview {
    AppShell(
        library: ArtworkLibrary.preview,
        generator: PreviewGenerationService(),
        modelManager: ModelManager(previewInstalled: true)
    )
}
