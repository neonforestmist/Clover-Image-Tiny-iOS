import SwiftUI
import UIKit

struct InpaintingCropSource: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct InpaintingCropSheet: View {
    @Environment(\.dismiss) private var dismiss

    let image: UIImage
    let onCrop: (CGImage) -> Void

    @State private var zoom = 1.0
    @State private var offset: CGSize = .zero
    @State private var canvasSize: CGFloat = 0
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var magnification = 1.0

    private let outputSize: CGFloat = 512

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("Choose the square area Clover should edit.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                GeometryReader { proxy in
                    let canvas = min(proxy.size.width, proxy.size.height)
                    let activeZoom = min(max(zoom * magnification, 1), 4)
                    let imageSize = pixelSize
                    let baseScale = max(
                        canvas / imageSize.width,
                        canvas / imageSize.height
                    )
                    let displaySize = CGSize(
                        width: imageSize.width * baseScale * activeZoom,
                        height: imageSize.height * baseScale * activeZoom
                    )
                    let currentOffset = constrainedOffset(
                        adding(offset, dragTranslation),
                        canvas: canvas,
                        imageSize: imageSize,
                        scale: baseScale * activeZoom
                    )

                    ZStack {
                        Color.black

                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: displaySize.width,
                                height: displaySize.height
                            )
                            .offset(currentOffset)

                        RoundedRectangle(cornerRadius: 18)
                            .stroke(.white.opacity(0.9), lineWidth: 2)
                            .overlay {
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(.black.opacity(0.35), lineWidth: 1)
                                    .padding(4)
                            }
                    }
                    .frame(width: canvas, height: canvas)
                    .clipShape(.rect(cornerRadius: 18))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .updating($dragTranslation) { value, state, _ in
                                state = value.translation
                            }
                            .onEnded { value in
                                offset = constrainedOffset(
                                    adding(offset, value.translation),
                                    canvas: canvas,
                                    imageSize: imageSize,
                                    scale: baseScale * zoom
                                )
                            }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .updating($magnification) { value, state, _ in
                                state = value
                            }
                            .onEnded { value in
                                zoom = min(max(zoom * value, 1), 4)
                                offset = constrainedOffset(
                                    offset,
                                    canvas: canvas,
                                    imageSize: imageSize,
                                    scale: baseScale * zoom
                                )
                            }
                    )
                    .onAppear {
                        canvasSize = canvas
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("inpainting-crop-canvas")

                HStack(spacing: 8) {
                    Label("512 × 512", systemImage: "crop")
                    Spacer()
                    Text("Pinch to zoom · Drag to move")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .padding()
            .navigationTitle("Crop Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crop") {
                        guard let croppedImage = makeCroppedImage() else { return }
                        onCrop(croppedImage)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("inpainting-crop-confirm")
                    .disabled(canvasSize == 0)
                }
            }
        }
    }

    private var pixelSize: CGSize {
        guard let cgImage = image.cgImage else {
            return CGSize(width: image.size.width, height: image.size.height)
        }
        return CGSize(width: cgImage.width, height: cgImage.height)
    }

    private func constrainedOffset(
        _ value: CGSize,
        canvas: CGFloat,
        imageSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        let maximum = CGSize(
            width: max(0, (imageSize.width * scale - canvas) / 2),
            height: max(0, (imageSize.height * scale - canvas) / 2)
        )
        return CGSize(
            width: min(max(value.width, -maximum.width), maximum.width),
            height: min(max(value.height, -maximum.height), maximum.height)
        )
    }

    private func adding(_ lhs: CGSize, _ rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }

    private func makeCroppedImage() -> CGImage? {
        guard let cgImage = image.cgImage, canvasSize > 0 else { return nil }

        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let baseScale = max(
            canvasSize / imageWidth,
            canvasSize / imageHeight
        )
        let scale = baseScale * zoom
        let cropWidth = canvasSize / scale
        let cropHeight = canvasSize / scale
        let cropX = (imageWidth - cropWidth) / 2 - offset.width / scale
        let cropY = (imageHeight - cropHeight) / 2 - offset.height / scale
        let cropRect = CGRect(
            x: cropX,
            y: cropY,
            width: cropWidth,
            height: cropHeight
        ).intersection(
            CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        )

        let coreGraphicsRect = CGRect(
            x: cropRect.minX,
            y: imageHeight - cropRect.maxY,
            width: cropRect.width,
            height: cropRect.height
        ).integral

        guard let cropped = cgImage.cropping(to: coreGraphicsRect),
              let context = CGContext(
                  data: nil,
                  width: Int(outputSize),
                  height: Int(outputSize),
                  bitsPerComponent: 8,
                  bytesPerRow: Int(outputSize) * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)
                      ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(
            cropped,
            in: CGRect(x: 0, y: 0, width: outputSize, height: outputSize)
        )
        return context.makeImage()
    }
}

extension UIImage {
    var cloverNormalized: UIImage {
        guard imageOrientation != .up else { return self }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
