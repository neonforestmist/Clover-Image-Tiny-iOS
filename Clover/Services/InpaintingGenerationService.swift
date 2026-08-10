import CoreGraphics
import CoreML
import Foundation
import StableDiffusion

struct InpaintingRequest: @unchecked Sendable {
    let image: CGImage
    let mask: CGImage
}

enum InpaintingImageComposer {
    /// Returns the conditioning image expected by a Stable Diffusion inpaint
    /// U-Net: original pixels outside the mask and black pixels inside it.
    static func maskedImage(
        from image: CGImage,
        mask: CGImage
    ) -> CGImage? {
        guard let original = rgbaBuffer(for: image),
              let maskBuffer = grayBuffer(for: mask),
              original.width == maskBuffer.width,
              original.height == maskBuffer.height else {
            return nil
        }
        for index in 0..<(original.width * original.height) {
            if maskBuffer.bytes[index] >= 128 {
                original.bytes[index * 4] = 0
                original.bytes[index * 4 + 1] = 0
                original.bytes[index * 4 + 2] = 0
            }
        }
        return original.makeImage()
    }

    /// Keeps the original pixels outside the white mask. This prevents a
    /// generative model from subtly rewriting the untouched part of a photo.
    static func composite(
        original image: CGImage,
        generated: CGImage,
        mask: CGImage
    ) -> CGImage? {
        guard let output = rgbaBuffer(for: generated),
              let original = rgbaBuffer(for: image),
              let maskBuffer = grayBuffer(for: mask),
              output.width == original.width,
              output.height == original.height,
              output.width == maskBuffer.width,
              output.height == maskBuffer.height else {
            return nil
        }
        for index in 0..<(output.width * output.height) {
            if maskBuffer.bytes[index] < 128 {
                output.bytes[index * 4] = original.bytes[index * 4]
                output.bytes[index * 4 + 1] = original.bytes[index * 4 + 1]
                output.bytes[index * 4 + 2] = original.bytes[index * 4 + 2]
                output.bytes[index * 4 + 3] = original.bytes[index * 4 + 3]
            }
        }
        return output.makeImage()
    }

    private final class RGBA: @unchecked Sendable {
        let width: Int
        let height: Int
        let bytes: UnsafeMutablePointer<UInt8>
        let context: CGContext

        init?(image: CGImage) {
            width = image.width
            height = image.height
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let data = context.data?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            self.context = context
            bytes = data
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        func makeImage() -> CGImage? {
            context.makeImage()
        }
    }

    private struct GrayBuffer {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    private static func rgbaBuffer(for image: CGImage) -> RGBA? {
        RGBA(image: image)
    }

    private static func grayBuffer(for image: CGImage) -> GrayBuffer? {
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let data = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return GrayBuffer(
            width: width,
            height: height,
            bytes: Array(UnsafeBufferPointer(start: data, count: width * height))
        )
    }
}

final class CoreMLInpaintingService: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.lukaslozada.Clover.inpainting",
        qos: .userInitiated
    )

    func generate(
        resourcesURL: URL,
        request: InpaintingRequest,
        settings: GenerationSettings,
        cancellation: GenerationCancellationToken,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [CGImage] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let images = try self.run(
                            resourcesURL: resourcesURL,
                            request: request,
                            settings: settings,
                            cancellation: cancellation,
                            progress: progress
                        )
                        continuation.resume(returning: images)
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
        resourcesURL: URL,
        request: InpaintingRequest,
        settings: GenerationSettings,
        cancellation: GenerationCancellationToken,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> [CGImage] {
        guard let maskedImage = InpaintingImageComposer.maskedImage(
            from: request.image,
            mask: request.mask
        ) else {
            throw CloverPipelineError.incompatibleResources
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = inpaintingComputeUnits(for: settings.computeTarget)
        let pipeline = try CloverPipelineFactory.makeInpainting(
            resourcesURL: resourcesURL,
            configuration: configuration
        )
        var generation = StableDiffusionPipeline.Configuration(
            prompt: settings.trimmedPrompt
        )
        generation.negativePrompt = settings.negativePrompt
        generation.startingImage = request.image
        generation.maskedImage = maskedImage
        generation.inpaintingMask = request.mask
        generation.imageCount = max(settings.imageCount, 1)
        generation.stepCount = settings.stepCount
        generation.seed = settings.seed
        generation.guidanceScale = Float(settings.guidanceScale)
        generation.schedulerType = inpaintingScheduler(for: settings.scheduler)
        generation.rngType = inpaintingRandomGenerator(for: settings.randomGenerator)
        generation.disableSafety = CloverPipelineFactory.isSafetyCheckerDisabled

        defer { pipeline.unloadResources() }
        let generated = try pipeline.generateImages(configuration: generation) { update in
            let complete = Double(update.step + 1) / Double(max(update.stepCount, 1))
            progress(min(max(complete, 0), 1))
            return !cancellation.isCancelled
        }
        guard !cancellation.isCancelled else {
            throw GenerationError.cancelled
        }
        return generated.compactMap { image in
            guard let image else { return nil }
            return InpaintingImageComposer.composite(
                original: request.image,
                generated: image,
                mask: request.mask
            ) ?? image
        }
    }

    private func inpaintingScheduler(
        for scheduler: GenerationSettings.Scheduler
    ) -> StableDiffusionScheduler {
        switch scheduler {
        case .pndm: .pndmScheduler
        case .dpmSolver: .dpmSolverMultistepScheduler
        }
    }

    private func inpaintingRandomGenerator(
        for generator: GenerationSettings.RandomGenerator
    ) -> StableDiffusionRNG {
        switch generator {
        case .numpy: .numpyRNG
        case .torch: .torchRNG
        }
    }

    private func inpaintingComputeUnits(
        for target: GenerationSettings.ComputeTarget
    ) -> MLComputeUnits {
        #if targetEnvironment(simulator)
        return .cpuOnly
        #else
        switch target {
        case .neuralEngine: .cpuAndNeuralEngine
        case .automatic: .all
        case .gpu: .cpuAndGPU
        }
        #endif
    }
}
