import CoreGraphics
import CoreML
import Foundation
import StableDiffusion
import UIKit

enum InpaintingGenerationLimits {
    static let minimumStepCount = 4
    static let maximumStepCount = 50

    static func clampedStepCount(_ stepCount: Int) -> Int {
        min(max(stepCount, minimumStepCount), maximumStepCount)
    }
}

enum InpaintingPreviewPolicy {
    static func shouldRender(
        enabled: Bool,
        completedStep: Int,
        stepCount: Int,
        interval: Int
    ) -> Bool {
        guard enabled else { return false }
        let clampedInterval = min(max(interval, 1), 10)
        return completedStep.isMultiple(of: clampedInterval)
            || completedStep >= stepCount
    }
}

struct InpaintingRequest: @unchecked Sendable {
    let image: CGImage
    let mask: CGImage
}

struct InpaintingPreparedInput: @unchecked Sendable {
    let image: CGImage
    let mask: CGImage
    let cropRect: CGRect
}

enum InpaintingImageComposer {
    static let inferenceSize = 512
    // Retained for compatibility with older installed model manifests and
    // geometry helper tests. Focused inpainting uses crop context instead.
    static let conditioningMaskExpansion = 64

    /// Gives a small painted region enough latent resolution by running a
    /// square crop that includes 96 points of source context on every side.
    /// This matches the focused-mask flow used by the Diffusers demo.
    static func prepareFocusedInput(
        image: CGImage,
        mask: CGImage
    ) -> InpaintingPreparedInput? {
        guard image.width == mask.width,
              image.height == mask.height,
              let maskBuffer = grayBuffer(for: mask),
              let bounds = whiteMaskBounds(maskBuffer) else {
            return nil
        }

        let fullRect = CGRect(
            x: 0,
            y: 0,
            width: image.width,
            height: image.height
        )

        let largestMaskSide = max(bounds.width, bounds.height)
        let cropSide = min(
            min(image.width, image.height),
            max(192, Int(largestMaskSide) + 192)
        )
        guard cropSide < min(image.width, image.height) - 16 else {
            return InpaintingPreparedInput(
                image: image,
                mask: mask,
                cropRect: fullRect
            )
        }

        let centerX = Int(bounds.midX.rounded())
        let centerY = Int(bounds.midY.rounded())
        let originX = min(
            max(centerX - cropSide / 2, 0),
            image.width - cropSide
        )
        let originY = min(
            max(centerY - cropSide / 2, 0),
            image.height - cropSide
        )
        let cropRect = CGRect(
            x: originX,
            y: originY,
            width: cropSide,
            height: cropSide
        )
        guard let croppedImage = image.cropping(to: cropRect),
              let croppedMask = mask.cropping(to: cropRect),
              let preparedImage = resized(
                  croppedImage,
                  width: inferenceSize,
                  height: inferenceSize
              ),
              let preparedMask = resized(
                  croppedMask,
                  width: inferenceSize,
                  height: inferenceSize,
                  grayscale: true
              ) else {
            return nil
        }
        return InpaintingPreparedInput(
            image: preparedImage,
            mask: preparedMask,
            cropRect: cropRect
        )
    }

