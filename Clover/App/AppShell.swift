import SwiftUI

struct AppShell: View {
    enum Tab: Hashable {
        case create
        case inpainting
        case library
    }

    let library: ArtworkLibrary
    let generator: any ImageGenerating
    let modelManager: ModelManager
    let inpaintingModelManager: InpaintingModelManager

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
                InpaintingView(
                    library: library,
                    modelManager: inpaintingModelManager,
                    styleManager: modelManager
                )
            }
            .tabItem {
                Label("Inpainting", systemImage: "pencil.and.outline")
            }
            .tag(Tab.inpainting)

            NavigationStack {
                LibraryView(library: library)
            }
            .tabItem {
                Label("Library", systemImage: "square.grid.2x2")
            }
            .tag(Tab.library)
        }
        .tint(.cloverGreen)
    }
}

#Preview {
    AppShell(
        library: ArtworkLibrary.preview,
        generator: PreviewGenerationService(),
        modelManager: ModelManager(previewInstalled: true),
        inpaintingModelManager: InpaintingModelManager()
    )
}
