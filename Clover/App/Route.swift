import Foundation
import Observation
import SwiftUI

enum StudioMode: String, CaseIterable, Identifiable, Sendable {
    case create
    case inpaint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .create: "Create"
        case .inpaint: "Inpaint"
        }
    }

    var symbol: String {
        switch self {
        case .create: "wand.and.stars"
        case .inpaint: "paintbrush.pointed"
        }
    }
}

@MainActor
@Observable
final class Route {
    enum Destination: String, Hashable, CaseIterable, Identifiable {
        case create
        case inpainting
        case models
        case library

        var id: String { rawValue }

        var title: String {
            switch self {
            case .create: "Create"
            case .inpainting: "Inpaint"
            case .models: "Models"
            case .library: "Library"
            }
        }

        var symbol: String {
            switch self {
            case .create: "wand.and.stars"
            case .inpainting: "pencil.and.outline"
            case .models: "square.stack.3d.down.right"
            case .library: "photo.on.rectangle.angled"
            }
        }
    }

    /// The section currently occupying the root of the app.
    var destination: Destination = .create
    /// Inner pushes on top of the current section (e.g. Library artwork detail).
    var path = NavigationPath()
    var settingsPresented = false
    var pendingCreateSettings: GenerationSettings?
    var pendingInpaintingSession: InpaintingStudioSession?

    func open(_ destination: Destination) {
        self.destination = destination
        path.removeLast(path.count)
    }

    func handle(_ url: URL) {
        switch url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "inpaint", "inpainting":
            open(.inpainting)
        case "models":
            open(.models)
        case "library":
            open(.library)
        case "settings":
            settingsPresented = true
        case "create", "studio":
            open(.create)
        default:
            break
        }
    }

    func openCreate(with settings: GenerationSettings) {
        pendingCreateSettings = settings
        open(.create)
    }

    func openInpainting(
        with settings: GenerationSettings,
        sourceImage: CGImage,
        maskImage: CGImage
    ) {
        pendingInpaintingSession = InpaintingStudioSession(
            settings: settings,
            sourceImage: sourceImage,
            maskImage: maskImage
        )
        open(.inpainting)
    }
}

struct InpaintingStudioSession: Identifiable, @unchecked Sendable {
    let id = UUID()
    let settings: GenerationSettings
    let sourceImage: CGImage
    let maskImage: CGImage
}
