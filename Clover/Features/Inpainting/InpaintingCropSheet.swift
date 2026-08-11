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
    @State private var showsGrid = true
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var magnification = 1.0

    private let outputSize: CGFloat = 512

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                VStack(spacing: 4) {
                    Text("Choose the square area Clover should edit.")
                        .font(.subheadline.weight(.semibold))
                    Text("Pinch or use the zoom slider, then drag to position the crop.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

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
                    let currentOffset = InpaintingCropGeometry.constrainedOffset(
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

                        if showsGrid {
                            CropGrid()
                                .padding(1)
                                .allowsHitTesting(false)
                                .transition(.opacity)
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
                                offset = InpaintingCropGeometry.constrainedOffset(
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
                                offset = InpaintingCropGeometry.constrainedOffset(
                                    offset,
                                    canvas: canvas,
                                    imageSize: imageSize,
                                    scale: baseScale * zoom
                                )
                            }
                    )
                    .onTapGesture(count: 2) {
                        resetCrop()
                    }
                    .onAppear {
                        canvasSize = canvas
                    }
                    .onChange(of: canvas) { _, newValue in
                        canvasSize = newValue
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("inpainting-crop-canvas")

                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Button {
                            adjustZoom(by: -0.25)
                        } label: {
                            Label("Zoom out", systemImage: "minus.magnifyingglass")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.bordered)
                        .disabled(zoom <= 1)

                        Slider(value: zoomBinding, in: 1...4, step: 0.05)
                            .accessibilityLabel("Crop zoom")
                            .accessibilityValue(zoomPercentage)
                            .accessibilityIdentifier("inpainting-crop-zoom")

                        Button {
                            adjustZoom(by: 0.25)
                        } label: {
                            Label("Zoom in", systemImage: "plus.magnifyingglass")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.bordered)
                        .disabled(zoom >= 4)

                        Text(zoomPercentage)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }

                    HStack(spacing: 14) {
                        Label("512 × 512", systemImage: "crop")
                        Toggle("Grid", isOn: $showsGrid)
                            .toggleStyle(.button)
                            .accessibilityIdentifier("inpainting-crop-grid")
                        Spacer()
                        Button("Reset", systemImage: "arrow.counterclockwise") {
                            resetCrop()
                        }
                        .disabled(zoom == 1 && offset == .zero)
                        .accessibilityIdentifier("inpainting-crop-reset")
                    }
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
                    Button("Use Crop") {
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

    private func adding(_ lhs: CGSize, _ rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }

    private var zoomPercentage: String {
        "\(Int((zoom * 100).rounded()))%"
    }

    private var zoomBinding: Binding<Double> {
        Binding(
            get: { zoom },
            set: { setZoom($0) }
        )
    }

    private func adjustZoom(by delta: Double) {
        setZoom(zoom + delta)
    }

    private func setZoom(_ proposedZoom: Double) {
        let nextZoom = min(max(proposedZoom, 1), 4)
        zoom = nextZoom
        guard canvasSize > 0 else { return }
        let baseScale = max(
            canvasSize / pixelSize.width,
            canvasSize / pixelSize.height
        )
        offset = InpaintingCropGeometry.constrainedOffset(
            offset,
            canvas: canvasSize,
            imageSize: pixelSize,
            scale: baseScale * nextZoom
        )
    }

    private func resetCrop() {
        withAnimation(.snappy) {
            zoom = 1
            offset = .zero
        }
    }

    private func makeCroppedImage() -> CGImage? {
        guard let cgImage = image.cgImage, canvasSize > 0 else { return nil }

        let coreGraphicsRect = InpaintingCropGeometry.cropRect(
            imageSize: CGSize(width: cgImage.width, height: cgImage.height),
            canvasSize: canvasSize,
            zoom: zoom,
            offset: offset
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

enum InpaintingCropGeometry {
    static func constrainedOffset(
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

    /// Returns a top-left-origin source rectangle matching the way UIImage is
    /// displayed in the crop canvas and consumed by CGImage.cropping(to:).
    static func cropRect(
        imageSize: CGSize,
        canvasSize: CGFloat,
        zoom: Double,
        offset: CGSize
    ) -> CGRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              canvasSize > 0 else {
            return .zero
        }
        let clampedZoom = min(max(zoom, 1), 4)
        let baseScale = max(
            canvasSize / imageSize.width,
            canvasSize / imageSize.height
        )
        let scale = baseScale * clampedZoom
        let cropSize = CGSize(
            width: canvasSize / scale,
            height: canvasSize / scale
        )
        return CGRect(
            x: (imageSize.width - cropSize.width) / 2 - offset.width / scale,
            y: (imageSize.height - cropSize.height) / 2 - offset.height / scale,
            width: cropSize.width,
            height: cropSize.height
        ).intersection(
            CGRect(origin: .zero, size: imageSize)
        )
    }
}

private struct CropGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                let x = size.width * fraction
                let y = size.height * fraction
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(
                path,
                with: .color(.white.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1, dash: [5, 4])
            )
        }
        .accessibilityHidden(true)
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
