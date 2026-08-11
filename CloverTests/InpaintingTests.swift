import CoreGraphics
import XCTest
@testable import Clover

final class InpaintingTests: XCTestCase {
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
        XCTAssertTrue(settings.livePreviewEnabled)
        XCTAssertEqual(settings.previewInterval, 5)
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
            schemaVersion: 1,
            model: "test",
            baseModel: "test",
            minimumIOS: "18.0",
            resolution: [512, 512],
            resources: [
                .init(path: "Unet.mlmodelc/model.mil", size: 1_670_353_234, sha256: "test")
            ]
        )

        XCTAssertEqual(manifest.totalSizeInMegabytes, "1,670 MB")
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
