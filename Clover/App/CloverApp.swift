import SwiftUI

@main
struct CloverApp: App {
    @State private var library = ArtworkLibrary()
    @State private var modelManager = ModelManager()
    private let generator = GenerationServiceFactory.make()

    var body: some Scene {
        WindowGroup {
            AppShell(
                library: library,
                generator: generator,
                modelManager: modelManager
            )
        }
    }
}
