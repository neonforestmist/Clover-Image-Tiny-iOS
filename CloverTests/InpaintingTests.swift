import CoreGraphics
import Foundation
import UIKit
import XCTest
@testable import Clover

final class InpaintingTests: XCTestCase {
    func testInstalledHighQualityInpaintingOnPhysicalDevice() async throws {
        guard ProcessInfo.processInfo.environment["CLOVER_DEVICE_MODEL_TEST"] == "1" else {
            throw XCTSkip("Set CLOVER_DEVICE_MODEL_TEST=1 for the opt-in physical model test.")
        }
        XCTAssertTrue(ModelStorage.hasInpaintingResources)
        XCTAssertTrue(InpaintingModelManifest.hasCurrentInstallation)
        let fixtureDirectory = ModelStorage.rootURL.appending(
            path: "Validation",
            directoryHint: .isDirectory
        )
        let fixtureSource = UIImage(
            contentsOfFile: fixtureDirectory.appending(path: "cat-source.png").path
        )?.cgImage
        let fixtureMask = UIImage(
            contentsOfFile: fixtureDirectory.appending(path: "cat-mask.png").path
        )?.cgImage
        let source = try XCTUnwrap(fixtureSource ?? makeRGBAImage(
            width: 512,
            height: 512
        ) { index in
            let x = index % 512
            let y = index / 512
            return (
                UInt8(40 + (x * 120 / 511)),
                UInt8(70 + (y * 100 / 511)),
                110,
                255
            )
        })
        let mask = try XCTUnwrap(fixtureMask ?? makeMaskImage(
            width: 512,
            height: 512,
            maskRect: CGRect(x: 144, y: 176, width: 224, height: 176)
        ))
        var settings = GenerationSettings.inpaintingDefaults
        settings.prompt = fixtureSource == nil
            ? "an orange cat"
            : "a tabby cat sitting naturally on the wooden park bench"
        settings.negativePrompt = "blurry, distorted"
        settings.stepCount = fixtureSource == nil ? 20 : 30
        settings.computeTarget = .neuralEngine
        settings.livePreviewEnabled = false

        let result = try await CoreMLInpaintingService().generate(
            resourcesURL: ModelStorage.inpaintingResourcesURL,
            request: InpaintingRequest(image: source, mask: mask),
            settings: settings,
            cancellation: GenerationCancellationToken(),
            progress: { _ in }
        )
        let image = try XCTUnwrap(result.images.first?.cgImage)
        let attachment = XCTAttachment(
            image: UIImage(cgImage: image),
            quality: .original
        )
        attachment.name = "Physical inpainting result"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(image.width, 512)
        XCTAssertEqual(image.height, 512)
        let output = try XCTUnwrap(rgbaPixels(image))
        let input = try XCTUnwrap(rgbaPixels(source))
        var changedPixels = 0
        for index in 0..<(output.count / 4) {
            let offset = index * 4
            let difference = abs(Int(output[offset]) - Int(input[offset]))
                + abs(Int(output[offset + 1]) - Int(input[offset + 1]))
                + abs(Int(output[offset + 2]) - Int(input[offset + 2]))
            if difference > 24 {
                changedPixels += 1
            }
        }
        XCTAssertGreaterThan(
            Double(changedPixels) / Double(output.count / 4),
            0.01,
            "inpainting did not materially edit the masked region"
        )
    }

    func testInpaintingSafetyCheckerIsDisabledByConstruction() {
        XCTAssertFalse(InpaintingRuntimePolicy.isSafetyCheckerEnabled)
    }

    func testStandaloneManifestDoesNotRequireSharedCloverResources() {
        let manifest = InpaintingModelManifest(
            schemaVersion: 3,
            model: "neonforestmist/Clover-Image-Tiny-Inpaint",
            baseModel: "neonforestmist/Clover-Image-Tiny",
            minimumIOS: "18.0",
            resolution: [512, 512],
            resources: manifestResources(for: ["VAEEncoder"])
                + pipelineManifestResources()
        )

        XCTAssertTrue(manifest.isValidForInstallation)
        XCTAssertFalse(
            manifest.resources.contains {
                $0.path.hasPrefix("TextEncoder.mlmodelc/")
                    || $0.path.hasPrefix("VAEDecoder.mlmodelc/")
            },
            "Shared Clover resources should not be duplicated in this manifest"
        )
    }

