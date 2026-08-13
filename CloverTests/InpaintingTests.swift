import CoreGraphics
import XCTest
@testable import Clover

final class InpaintingTests: XCTestCase {
    func testInpaintingSafetyCheckerIsDisabledByConstruction() {
        XCTAssertFalse(InpaintingRuntimePolicy.isSafetyCheckerEnabled)
    }

    func testInpaintingRetriesThreeDeterministicSeeds() {
        XCTAssertEqual(InpaintingRuntimePolicy.generationAttemptCount, 3)
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
            schemaVersion: 2,
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

    func testInpaintingDownloadsUsePinnedCoreMLRevision() {
        let manifest = InpaintingModelManifest(
            schemaVersion: 2,
            model: "test",
            baseModel: "test",
            minimumIOS: "18.0",
            resolution: [512, 512],
            resources: [
                .init(
                    path: "Unet.mlmodelc/model.mil",
                    remotePath: "hq-v3/Unet.mlmodelc/model.mil",
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
                "hq-v3/Unet.mlmodelc/model.mil"
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

        try (InpaintingModelManifest.repositoryRevision + "\n").write(
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
        height: Int = 8
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
        context.fill(CGRect(x: 2, y: 2, width: 4, height: 4))
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
