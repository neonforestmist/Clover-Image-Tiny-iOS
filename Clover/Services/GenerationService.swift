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
    case modelExecutionPlan
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingResources:
            "The Core ML resources are missing from this build."
        case .noSafeImages:
            "The safety checker did not return an image."
        case .modelExecutionPlan:
            "Clover couldn’t start its Core ML model. Restart the app and try again. If it continues, remove and download Clover again."
        case .cancelled:
            "Generation was cancelled."
        }
    }

    static func presenting(_ error: Error) -> Error {
        let coreMLError = error as NSError
        guard coreMLError.domain == "com.apple.CoreML",
              coreMLError.localizedDescription.localizedCaseInsensitiveContains(
                "execution plan"
              ) else {
            return error
        }
        return GenerationError.modelExecutionPlan
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
                        continuation.resume(
                            throwing: GenerationError.presenting(error)
                        )
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
                styleWeightsURL: ModelStorage.importedWeightsURL(
                    for: settings.modelID
                ),
                configuration: configuration
            )
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
        configuration.imageCount = 1
        configuration.stepCount = settings.stepCount
        configuration.guidanceScale = Float(settings.guidanceScale)
        configuration.schedulerType = settings.scheduler.coreMLScheduler
        configuration.rngType = settings.randomGenerator.coreMLRandomGenerator
        configuration.disableSafety = CloverPipelineFactory
            .isSafetyCheckerDisabled

        defer { pipeline.unloadResources() }

        let imageCount = max(settings.imageCount, 1)
        var images: [CGImage?] = []
        images.reserveCapacity(imageCount)

        for imageIndex in 0..<imageCount {
            guard !cancellation.isCancelled else {
                throw GenerationError.cancelled
            }

            configuration.seed = settings.seed &+ UInt32(imageIndex)
            let generated = try autoreleasepool {
                try pipeline.generateImages(
                    configuration: configuration
                ) { update in
                    let stepCount = max(update.stepCount, 1)
                    let imageProgress = Double(update.step)
                        / Double(stepCount)
                    let totalProgress = (
                        Double(imageIndex) + imageProgress
                    ) / Double(imageCount)
                    progress(totalProgress)
                    return !cancellation.isCancelled
                }
            }
            images.append(contentsOf: generated)
        }

        guard !cancellation.isCancelled else {
            throw GenerationError.cancelled
        }

        let safeImages = images.compactMap { $0 }.map(GeneratedImage.init)
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
        return (0..<settings.imageCount).map { _ in
            GeneratedImage(cgImage: image)
        }
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
        // Stateful ML Programs can fail to build a GPU execution plan in the
        // simulator. CPU-only keeps simulator smoke tests deterministic; real
        // iPhones continue to honor the selected compute target below.
        return .cpuOnly
        #else
        switch self {
        case .neuralEngine: .cpuAndNeuralEngine
        case .automatic: .all
        case .gpu: .cpuAndGPU
        }
        #endif
    }
}