    func testStandaloneManifestRequiresCompleteInpaintingModels() {
        let manifest = InpaintingModelManifest(
            schemaVersion: 3,
            model: "neonforestmist/Clover-Image-Tiny-Inpaint",
            baseModel: "neonforestmist/Clover-Image-Tiny",
            minimumIOS: "18.0",
            resolution: [512, 512],
            resources: manifestResources(for: ["Unet"])
        )

        XCTAssertFalse(manifest.isValidForInstallation)
    }

    private func manifestResources(
        for modelNames: [String]
    ) -> [InpaintingModelManifest.Resource] {
        let checksum = String(repeating: "a", count: 64)
        return modelNames.flatMap { name in
            [
                InpaintingModelManifest.Resource(
                    path: "\(name).mlmodelc/metadata.json",
                    size: 1,
                    sha256: checksum
                ),
                InpaintingModelManifest.Resource(
                    path: "\(name).mlmodelc/model.mil",
                    size: 1,
                    sha256: checksum
                ),
                InpaintingModelManifest.Resource(
                    path: "\(name).mlmodelc/weights/weight.bin",
                    size: 1,
                    sha256: checksum
                ),
            ]
        }
    }

    private func pipelineManifestResources(
    ) -> [InpaintingModelManifest.Resource] {
        let checksum = String(repeating: "b", count: 64)
        return [
            "UnetPipeline.mlmodelc/metadata.json",
            "UnetPipeline.mlmodelc/model0/model.mil",
            "UnetPipeline.mlmodelc/model0/weights/0-weight.bin",
            "UnetPipeline.mlmodelc/model1/model.mil",
            "UnetPipeline.mlmodelc/model1/weights/1-weight.bin",
        ].map {
            InpaintingModelManifest.Resource(
                path: $0,
                size: 1,
                sha256: checksum
            )
        }
    }

    func testInpaintingDefaultsUseTorchSampling() {
        XCTAssertEqual(
            GenerationSettings.inpaintingDefaults.randomGenerator,
            .torch
        )
    }

    func testStepCountIsClampedToSafeOnDeviceRange() {
        XCTAssertEqual(
            InpaintingGenerationLimits.clampedStepCount(3),
            InpaintingGenerationLimits.minimumStepCount
        )
        XCTAssertEqual(
            InpaintingGenerationLimits.clampedStepCount(30),
            30
        )
        XCTAssertEqual(
            InpaintingGenerationLimits.clampedStepCount(100),
            InpaintingGenerationLimits.maximumStepCount
        )
    }

    func testCompositePreservesEveryUnmaskedPixel() throws {
        let original = try XCTUnwrap(makeRGBAImage { index in
            (
                UInt8((index * 17) % 255),
                UInt8((index * 31) % 255),
                UInt8((index * 47) % 255),
                255
            )
        })
        let generated = try XCTUnwrap(makeRGBAImage { _ in
            (12, 180, 240, 255)
        })
        let mask = try XCTUnwrap(makeMaskImage())
        let output = try XCTUnwrap(
            InpaintingImageComposer.composite(
                original: original,
                generated: generated,
                mask: mask
            )
        )

        let originalPixels = try XCTUnwrap(rgbaPixels(original))
        let generatedPixels = try XCTUnwrap(rgbaPixels(generated))
        let outputPixels = try XCTUnwrap(rgbaPixels(output))
        let maskPixels = try XCTUnwrap(grayPixels(mask))

        for index in 0..<maskPixels.count {
            let offset = index * 4
            let expected = maskPixels[index] >= 128
                ? generatedPixels[offset..<offset + 4]
                : originalPixels[offset..<offset + 4]
            XCTAssertEqual(
                Array(outputPixels[offset..<offset + 4]),
                Array(expected),
                "composite changed an unexpected pixel at index \(index)"
            )
        }
    }

