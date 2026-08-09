import CoreGraphics
import CoreML
import Foundation
import StableDiffusion
import UIKit

struct GeneratedImage: @unchecked Sendable {
    let cgImage: CGImage
    let imageIndex: Int
}

struct GeneratedPreviewFrame: Sendable {
    let jpegData: Data
    let step: Int
    let stepCount: Int
    let imageIndex: Int
}

struct GenerationResult: Sendable {
    let images: [GeneratedImage]
    let previewFrames: [GeneratedPreviewFrame]
}

struct GenerationPreview: @unchecked Sendable {
    let cgImage: CGImage
    let step: Int
    let stepCount: Int
    let imageIndex: Int
}

struct GenerationUpdate: @unchecked Sendable {
    let progress: Double
    let preview: GenerationPreview?
}

enum GenerationError: LocalizedError {
    case missingResources
    case noImages
    case modelExecutionPlan
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingResources:
            "The Core ML resources are missing from this build."
        case .noImages:
            "Clover couldn’t produce an image. Try generating again."
        case .modelExecutionPlan:
            "Clover couldn’t start its Core ML model. Restart the app and try again. If it continues, remove and download Clover again."
        case .cancelled:
            "Generation was cancelled."
        }
    }

    static func presenting(_ error: Error) -> Error {
        let coreMLError = error as NSError
        let description = coreMLError.localizedDescription
        if coreMLError.domain.localizedCaseInsensitiveContains("safety")
            || description.localizedCaseInsensitiveContains("safety check") {
            return GenerationError.noImages
        }
        guard coreMLError.domain == "com.apple.CoreML",
              description.localizedCaseInsensitiveContains(
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
        progress: @escaping @Sendable (GenerationUpdate) -> Void
    ) async throws -> GenerationResult
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
        progress: @escaping @Sendable (GenerationUpdate) -> Void
    ) async throws -> GenerationResult {
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
        progress: @escaping @Sendable (GenerationUpdate) -> Void
    ) throws -> GenerationResult {
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
        configuration.useDenoisedIntermediates = settings.livePreviewEnabled
        configuration.disableSafety = CloverPipelineFactory
            .isSafetyCheckerDisabled

        defer { pipeline.unloadResources() }

        let imageCount = max(settings.imageCount, 1)
        var images: [GeneratedImage] = []
        images.reserveCapacity(imageCount)
        var storedPreviews: [GeneratedPreviewFrame] = []

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
                    let completedStep = min(update.step + 1, stepCount)
                    let imageProgress = Double(completedStep)
                        / Double(stepCount)
                    let totalProgress = (
                        Double(imageIndex) + imageProgress
                    ) / Double(imageCount)
                    let previewInterval = min(
                        min(max(settings.previewInterval, 1), 10),
                        stepCount
                    )
                    let shouldPreview = settings.livePreviewEnabled
                        && (completedStep.isMultiple(of: previewInterval)
                            || completedStep == stepCount)
                    let renderedPreview = shouldPreview
                        ? autoreleasepool {
                            LatentPreviewRenderer.render(
                                update.currentLatentSamples.first
                            )
                        }
                        : nil
                    let preview = renderedPreview.map { image in
                        GenerationPreview(
                            cgImage: image,
                            step: completedStep,
                            stepCount: stepCount,
                            imageIndex: imageIndex
                        )
                    }
                    if completedStep < stepCount,
                       let renderedPreview,
                       let jpegData = autoreleasepool(invoking: {
                           UIImage(cgImage: renderedPreview).jpegData(
                               compressionQuality: 0.82
                           )
                       }) {
                        storedPreviews.append(
                            GeneratedPreviewFrame(
                                jpegData: jpegData,
                                step: completedStep,
                                stepCount: stepCount,
                                imageIndex: imageIndex
                            )
                        )
                    }
                    progress(
                        GenerationUpdate(
                            progress: totalProgress,
                            preview: preview
                        )
                    )
                    return !cancellation.isCancelled
                }
            }
            images.append(
                contentsOf: generated.compactMap { image in
                    image.map {
                        GeneratedImage(
                            cgImage: $0,
                            imageIndex: imageIndex
                        )
                    }
                }
            )
        }

        guard !cancellation.isCancelled else {
            throw GenerationError.cancelled
        }

        guard !images.isEmpty else {
            throw GenerationError.noImages
        }
        progress(GenerationUpdate(progress: 1, preview: nil))
        let safeImageIndices = Set(images.map(\.imageIndex))
        return GenerationResult(
            images: images,
            previewFrames: storedPreviews.filter {
                safeImageIndices.contains($0.imageIndex)
            }
        )
    }
}

