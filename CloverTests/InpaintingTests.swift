import CoreGraphics
import XCTest
@testable import Clover

final class InpaintingTests: XCTestCase {
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

    private func makeRGBAImage(
        _ pixel: (Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) -> CGImage? {
        let width = 8
        let height = 8
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

    private func makeMaskImage() -> CGImage? {
        let width = 8
        let height = 8
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