    func testMaskedImageUsesNeutralConditioningInsideMask() throws {
        let original = try XCTUnwrap(makeRGBAImage { index in
            (
                UInt8((index * 17) % 255),
                UInt8((index * 31) % 255),
                UInt8((index * 47) % 255),
                255
            )
        })
        let mask = try XCTUnwrap(makeMaskImage())
        let masked = try XCTUnwrap(
            InpaintingImageComposer.maskedImage(from: original, mask: mask)
        )

        let originalPixels = try XCTUnwrap(rgbaPixels(original))
        let maskedPixels = try XCTUnwrap(rgbaPixels(masked))
        let maskPixels = try XCTUnwrap(grayPixels(mask))

        for index in 0..<maskPixels.count {
            let offset = index * 4
            if maskPixels[index] >= 128 {
                XCTAssertEqual(
                    Array(maskedPixels[offset..<offset + 4]),
                    [128, 128, 128, 255],
                    "masked pixel must normalize to zero in the Core ML VAE"
                )
            } else {
                XCTAssertEqual(
                    Array(maskedPixels[offset..<offset + 4]),
                    Array(originalPixels[offset..<offset + 4]),
                    "conditioning changed an unmasked pixel at index \(index)"
                )
            }
        }
    }

    func testConditioningMaskExpansionKeepsOriginalCenterAndAddsContext() throws {
        let mask = try XCTUnwrap(
            makeMaskImage(
                width: 64,
                height: 64,
                maskRect: CGRect(x: 28, y: 28, width: 8, height: 8)
            )
        )
        let expanded = try XCTUnwrap(
            InpaintingImageComposer.expandedConditioningMask(mask, radius: 6)
        )
        let originalPixels = try XCTUnwrap(grayPixels(mask))
        let expandedPixels = try XCTUnwrap(grayPixels(expanded))
        XCTAssertGreaterThan(
            expandedPixels.filter { $0 >= 128 }.count,
            originalPixels.filter { $0 >= 128 }.count
        )
        XCTAssertGreaterThanOrEqual(expandedPixels[32 * 64 + 32], 128)
        XCTAssertEqual(expandedPixels[0], 0)
    }

    func testSmallMaskUsesFocusedInferenceCrop() throws {
        let original = try XCTUnwrap(makeRGBAImage(width: 256, height: 256) { index in
            let value = UInt8(index % 255)
            return (value, value, value, 255)
        })
        let mask = try XCTUnwrap(makeMaskImage(width: 256, height: 256))
        let prepared = try XCTUnwrap(
            InpaintingImageComposer.prepareFocusedInput(
                image: original,
                mask: mask
            )
        )

        XCTAssertLessThan(prepared.cropRect.width, CGFloat(original.width))
        XCTAssertEqual(prepared.cropRect.width, prepared.cropRect.height)
        XCTAssertEqual(prepared.image.width, InpaintingImageComposer.inferenceSize)
        XCTAssertEqual(prepared.mask.height, InpaintingImageComposer.inferenceSize)
    }

    func testFocusedCompositeStillPreservesEveryUnmaskedPixel() throws {
        let original = try XCTUnwrap(
            makeRGBAImage(width: 256, height: 256) { index in
                (
                    UInt8((index * 17) % 255),
                    UInt8((index * 31) % 255),
                    UInt8((index * 47) % 255),
                    255
                )
            }
        )
        let mask = try XCTUnwrap(makeMaskImage(width: 256, height: 256))
        let prepared = try XCTUnwrap(
            InpaintingImageComposer.prepareFocusedInput(
                image: original,
                mask: mask
            )
        )
        let generated = try XCTUnwrap(
            makeRGBAImage(width: 512, height: 512) { _ in
                (240, 80, 20, 255)
            }
        )
        let output = try XCTUnwrap(
            InpaintingImageComposer.compositeFocused(
                original: original,
                generated: generated,
                mask: mask,
                cropRect: prepared.cropRect
            )
        )
        let originalPixels = try XCTUnwrap(rgbaPixels(original))
        let outputPixels = try XCTUnwrap(rgbaPixels(output))
        let maskPixels = try XCTUnwrap(grayPixels(mask))

        for index in 0..<maskPixels.count where maskPixels[index] < 128 {
            let offset = index * 4
            XCTAssertEqual(
                Array(outputPixels[offset..<offset + 4]),
                Array(originalPixels[offset..<offset + 4])
            )
        }
        let paintedIndex = try XCTUnwrap(
            maskPixels.firstIndex(where: { $0 >= 128 })
        )
        let paintedOffset = paintedIndex * 4
        XCTAssertEqual(
            Array(outputPixels[paintedOffset..<paintedOffset + 4]),
            [240, 80, 20, 255],
            "focused compositing must fully replace the painted region"
        )
    }