/// Produces an inexpensive approximation directly from the four-channel
/// Stable Diffusion latent. This deliberately avoids loading the VAE decoder
/// (and safety checker) while the U-Net is resident on memory-constrained
/// iPhones. The full-resolution final image still uses the model decoder.
enum LatentPreviewRenderer {
    private static let rgbFactors: [[Float32]] = [
        [0.298, 0.207, 0.208],
        [0.187, 0.286, 0.173],
        [-0.158, 0.189, 0.264],
        [-0.184, -0.271, -0.473],
    ]

    static func render(
        _ latent: MLShapedArray<Float32>?
    ) -> CGImage? {
        guard let latent,
              latent.shape.count >= 3 else { return nil }

        let shape = latent.shape
        let width = shape[shape.count - 1]
        let height = shape[shape.count - 2]
        let channels = shape[shape.count - 3]
        guard width > 0,
              height > 0,
              channels >= rgbFactors.count else { return nil }

        let planeSize = width * height
        let scalars = latent.scalars
        guard scalars.count >= planeSize * channels else { return nil }

        var pixels = [UInt8](repeating: 255, count: planeSize * 4)
        for pixelIndex in 0..<planeSize {
            var red: Float32 = 0
            var green: Float32 = 0
            var blue: Float32 = 0
            for channel in 0..<rgbFactors.count {
                let value = scalars[channel * planeSize + pixelIndex]
                red += value * rgbFactors[channel][0]
                green += value * rgbFactors[channel][1]
                blue += value * rgbFactors[channel][2]
            }

            let outputIndex = pixelIndex * 4
            pixels[outputIndex] = componentByte(red)
            pixels[outputIndex + 1] = componentByte(green)
            pixels[outputIndex + 2] = componentByte(blue)
        }

        guard let provider = CGDataProvider(
            data: Data(pixels) as CFData
        ),
        let smallImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            return nil
        }

        let scale = max(1, 512 / max(width, height))
        let scaledWidth = width * scale
        let scaledHeight = height * scale
        guard let context = CGContext(
            data: nil,
            width: scaledWidth,
            height: scaledHeight,
            bitsPerComponent: 8,
            bytesPerRow: scaledWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return smallImage
        }
        context.interpolationQuality = .high
        context.draw(
            smallImage,
            in: CGRect(
                x: 0,
                y: 0,
                width: scaledWidth,
                height: scaledHeight
            )
        )
        return context.makeImage() ?? smallImage
    }

    private static func componentByte(_ value: Float32) -> UInt8 {
        let normalized = (tanh(value) + 1) * 0.5
        return UInt8(max(0, min(255, Int(normalized * 255))))
    }
}

final class PreviewGenerationService: ImageGenerating, @unchecked Sendable {
    func generate(
        settings: GenerationSettings,
        cancellation: GenerationCancellationToken,
        progress: @escaping @Sendable (GenerationUpdate) -> Void
    ) async throws -> GenerationResult {
        guard let image = UIImage(named: "SampleOutput")?.cgImage else {
            throw GenerationError.missingResources
        }
        let stepCount = max(settings.stepCount, 1)
        let previewInterval = min(
            min(max(settings.previewInterval, 1), 10),
            stepCount
        )
        let jpegData = UIImage(cgImage: image).jpegData(
            compressionQuality: 0.86
        )
        var storedPreviews: [GeneratedPreviewFrame] = []

        for completedStep in 1...stepCount {
            try await Task.sleep(for: .milliseconds(30))
            guard !cancellation.isCancelled else {
                throw GenerationError.cancelled
            }
            let shouldPreview = settings.livePreviewEnabled
                && (completedStep.isMultiple(of: previewInterval)
                    || completedStep == stepCount)
            if shouldPreview,
               completedStep < stepCount,
               let jpegData {
                for imageIndex in 0..<settings.imageCount {
                    storedPreviews.append(
                        GeneratedPreviewFrame(
                            jpegData: jpegData,
                            step: completedStep,
                            stepCount: stepCount,
                            imageIndex: imageIndex
                        )
                    )
                }
            }
            progress(
                GenerationUpdate(
                    progress: Double(completedStep) / Double(stepCount),
                    preview: shouldPreview
                        ? GenerationPreview(
                            cgImage: image,
                            step: completedStep,
                            stepCount: stepCount,
                            imageIndex: 0
                        )
                        : nil
                )
            )
        }
        return GenerationResult(
            images: (0..<settings.imageCount).map {
                GeneratedImage(cgImage: image, imageIndex: $0)
            },
            previewFrames: storedPreviews
        )
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
