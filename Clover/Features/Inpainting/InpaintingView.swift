import PhotosUI
import SwiftUI
import UIKit

struct InpaintingView: View {
    let library: ArtworkLibrary
    let modelManager: InpaintingModelManager

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var sourceImage: CGImage?
    @State private var strokes: [MaskStroke] = []
    @State private var settings = GenerationSettings()
    @State private var presentedSheet: InpaintingSheet?
    @State private var isWorking = false
    @State private var progress = 0.0
    @State private var preview: GenerationPreview?
    @State private var errorMessage: String?
    @State private var cancellation: GenerationCancellationToken?
    @State private var generationTask: Task<Void, Never>?

    private let service = CoreMLInpaintingService()

    private enum InpaintingSheet: Identifiable {
        case settings
        case crop(InpaintingCropSource)

        var id: String {
            switch self {
            case .settings:
                "settings"
            case let .crop(source):
                "crop-\(source.id.uuidString)"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                sourceSection
                promptSection
                modelSection
            }
            .padding()
            .padding(.bottom, 18)
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Inpainting")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentedSheet = .settings
                } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("inpainting-settings-button")
                .disabled(isWorking)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionBar
        }
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .settings:
                InpaintingSettingsSheet(settings: $settings)
            case let .crop(source):
                InpaintingCropSheet(image: source.image) { croppedImage in
                    applySourceImage(croppedImage)
                }
            }
        }
        .task {
            await modelManager.refresh()
        }
        .task(id: selectedPhoto) {
            await loadSelectedPhoto()
        }
        .onDisappear {
            cancellation?.cancel()
            generationTask?.cancel()
        }
        .alert(
            "Couldn’t Inpaint",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Source image", systemImage: "photo")
                    .font(.headline)
                Spacer()
                if sourceImage != nil {
                    Button("Clear mask") {
                        strokes.removeAll()
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(isWorking)
                }
            }

            if isWorking, let preview {
                InpaintingPreviewCanvas(preview: preview)
                    .frame(height: 300)
            } else if let sourceImage {
                MaskEditor(image: sourceImage, strokes: $strokes)
                    .frame(height: 300)
                    .clipShape(.rect(cornerRadius: 16))
                    .accessibilityIdentifier("inpainting-mask-editor")
                    .allowsHitTesting(!isWorking)

                if isWorking {
                    ProgressView("Preparing preview…")
                        .frame(maxWidth: .infinity)
                }

                Text("Paint white over the area to regenerate. Unpainted pixels stay unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Working canvas: 512 × 512")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView {
                    Label("Choose an image", systemImage: "photo.badge.plus")
                } description: {
                    Text("Then paint the part Clover should replace.")
                } actions: {
                    photoPicker
                    Button("Use Clover Sample") {
                        loadSampleImage()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("inpainting-sample-button")
                }
                .frame(minHeight: 240)
                .background(
                    Color(.secondarySystemBackground),
                    in: .rect(cornerRadius: 16)
                )
            }

            if sourceImage != nil {
                photoPicker
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var photoPicker: some View {
        PhotosPicker(
            selection: $selectedPhoto,
            matching: .images,
            photoLibrary: .shared()
        ) {
            Label(
                sourceImage == nil ? "Choose Source Image" : "Replace Image",
                systemImage: "photo.on.rectangle"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(isWorking)
        .accessibilityIdentifier("inpainting-source-picker")
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prompt")
                .font(.headline)

            Button("Use greenhouse example") {
                settings.prompt = "a warm glowing glass greenhouse extension with small plants"
            }
            .font(.caption.weight(.semibold))
            .accessibilityIdentifier("inpainting-example-prompt-button")

            ZStack(alignment: .topLeading) {
                if settings.prompt.isEmpty {
                    Text("Describe what should replace the mask")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $settings.prompt)
                    .scrollContentBackground(.hidden)
                    .textInputAutocapitalization(.sentences)
                    .accessibilityLabel("Inpainting prompt")
                    .accessibilityIdentifier("inpainting-prompt-field")
            }
            .frame(height: 88)
            .padding(10)
            .background(
                Color(.secondarySystemBackground),
                in: .rect(cornerRadius: 14)
            )

            HStack(spacing: 8) {
                inpaintingPill(
                    "\(InpaintingGenerationLimits.clampedStepCount(settings.stepCount)) steps",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                inpaintingPill(String(format: "%.1f CFG", settings.guidanceScale), systemImage: "scope")
                inpaintingPill("#\(settings.seed)", systemImage: "dice")
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Inpainting model", systemImage: "shippingbox")
                .font(.headline)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: modelManager.isInstalled
                    ? "checkmark.circle.fill"
                    : "arrow.down.circle")
                    .foregroundStyle(
                        modelManager.isInstalled
                            ? .green
                            : .secondary
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(modelStatusTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(modelStatusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if case .notInstalled = modelManager.state {
                    Button("Download") {
                        modelManager.download()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("inpainting-download-button")
                } else if case .downloading = modelManager.state {
                    Button("Cancel") {
                        modelManager.cancel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(
                Color(.secondarySystemBackground),
                in: .rect(cornerRadius: 14)
            )

            if case let .downloading(progress) = modelManager.state {
                ProgressView(value: progress)
                    .tint(.cloverGreen)
                if let manifest = modelManager.manifest {
                    Text("\(manifest.totalSize.formatted(.byteCount(style: .file))) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if case let .failed(message) = modelManager.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Try Again") {
                    modelManager.download()
                }
                .font(.caption.weight(.semibold))
            }

            Link(
                "View Core ML model on Hugging Face",
                destination: URL(string: "https://huggingface.co/neonforestmist/Clover-Image-Tiny-Inpaint-CoreML")!
            )
            .font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inpainting-model-status")
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            if isWorking {
                if let preview {
                    Text("Step \(preview.step) of \(preview.stepCount)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("inpainting-preview-step")
                }
                ProgressView(value: progress)
                    .tint(.cloverGreen)
                    .accessibilityLabel("Inpainting progress")

                Button(role: .cancel) {
                    cancellation?.cancel()
                    generationTask?.cancel()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                Button {
                    startGeneration()
                } label: {
                    Label("Inpaint", systemImage: "pencil.and.outline")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canGenerate)
                .accessibilityIdentifier("inpainting-generate-button")
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(.bar)
    }

    private var canGenerate: Bool {
        sourceImage != nil
            && !strokes.isEmpty
            && !settings.trimmedPrompt.isEmpty
            && modelManager.isInstalled
    }

    private func inpaintingPill(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: .capsule)
            .foregroundStyle(.secondary)
    }

    private var modelStatusTitle: String {
        switch modelManager.state {
        case .installed:
            "Ready on device"
        case .checking:
            "Checking Hugging Face"
        case .downloading:
            "Downloading Core ML bundle"
        case .notInstalled:
            "Download the Core ML bundle"
        case .failed:
            "Download needs attention"
        }
    }

    private var modelStatusDetail: String {
        switch modelManager.state {
        case .installed:
            "9-channel SD 1.4-class pipeline"
        case .checking:
            "Fetching the verified release manifest"
        case let .downloading(progress):
            "\(Int(progress * 100))% · checksummed resources"
        case .notInstalled:
            if let manifest = modelManager.manifest {
                "\(manifest.totalSize.formatted(.byteCount(style: .file))) · verified from Hugging Face"
            } else {
                "Verified resources from Hugging Face"
            }
        case let .failed(message):
            message
        }
    }

    private func loadSelectedPhoto() async {
        guard let selectedPhoto,
              let data = try? await selectedPhoto.loadTransferable(
                type: Data.self
              ),
              let image = UIImage(data: data)?.cloverNormalized,
              let cgImage = image.cgImage else {
            return
        }

        await MainActor.run {
            if cgImage.width == 512, cgImage.height == 512 {
                applySourceImage(cgImage)
            } else {
                presentedSheet = .crop(InpaintingCropSource(image: image))
            }
        }
    }

    private func loadSampleImage() {
        guard let sample = UIImage(named: "SampleOutput")?.cgImage else {
            errorMessage = "The bundled Clover sample image is unavailable."
            return
        }
        applySourceImage(sample)
    }

    private func applySourceImage(_ image: CGImage) {
        sourceImage = image
        preview = nil
        strokes.removeAll()
    }

    private func startGeneration() {
        guard let originalImage = sourceImage,
              let mask = MaskRenderer.makeMask(
                image: originalImage,
                strokes: strokes
              ) else {
            return
        }

        var requestSettings = settings
        requestSettings.stepCount = InpaintingGenerationLimits.clampedStepCount(
            settings.stepCount
        )
        requestSettings.livePreviewEnabled = true
        requestSettings.previewInterval = 1
        let token = GenerationCancellationToken()
        cancellation = token
        isWorking = true
        progress = 0
        preview = nil
        errorMessage = nil

        generationTask = Task { @MainActor in
            do {
                let result = try await service.generate(
                    resourcesURL: ModelStorage.inpaintingResourcesURL,
                    request: InpaintingRequest(image: originalImage, mask: mask),
                    settings: requestSettings,
                    cancellation: token
                ) { update in
                    Task { @MainActor in
                        progress = update.progress
                        if let updatePreview = update.preview {
                            preview = updatePreview
                        }
                    }
                }

                guard !token.isCancelled, let image = result.images.first else {
                    throw GenerationError.cancelled
                }
                sourceImage = image.cgImage
                strokes.removeAll()
                preview = nil
                _ = try library.add(
                    images: result.images,
                    previewFrames: result.previewFrames,
                    settings: requestSettings
                )
            } catch GenerationError.cancelled {
                // Cancellation is an expected interaction.
            } catch {
                preview = nil
                errorMessage = error.localizedDescription
            }
            isWorking = false
            cancellation = nil
            generationTask = nil
        }
    }
}

private struct InpaintingPreviewCanvas: View {
    let preview: GenerationPreview

    var body: some View {
        Image(
            decorative: preview.cgImage,
            scale: 1
        )
        .resizable()
        .scaledToFit()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .clipShape(.rect(cornerRadius: 16))
        .overlay(alignment: .bottom) {
            Label(
                "Step \(preview.step) of \(preview.stepCount)",
                systemImage: "sparkles"
            )
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: .capsule)
            .padding()
        }
        .accessibilityLabel(
            "Inpainting preview, step \(preview.step) of \(preview.stepCount)"
        )
        .accessibilityIdentifier("inpainting-preview")
    }
}

private struct MaskStroke: Sendable {
    var points: [CGPoint]
}

private struct MaskEditor: View {
    let image: CGImage
    @Binding var strokes: [MaskStroke]
    @State private var activeStroke: MaskStroke?

    var body: some View {
        GeometryReader { proxy in
            let rect = aspectFitRect(
                imageSize: CGSize(width: image.width, height: image.height),
                in: proxy.size
            )

            ZStack {
                Color.black
                Image(uiImage: UIImage(cgImage: image))
                    .resizable()
                    .scaledToFit()

                Canvas { context, _ in
                    for stroke in strokes + (activeStroke.map { [$0] } ?? []) {
                        draw(stroke, in: &context, rect: rect)
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard rect.contains(value.location) else { return }
                        let point = normalizedPoint(value.location, in: rect)
                        if activeStroke == nil {
                            activeStroke = MaskStroke(points: [point])
                        } else {
                            activeStroke?.points.append(point)
                        }
                    }
                    .onEnded { _ in
                        if let activeStroke {
                            strokes.append(activeStroke)
                        }
                        activeStroke = nil
                    }
            )
        }
        .background(.black)
    }

    private func draw(
        _ stroke: MaskStroke,
        in context: inout GraphicsContext,
        rect: CGRect
    ) {
        guard let first = stroke.points.first else { return }
        var path = Path()
        path.move(to: point(first, in: rect))
        for normalized in stroke.points.dropFirst() {
            path.addLine(to: point(normalized, in: rect))
        }
        if stroke.points.count == 1 {
            path.addLine(to: point(first, in: rect))
        }
        context.stroke(
            path,
            with: .color(.white.opacity(0.82)),
            style: StrokeStyle(
                lineWidth: max(18, rect.width / 18),
                lineCap: .round,
                lineJoin: .round
            )
        )
    }

    private func normalizedPoint(_ location: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: (location.x - rect.minX) / rect.width,
            y: (location.y - rect.minY) / rect.height
        )
    }

    private func point(_ normalized: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + normalized.x * rect.width,
            y: rect.minY + normalized.y * rect.height
        )
    }

    private func aspectFitRect(imageSize: CGSize, in size: CGSize) -> CGRect {
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (size.width - fitted.width) / 2,
            y: (size.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}

private enum MaskRenderer {
    static func makeMask(
        image: CGImage,
        strokes: [MaskStroke]
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))

        // DragGesture locations and the Canvas overlay use a top-left origin.
        // CGContext's default bitmap coordinate system uses a bottom-left
        // origin, so flip only the stroke drawing coordinates to keep the
        // generated mask aligned with what the user painted on screen.
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineWidth(max(32, CGFloat(image.width) / 18))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for stroke in strokes {
            guard let first = stroke.points.first else { continue }
            context.beginPath()
            context.move(
                to: CGPoint(
                    x: first.x * CGFloat(image.width),
                    y: first.y * CGFloat(image.height)
                )
            )
            for point in stroke.points.dropFirst() {
                context.addLine(
                    to: CGPoint(
                        x: point.x * CGFloat(image.width),
                        y: point.y * CGFloat(image.height)
                    )
                )
            }
            if stroke.points.count == 1 {
                context.addArc(
                    center: CGPoint(
                        x: first.x * CGFloat(image.width),
                        y: first.y * CGFloat(image.height)
                    ),
                    radius: max(16, CGFloat(image.width) / 36),
                    startAngle: 0,
                    endAngle: 2 * .pi,
                    clockwise: false
                )
            }
            context.strokePath()
        }
        return context.makeImage()
    }
}

#Preview {
    NavigationStack {
        InpaintingView(
            library: .preview,
            modelManager: InpaintingModelManager()
        )
    }
}