    func testInpaintingDefaultsUseStableDPMConfiguration() {
        let settings = GenerationSettings.inpaintingDefaults

        XCTAssertEqual(settings.scheduler, .dpmSolver)
        XCTAssertEqual(settings.stepCount, 20)
        XCTAssertEqual(settings.guidanceScale, 6.0)
        XCTAssertTrue(settings.livePreviewEnabled)
        XCTAssertEqual(settings.previewInterval, 5)
    }

    func testDisabledLivePreviewNeverRendersFrames() {
        for step in 1...20 {
            XCTAssertFalse(
                InpaintingPreviewPolicy.shouldRender(
                    enabled: false,
                    completedStep: step,
                    stepCount: 20,
                    interval: 5
                )
            )
        }
    }

    func testLivePreviewRendersAtIntervalAndFinalStep() {
        XCTAssertFalse(
            InpaintingPreviewPolicy.shouldRender(
                enabled: true,
                completedStep: 4,
                stepCount: 20,
                interval: 5
            )
        )
        XCTAssertTrue(
            InpaintingPreviewPolicy.shouldRender(
                enabled: true,
                completedStep: 5,
                stepCount: 20,
                interval: 5
            )
        )
        XCTAssertTrue(
            InpaintingPreviewPolicy.shouldRender(
                enabled: true,
                completedStep: 20,
                stepCount: 20,
                interval: 7
            )
        )
    }

    func testSolidBlackMaskedOutputIsRejected() throws {
        let black = try XCTUnwrap(makeRGBAImage { _ in (0, 0, 0, 255) })
        let mask = try XCTUnwrap(makeMaskImage())

        XCTAssertFalse(
            InpaintingImageComposer.hasUsableMaskedContent(
                generated: black,
                mask: mask
            )
        )
    }

    func testDetailedMaskedOutputIsAccepted() throws {
        let detailed = try XCTUnwrap(makeRGBAImage { index in
            index.isMultiple(of: 2)
                ? (12, 80, 190, 255)
                : (220, 130, 40, 255)
        })
        let mask = try XCTUnwrap(makeMaskImage())

        XCTAssertTrue(
            InpaintingImageComposer.hasUsableMaskedContent(
                generated: detailed,
                mask: mask
            )
        )
    }

    func testInpaintingDownloadSizeUsesMegabytes() {
        let manifest = InpaintingModelManifest(
            schemaVersion: 3,
            model: "test",
            baseModel: "test",
            minimumIOS: "18.0",
            resolution: [512, 512],
            resources: [
                .init(path: "Unet.mlmodelc/model.mil", size: 1_671_581_989, sha256: "test")
            ]
        )

        XCTAssertEqual(manifest.totalSizeInMegabytes, "1,672 MB")
    }

    func testInpaintingRetryStartsWithCleanStagingDirectory() throws {
        let parent = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }

