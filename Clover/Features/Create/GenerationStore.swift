import Foundation
import Observation

@MainActor
@Observable
final class GenerationStore {
    enum Phase: Equatable {
        case idle
        case preparing
        case generating(Double)
        case finished

        var isWorking: Bool {
            switch self {
            case .preparing, .generating: true
            case .idle, .finished: false
            }
        }
    }

    var settings = GenerationSettings.restored()
    private(set) var phase = Phase.idle
    private(set) var latest: [Artwork] = []
    var presentedSheet: SheetDestination?
    var errorMessage: String?

    private let generator: any ImageGenerating
    private let library: ArtworkLibrary
    private var task: Task<Void, Never>?
    private var cancellation: GenerationCancellationToken?

    init(generator: any ImageGenerating, library: ArtworkLibrary) {
        self.generator = generator
        self.library = library
    }

    func generate() {
        guard !phase.isWorking, !settings.trimmedPrompt.isEmpty else { return }

        settings.persist()
        phase = .preparing
        errorMessage = nil
        let request = settings
        let token = GenerationCancellationToken()
        cancellation = token

        task = Task { [weak self, generator, library] in
            guard let self else { return }
            do {
                let images = try await generator.generate(
                    settings: request,
                    cancellation: token
                ) { progress in
                    Task { @MainActor [self] in
                        self.phase = .generating(progress)
                    }
                }

                guard !Task.isCancelled else { return }
                latest = try library.add(images: images, settings: request)
                phase = .finished
                HapticManager.success()
            } catch GenerationError.cancelled {
                phase = .idle
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .idle
                errorMessage = error.localizedDescription
                HapticManager.error()
            }
            cancellation = nil
            task = nil
        }
    }

    func cancel() {
        cancellation?.cancel()
        task?.cancel()
        phase = .idle
    }
}

enum SheetDestination: String, Identifiable {
    case parameters
    case models

    var id: String { rawValue }
}
