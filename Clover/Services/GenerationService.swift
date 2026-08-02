import CoreGraphics
import CoreML
import Foundation
import StableDiffusion
import UIKit

struct GeneratedImage: @unchecked Sendable {
    let cgImage: CGImage
}

enum GenerationError: LocalizedError {
    case missingResources
    case noSafeImages
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingResources:
            "The Core ML resources are missing from this build."
        case .noSafeImages:
            "The safety checker did not return an image."
        case .cancelled:
            "Generation was cancelled."
        }
    }
}

final class GenerationCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
        }
    }
}

protocol ImageGenerating: Sendable {
    func generate(
        settings: GenerationSettings,
        cancellation: GenerationCancellationToken,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [GeneratedImage]
}

enum GenerationServiceFactory {
    static func make() -> any ImageGenerating {
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-preview") {
            return PreviewGenerationService()
        }
        return CoreMLGenerationService()
    }
}

final class CoreMLGenerationService: ImageGenerating, @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.lukaslozada.Clover.generation",
        qos: .userInitiated
    )

    private var pipeline: StableDiffusionPipeline?
    private var loadedComputeTarget: GenerationSettings.ComputeTarget?
    private var loadedModelID: String?

    func generate(
        settings: GenerationSettings,
        cancellation: GenerationCancellationToken,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [GeneratedImage] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        continuation.resume(
                            returning: try run(
                                settings: settings,
                                cancellation: cancellation,
                                progress: progress
                            )
                        )
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func run(
        settings: GenerationSettings,
        cancellation: GenerationCancellationToken,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> [GeneratedImage] {
        guard let resourcesURL = ModelStorage.resourcesURL(
            for: settings.modelID
        ) else {
            throw GenerationError.missingResources
        }

        if pipeline == nil
            || loadedComputeTarget != settings.computeTarget
            || loadedModelID != settings.modelID {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = settings.computeTarget.coreMLComputeUnits

            let newPipeline = try CloverPipelineFactory.make(
                resourcesURL: resourcesURL,
                modelID: settings.modelID,
                styleWeightsURL: ModelStorage.importedWeightsURL(
                    for: settings.modelID
                ),
                configuration: configuration
            )
            try newPipeline.loadResources()
            pipeline = newPipeline
            loadedComputeTarget = settings.computeTarget
            loadedModelID = settings.modelID
        }

        guard let pipeline else {
            throw GenerationError.missingResources
        }
        guard !cancellation.isCancelled else {
            throw GenerationError.cancelled
        }

        var configuration = StableDiffusionPipeline.Configuration(
            prompt: settings.trimmedPrompt
        )
        configuration.negativePrompt = settings.negativePrompt
        configuration.imageCount = settings.imageCount
        configuration.stepCount = settings.stepCount
        configuration.seed = settings.seed
        configuration.guidanceScale = Float(settings.guidanceScale)
        configuration.schedulerType = settings.scheduler.coreMLScheduler
        configuration.rngType = settings.randomGenerator.coreMLRandomGenerator

        let images = try pipeline.generateImages(configuration: configuration) { update in
            let denominator = max(update.stepCount, 1)
            progress(Double(update.step) / Double(denominator))
            return !cancellation.isCancelled
        }

        guard !cancellation.isCancelled else {
            throw GenerationError.cancelled
        }

        let safeImages = images.compactMap { $0 }.compactMap {
            $0.cropped(using: settings)
        }.map(GeneratedImage.init)
        guard !safeImages.isEmpty else {
            throw GenerationError.noSafeImages
        }
        progress(1)
        return safeImages
    }
}

final class PreviewGenerationService: ImageGenerating, @unchecked Sendable {
    func generate(
        settings: GenerationSettings,
        cancellation: GenerationCancellationToken,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [GeneratedImage] {
        for step in 1...10 {
            try await Task.sleep(for: .milliseconds(90))
            guard !cancellation.isCancelled else {
                throw GenerationError.cancelled
            }
            progress(Double(step) / 10)
        }

        guard let image = UIImage(named: "SampleOutput")?.cgImage else {
            throw GenerationError.missingResources
        }
        guard let cropped = image.cropped(using: settings) else {
            throw GenerationError.missingResources
        }
        return (0..<settings.imageCount).map { _ in
            GeneratedImage(cgImage: cropped)
        }
    }
}

extension CGImage {
    func cropped(
        using settings: GenerationSettings
    ) -> CGImage? {
        let source = CGSize(width: width, height: height)
        let target = settings.croppedSize(from: source)
        let rect = CGRect(
            x: ((source.width - target.width) / 2).rounded(.down),
            y: ((source.height - target.height) / 2).rounded(.down),
            width: target.width,
            height: target.height
        )
        return cropping(to: rect)
    }
}

private extension GenerationSettings.Scheduler {
    var coreMLScheduler: StableDiffusionScheduler {
        switch self {
        case .pndm: .pndmScheduler
        case .dpmSolver: .dpmSolverMultistepScheduler
        }
    }
}

private extension GenerationSettings.RandomGenerator {
    var coreMLRandomGenerator: StableDiffusionRNG {
        switch self {
        case .numpy: .numpyRNG
        case .torch: .torchRNG
        }
    }
}

private extension GenerationSettings.ComputeTarget {
    var coreMLComputeUnits: MLComputeUnits {
        #if targetEnvironment(simulator)
        return .cpuAndGPU
        #else
        switch self {
        case .neuralEngine: .cpuAndNeuralEngine
        case .automatic: .all
        case .gpu: .cpuAndGPU
        }
        #endif
    }
}
