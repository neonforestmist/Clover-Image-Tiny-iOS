import SwiftUI

struct AppShell: View {
    let library: ArtworkLibrary
    let generator: any ImageGenerating
    let modelManager: ModelManager
    let inpaintingModelManager: InpaintingModelManager

    @State private var route = Route()
    @State private var createStore: GenerationStore
    @State private var inpaintingSettings = GenerationSettings.inpaintingDefaults

    init(
        library: ArtworkLibrary,
        generator: any ImageGenerating,
        modelManager: ModelManager,
        inpaintingModelManager: InpaintingModelManager
    ) {
        self.library = library
        self.generator = generator
        self.modelManager = modelManager
        self.inpaintingModelManager = inpaintingModelManager
        _createStore = State(
            initialValue: GenerationStore(
                generator: generator,
                library: library
            )
        )
    }

    var body: some View {
        @Bindable var route = route
        nativeTabs(selection: $route.destination, path: $route.path)
        .environment(library)
        .environment(route)
        .tint(.cloverGreen)
        .onOpenURL { route.handle($0) }
        .onChange(of: route.pendingCreateSettings) { _, pending in
            guard let pending else { return }
            createStore.settings = pending
            createStore.settings.persist()
            route.pendingCreateSettings = nil
        }
        .fullScreenCover(isPresented: $route.settingsPresented) {
            SettingsScreen(
                modelManager: modelManager,
                inpaintingModelManager: inpaintingModelManager
            )
        }
    }

    private func nativeTabs(
        selection: Binding<Route.Destination>,
        path: Binding<NavigationPath>
    ) -> some View {
        @Bindable var store = createStore
        return TabView(selection: selection) {
            NavigationStack {
                CreateView(
                    store: store,
                    library: library,
                    modelManager: modelManager
                )
            }
            .tabItem {
                Label("Create", systemImage: "wand.and.stars")
            }
            .tag(Route.Destination.create)

            NavigationStack {
                InpaintingView(
                    library: library,
                    modelManager: inpaintingModelManager,
                    styleManager: modelManager,
                    settings: $inpaintingSettings
                )
            }
            .tabItem {
                Label("Inpaint", systemImage: "pencil.and.outline")
            }
            .tag(Route.Destination.inpainting)

            NavigationStack {
                ModelsScreen(
                    settings: $store.settings,
                    manager: modelManager,
                    inpaintingManager: inpaintingModelManager
                )
            }
            .tabItem {
                Label("Models", systemImage: "square.stack.3d.down.right")
            }
            .tag(Route.Destination.models)

            NavigationStack(path: path) {
                LibraryView(library: library)
            }
            .tabItem {
                Label("Library", systemImage: "photo.on.rectangle.angled")
            }
            .tag(Route.Destination.library)
        }
        .tabViewStyle(.sidebarAdaptable)
        .modifier(NativeTabBarBehavior())
        .onChange(of: route.destination) {
            if route.destination != .library {
                route.path.removeLast(route.path.count)
            }
        }
    }
}

private struct NativeTabBarBehavior: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
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
