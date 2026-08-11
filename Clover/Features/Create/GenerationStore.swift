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
    private(set) var activity = GenerationActivity.loadingModel
    private(set) var latest: [Artwork] = []
    private(set) var preview: GenerationPreview?
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
        activity = .loadingModel
        preview = nil
        errorMessage = nil
        let request = settings
        let token = GenerationCancellationToken()
        cancellation = token

        task = Task { [weak self, generator, library] in
            guard let self else { return }
            do {
                let result = try await generator.generate(
                    settings: request,
                    cancellation: token
                ) { update in
                    Task { @MainActor [self] in
                        self.phase = .generating(update.progress)
                        self.activity = update.activity
                        if let preview = update.preview {
                            self.preview = preview
                        }
                    }
                }

                guard !Task.isCancelled else { return }
                phase = .generating(0.98)
                activity = .saving
                latest = try library.add(
                    images: result.images,
                    previewFrames: result.previewFrames,
                    settings: request
                )
                preview = nil
                phase = .finished
                HapticManager.success()
            } catch GenerationError.cancelled {
                preview = nil
                phase = .idle
            } catch is CancellationError {
                preview = nil
                phase = .idle
            } catch {
                preview = nil
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
        preview = nil
        phase = .idle
    }
}

enum SheetDestination: String, Identifiable {
    case parameters
    case models

    var id: String { rawValue }
}