    /// Returns the conditioning image expected by a Stable Diffusion inpaint
    /// U-Net: original pixels outside the mask and neutral gray inside it.
    /// Diffusers zeros the already-normalized [-1, 1] image tensor. Clover's
    /// VAE performs that normalization, so a zero-valued tensor is represented
    /// by 0.5 gray (128) in the pixel-space conditioning image.
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
                original.bytes[index * 4] = 128
                original.bytes[index * 4 + 1] = 128
                original.bytes[index * 4 + 2] = 128
            }
        }
        return original.makeImage()
    }

    /// Expands only the mask supplied to the inpainting model. Small painted
    /// regions otherwise leave too little latent-space context for the model
    /// to form a requested object. Final compositing still uses the user's
    /// original mask, so pixels outside their selection remain untouched.
    static func expandedConditioningMask(
        _ mask: CGImage,
        radius: Int = conditioningMaskExpansion
    ) -> CGImage? {
        guard radius > 0, let source = grayBuffer(for: mask) else {
            return mask
        }
        let width = source.width
        let height = source.height
        var horizontal = [UInt8](repeating: 0, count: width * height)
        var expanded = [UInt8](repeating: 0, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let lower = max(x - radius, 0)
                let upper = min(x + radius, width - 1)
                var value: UInt8 = 0
                for sourceX in lower...upper {
                    value = max(value, source.bytes[y * width + sourceX])
                }
                horizontal[y * width + x] = value
            }
        }
        for y in 0..<height {
            let lower = max(y - radius, 0)
            let upper = min(y + radius, height - 1)
            for x in 0..<width {
                var value: UInt8 = 0
                for sourceY in lower...upper {
                    value = max(value, horizontal[sourceY * width + x])
                }
                expanded[y * width + x] = value
            }
        }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let destination = context.data?.assumingMemoryBound(to: UInt8.self)
        else {
            return nil
        }
        expanded.withUnsafeBufferPointer { source in
            destination.update(from: source.baseAddress!, count: expanded.count)
        }
        return context.makeImage()
    }

    /// Keeps the original pixels outside the white mask. This prevents a
    /// generative model from subtly rewriting the untouched part of a photo.
    static func composite(
        original image: CGImage,
        generated: CGImage,
        mask: CGImage,
        featherRadius: Int = 0
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
        let compositingMask = featherRadius > 1
            ? feathered(maskBuffer, radius: featherRadius)
            : maskBuffer
        blend(
            output: output,
            original: original,
            generated: output,
            mask: compositingMask
        )

        // The inward feather deliberately returns zero outside the white
        // mask. Preserve the source alpha there as well, so transparent input
        // images do not acquire an opaque halo at the edit boundary.
        for index in 0..<(output.width * output.height)
        where maskBuffer.bytes[index] < 128 {
            output.bytes[index * 4 + 3] = original.bytes[index * 4 + 3]
        }
        return output.makeImage()
    }

    /// Maps a generated focus crop back to the source image while changing
    /// only pixels selected by the original white mask.
    static func compositeFocused(
        original image: CGImage,
        generated: CGImage,
        mask: CGImage,
        cropRect: CGRect,
        featherRadius: Int = 0
    ) -> CGImage? {
        let fullRect = CGRect(
            x: 0,
            y: 0,
            width: image.width,
            height: image.height
        )
        if cropRect.equalTo(fullRect) {
            return composite(
                original: image,
                generated: generated,
                mask: mask,
                featherRadius: featherRadius
            )
        }

        let cropWidth = Int(cropRect.width)
        let cropHeight = Int(cropRect.height)
        guard let generatedCrop = resized(
            generated,
            width: cropWidth,
            height: cropHeight
        ),
        let output = rgbaBuffer(for: image),
        let generatedBuffer = rgbaBuffer(for: generatedCrop),
        let maskBuffer = grayBuffer(for: mask) else {
            return nil
        }

        let originX = Int(cropRect.origin.x)
        let originY = Int(cropRect.origin.y)
        let compositingMask = featherRadius > 1
            ? feathered(maskBuffer, radius: featherRadius)
            : maskBuffer
        for cropY in 0..<cropHeight {
            let imageY = originY + cropY
            for cropX in 0..<cropWidth {
                let imageX = originX + cropX
                let imageIndex = imageY * image.width + imageX
                let alpha = Int(compositingMask.bytes[imageIndex])
                guard alpha > 0 else { continue }
                let cropIndex = cropY * cropWidth + cropX
                for channel in 0..<3 {
                    let originalValue = Int(output.bytes[imageIndex * 4 + channel])
                    let generatedValue = Int(
                        generatedBuffer.bytes[cropIndex * 4 + channel]
                    )
                    output.bytes[imageIndex * 4 + channel] = UInt8(
                        (generatedValue * alpha
                        + originalValue * (255 - alpha)
                            + 127) / 255
                    )
                }
                let generatedAlpha = Int(generatedBuffer.bytes[cropIndex * 4 + 3])
                let originalAlpha = Int(output.bytes[imageIndex * 4 + 3])
                output.bytes[imageIndex * 4 + 3] = UInt8(
                    (generatedAlpha * alpha
                        + originalAlpha * (255 - alpha)
                        + 127) / 255
                )
            }
        }
        return output.makeImage()
    }

    /// Rejects the known failed-sampler output: a nearly solid black masked
    /// region. Keeping this check before compositing prevents a bad render
    /// from replacing the editor canvas.
    static func hasUsableMaskedContent(
        generated: CGImage,
        mask: CGImage
    ) -> Bool {
        guard let output = rgbaBuffer(for: generated),
              let maskBuffer = grayBuffer(for: mask),
              output.width == maskBuffer.width,
              output.height == maskBuffer.height else {
            return false
        }

        var maskedPixelCount = 0
        var nearlyBlackPixelCount = 0
        for index in 0..<(output.width * output.height)
        where maskBuffer.bytes[index] >= 128 {
            maskedPixelCount += 1
            let offset = index * 4
            if output.bytes[offset] <= 4,
               output.bytes[offset + 1] <= 4,
               output.bytes[offset + 2] <= 4 {
                nearlyBlackPixelCount += 1
            }
        }

        guard maskedPixelCount > 0 else { return false }
        return Double(nearlyBlackPixelCount) / Double(maskedPixelCount) < 0.98
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

    private static func whiteMaskBounds(_ mask: GrayBuffer) -> CGRect? {
        var minX = mask.width
        var minY = mask.height
        var maxX = -1
        var maxY = -1
        for y in 0..<mask.height {
            for x in 0..<mask.width
            where mask.bytes[y * mask.width + x] >= 128 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }

    private static func feathered(
        _ mask: GrayBuffer,
        radius: Int
    ) -> GrayBuffer {
        guard radius > 1 else { return mask }
        let count = mask.width * mask.height
        let far = mask.width + mask.height
        var distances = [Int](repeating: far, count: count)

        for y in 0..<mask.height {
            for x in 0..<mask.width {
                let index = y * mask.width + x
                guard mask.bytes[index] >= 128 else {
                    distances[index] = 0
                    continue
                }
                if x > 0 {
                    distances[index] = min(distances[index], distances[index - 1] + 1)
                }
                if y > 0 {
                    distances[index] = min(
                        distances[index],
                        distances[index - mask.width] + 1
                    )
                }
            }
        }
        for y in stride(from: mask.height - 1, through: 0, by: -1) {
            for x in stride(from: mask.width - 1, through: 0, by: -1) {
                let index = y * mask.width + x
                guard distances[index] > 0 else { continue }
                if x + 1 < mask.width {
                    distances[index] = min(distances[index], distances[index + 1] + 1)
                }
                if y + 1 < mask.height {
                    distances[index] = min(
                        distances[index],
                        distances[index + mask.width] + 1
                    )
                }
            }
        }

        return GrayBuffer(
            width: mask.width,
            height: mask.height,
            bytes: distances.enumerated().map { index, distance in
                guard mask.bytes[index] >= 128 else { return 0 }
                return UInt8(min(distance * 255 / radius, 255))
            }
        )
    }

    private static func blend(
        output: RGBA,
        original: RGBA,
        generated: RGBA,
        mask: GrayBuffer
    ) {
        for index in 0..<(output.width * output.height) {
            let alpha = Int(mask.bytes[index])
            for channel in 0..<3 {
                let generatedValue = Int(generated.bytes[index * 4 + channel])
                let originalValue = Int(original.bytes[index * 4 + channel])
                output.bytes[index * 4 + channel] = UInt8(
                    (generatedValue * alpha
                        + originalValue * (255 - alpha)
                        + 127) / 255
                )
            }
        }
    }

    private static func resized(
        _ image: CGImage,
        width: Int,
        height: Int,
        grayscale: Bool = false
    ) -> CGImage? {
        let colorSpace = grayscale
            ? CGColorSpaceCreateDeviceGray()
            : (CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB())
        let bytesPerRow = grayscale ? width : width * 4
        let bitmapInfo = grayscale
            ? CGImageAlphaInfo.none.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        context.interpolationQuality = grayscale ? .none : .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
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
        progress: @escaping @Sendable (GenerationUpdate) -> Void
    ) async throws -> GenerationResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let images = try autoreleasepool {
                            try self.run(
                                resourcesURL: resourcesURL,
                                request: request,
                                settings: settings,
                                cancellation: cancellation,
                                progress: progress
                            )
                        }
                        continuation.resume(returning: images)
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
        resourcesURL: URL,
        request: InpaintingRequest,
        settings: GenerationSettings,
        cancellation: GenerationCancellationToken,
        progress: @escaping @Sendable (GenerationUpdate) -> Void
    ) throws -> GenerationResult {
        // Match the Diffusers inpaint demo: focus a 512px inference canvas
        // around the painted region while retaining 96 points of surrounding
        // source context. A small mask otherwise occupies too few latent
        // pixels in a full-frame pass and the model recreates the background
        // instead of the requested replacement.
        guard let prepared = InpaintingImageComposer.prepareFocusedInput(
            image: request.image,
            mask: request.mask
        ),
            let maskedImage = InpaintingImageComposer.maskedImage(
                from: prepared.image,
                mask: prepared.mask
            ) else {
            throw CloverPipelineError.incompatibleResources
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = inpaintingComputeUnits(for: settings.computeTarget)
        let pipeline = try CloverPipelineFactory.makeInpainting(
            resourcesURL: resourcesURL,
            // Create LoRAs target a different U-Net and must not be applied to
            // the standalone inpainting checkpoint.
            styleWeights: [],
            configuration: configuration
        )
        let requestedStepCount = InpaintingGenerationLimits.clampedStepCount(
            settings.stepCount
        )
        var generation = StableDiffusionPipeline.Configuration(
            prompt: settings.trimmedPrompt
        )
        generation.negativePrompt = settings.negativePrompt
        generation.startingImage = prepared.image
        generation.maskedImage = maskedImage
        generation.inpaintingMask = prepared.mask
        generation.imageCount = max(settings.imageCount, 1)
        generation.stepCount = requestedStepCount
        generation.seed = settings.seed
        generation.guidanceScale = Float(settings.guidanceScale)
        // DPM-Solver is stable for this 9-channel model. PNDM can collapse
        // otherwise valid edits to an all-black masked region at 30+ steps.
        generation.schedulerType = .dpmSolverMultistepScheduler
        generation.rngType = inpaintingRandomGenerator(for: settings.randomGenerator)
        generation.useDenoisedIntermediates = settings.livePreviewEnabled
        // Inpainting never constructs a safety checker. Keep the pipeline
        // configuration in agreement so decode cannot discard a valid final
        // image after live previews have already been shown.
        generation.disableSafety = !InpaintingRuntimePolicy.isSafetyCheckerEnabled

        defer { pipeline.unloadResources() }
        var storedPreviews: [GeneratedPreviewFrame] = []
        var reportedProgress = 0.0
        let generated = try pipeline.generateImages(
            configuration: generation
        ) { update in
            let schedulerStepCount = max(update.stepCount, 1)
            let schedulerStep = min(max(update.step + 1, 1), schedulerStepCount)
            let completedStep = GenerationStepMapper.visibleStep(
                updateStep: update.step,
                requestedStepCount: requestedStepCount
            )
            let imageProgress = Double(schedulerStep) / Double(schedulerStepCount)
            let previewInterval = min(max(settings.previewInterval, 1), 10)
            let shouldPreview = InpaintingPreviewPolicy.shouldRender(
                enabled: settings.livePreviewEnabled,
                completedStep: completedStep,
                stepCount: requestedStepCount,
                interval: previewInterval
            )
            let renderedPreview = shouldPreview
                ? autoreleasepool {
                    LatentPreviewRenderer.render(update.currentLatentSamples.first)
                }
                : nil
            let previewImage = renderedPreview.flatMap { image in
                InpaintingImageComposer.compositeFocused(
                    original: request.image,
                    generated: image,
                    mask: request.mask,
                    cropRect: prepared.cropRect
                )
            } ?? renderedPreview
            let preview = previewImage.map { image in
                GenerationPreview(
                    cgImage: image,
                    step: completedStep,
                    stepCount: requestedStepCount,
                    imageIndex: 0
                )
            }
            if completedStep < requestedStepCount,
               completedStep.isMultiple(of: previewInterval),
               let previewImage,
               let jpegData = autoreleasepool(invoking: {
                   UIImage(cgImage: previewImage).jpegData(compressionQuality: 0.82)
               }) {
                storedPreviews.append(
                    GeneratedPreviewFrame(
                        jpegData: jpegData,
                        step: completedStep,
                        stepCount: requestedStepCount,
                        imageIndex: 0
                    )
                )
            }
            reportedProgress = min(max(imageProgress * 0.9, 0), 0.9)
            progress(
                GenerationUpdate(
                    progress: reportedProgress,
                    preview: preview,
                    activity: completedStep >= requestedStepCount
                        ? .decoding(imageIndex: 0, imageCount: 1)
                        : .denoising(
                            step: completedStep,
                            stepCount: requestedStepCount,
                            imageIndex: 0,
                            imageCount: 1
                        )
                )
            )
            return !cancellation.isCancelled
        }
        guard !cancellation.isCancelled else {
            throw GenerationError.cancelled
        }
        progress(
            GenerationUpdate(
                progress: 0.96,
                preview: nil,
                activity: .compositing
            )
        )
        let images = generated.compactMap { optionalImage -> CGImage? in
            guard let image = optionalImage else { return nil }
            return InpaintingImageComposer.compositeFocused(
                original: request.image,
                generated: image,
                mask: request.mask,
                cropRect: prepared.cropRect
            ) ?? image
        }
        guard !images.isEmpty else {
            throw GenerationError.unusableInpaintingOutput
        }
        return GenerationResult(
            images: images.enumerated().map { index, image in
                GeneratedImage(cgImage: image, imageIndex: index)
            },
            previewFrames: storedPreviews,
            resolvedSeed: settings.seed
        )
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