        let legacyDirectory = parent.appending(
            path: InpaintingModelDownloader.legacyStagingDirectoryName,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        try Data("partial".utf8).write(
            to: legacyDirectory.appending(path: "weight.bin")
        )

        let staging = try InpaintingModelDownloader()
            .prepareStagingDirectory(parentURL: parent)

        XCTAssertEqual(
            staging.lastPathComponent,
            InpaintingModelDownloader.stagingDirectoryName
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: parent.appending(
                    path: InpaintingModelDownloader.legacyStagingDirectoryName
                ).path
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: staging.appending(path: "weight.bin")),
            Data("partial".utf8)
        )
    }

    func testInpaintingSharedResourceCopyResolvesSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        let actual = root.appending(path: "actual", directoryHint: .isDirectory)
        let linked = root.appending(path: "linked", directoryHint: .isDirectory)
        let destination = root.appending(
            path: "destination",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: actual,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("clover".utf8).write(to: actual.appending(path: "vocab.json"))
        try FileManager.default.createSymbolicLink(
            at: linked,
            withDestinationURL: actual
        )

        try InpaintingModelDownloader().linkOrCopyTree(
            from: linked,
            to: destination
        )

        XCTAssertEqual(
            try Data(contentsOf: destination.appending(path: "vocab.json")),
            Data("clover".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appending(path: "actual/vocab.json").path
            )
        )
    }

    func testInpaintingDownloadsUsePinnedCoreMLRevision() {
        let manifest = InpaintingModelManifest(
            schemaVersion: 3,
            model: "test",
            baseModel: "test",
            minimumIOS: "18.0",
            resolution: [512, 512],
            resources: [
                .init(
                    path: "UnetPipeline.mlmodelc/metadata.json",
                    remotePath: "pipeline-v1/UnetPipeline.mlmodelc/metadata.json",
                    size: 1,
                    sha256: "test"
                )
            ]
        )

        XCTAssertTrue(
            InpaintingModelManifest.remoteURL.absoluteString.contains(
                InpaintingModelManifest.repositoryRevision
            )
        )
        XCTAssertTrue(
            manifest.downloadURL(for: manifest.resources[0]).absoluteString.contains(
                InpaintingModelManifest.repositoryRevision
            )
        )
        XCTAssertTrue(
            manifest.downloadURL(for: manifest.resources[0]).absoluteString.contains(
                "pipeline-v1/UnetPipeline.mlmodelc/metadata.json"
            )
        )
    }

    func testInpaintingRevisionMarkerRejectsAnOlderInstalledModel() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let marker = directory.appending(
            path: InpaintingModelManifest.revisionMarkerName
        )
        try "old-revision\n".write(to: marker, atomically: true, encoding: .utf8)
        XCTAssertFalse(InpaintingModelManifest.isRevisionCurrent(at: directory))

        try (InpaintingModelManifest.installationVersion + "\n").write(
            to: marker,
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(InpaintingModelManifest.isRevisionCurrent(at: directory))
    }

    func testCropGeometryCentersWideImageWithoutFlippingVertically() {
        let rect = InpaintingCropGeometry.cropRect(
            imageSize: CGSize(width: 1_000, height: 500),
            canvasSize: 300,
            zoom: 1,
            offset: .zero
        )

        XCTAssertEqual(rect.origin.x, 250, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(rect.width, 500, accuracy: 0.001)
        XCTAssertEqual(rect.height, 500, accuracy: 0.001)
    }

    func testCropGeometryPositiveDownwardOffsetRevealsTopPixels() {
        let rect = InpaintingCropGeometry.cropRect(
            imageSize: CGSize(width: 500, height: 1_000),
            canvasSize: 300,
            zoom: 1,
            offset: CGSize(width: 0, height: 60)
        )

        XCTAssertEqual(rect.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 150, accuracy: 0.001)
        XCTAssertEqual(rect.height, 500, accuracy: 0.001)
    }

    func testCropOffsetIsConstrainedAtEveryZoomLevel() {
        let offset = InpaintingCropGeometry.constrainedOffset(
            CGSize(width: 500, height: -500),
            canvas: 300,
            imageSize: CGSize(width: 1_000, height: 500),
            scale: 1.2
        )

        XCTAssertEqual(offset.width, 450, accuracy: 0.001)
        XCTAssertEqual(offset.height, -150, accuracy: 0.001)
    }

    private func makeRGBAImage(
        width: Int = 8,
        height: Int = 8,
        _ pixel: (Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) -> CGImage? {
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

        for index in 0..<(width * height) {
            let value = pixel(index)
            data[index * 4] = value.0
            data[index * 4 + 1] = value.1
            data[index * 4 + 2] = value.2
            data[index * 4 + 3] = value.3
        }
        return context.makeImage()
    }

    private func makeMaskImage(
        width: Int = 8,
        height: Int = 8,
        maskRect: CGRect = CGRect(x: 2, y: 2, width: 4, height: 4)
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(maskRect)
        return context.makeImage()
    }

    private func rgbaPixels(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
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
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Array(UnsafeBufferPointer(start: data, count: width * height * 4))
    }

    private func grayPixels(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let data = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Array(UnsafeBufferPointer(start: data, count: width * height))
    }
}
