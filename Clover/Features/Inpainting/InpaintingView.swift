import PhotosUI
import SwiftUI
import UIKit

struct InpaintingView: View {
    let library: ArtworkLibrary
    let modelManager: InpaintingModelManager
    let styleManager: ModelManager

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var sourceImage: CGImage?
    @State private var strokes: [MaskStroke] = []
    @State private var redoStrokes: [MaskStroke] = []
    @State private var maskTool: MaskTool = .paint
    @State private var brushSize = 56.0
    @State private var settings = GenerationSettings.inpaintingDefaults
    @State private var presentedSheet: InpaintingSheet?
    @State private var isWorking = false
    @State private var progress = 0.0
    @State private var activity = GenerationActivity.loadingModel
    @State private var preview: GenerationPreview?
    @State private var errorMessage: String?
    @State private var cancellation: GenerationCancellationToken?
    @State private var generationTask: Task<Void, Never>?
    @State private var activeGenerationID: UUID?

    private let service = CoreMLInpaintingService()

    private enum InpaintingSheet: Identifiable {
        case settings
        case styles
        case crop(InpaintingCropSource)

        var id: String {
            switch self {
            case .settings:
                "settings"
            case .styles:
                "styles"
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
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .settings:
                InpaintingSettingsSheet(settings: $settings)
            case .styles:
                ModelPickerView(
                    settings: $settings,
                    manager: styleManager
                )
            case let .crop(source):
                InpaintingCropSheet(image: source.image) { croppedImage in
                    applySourceImage(croppedImage)
                }
            }
        }
        .task {
            await modelManager.refresh()
            await styleManager.refreshCatalog()
        }
        .task(id: selectedPhoto) {
            await loadSelectedPhoto()
        }
        .onDisappear {
            activeGenerationID = nil
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
            }

            if isWorking, let preview {
                InpaintingPreviewCanvas(preview: preview)
                    .frame(height: 300)

                HStack(spacing: 7) {
                    Image(systemName: "photo")
                    Text("Live preview")
                    Spacer()
                    Text(
                        preview.step >= preview.stepCount
                            ? "Finishing image…"
                            : "Step \(preview.step) of \(preview.stepCount)"
                    )
                        .monospacedDigit()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("inpainting-preview-step")
            } else if let sourceImage {
                MaskEditor(
                    image: sourceImage,
                    strokes: $strokes,
                    tool: maskTool,
                    brushSize: brushSize
                ) {
                    redoStrokes.removeAll()
                }
                    .frame(height: 300)
                    .clipShape(.rect(cornerRadius: 16))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Mask drawing canvas")
                    .accessibilityIdentifier("inpainting-mask-editor")
                    .allowsHitTesting(!isWorking)

                maskControls

                if isWorking {
                    ProgressView(
                        settings.livePreviewEnabled
                            ? "Preparing preview…"
                            : "Generating without live previews…"
                    )
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

    private var maskControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Picker("Mask tool", selection: $maskTool) {
                    ForEach(MaskTool.allCases) { tool in
                        Label(tool.title, systemImage: tool.systemImage)
                            .tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("inpainting-mask-tool-picker")

                Button {
                    undoMaskStroke()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .disabled(strokes.isEmpty || isWorking)
                .accessibilityIdentifier("inpainting-mask-undo")

                Button {
                    redoMaskStroke()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .disabled(redoStrokes.isEmpty || isWorking)
                .accessibilityIdentifier("inpainting-mask-redo")
            }

            HStack(spacing: 10) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .accessibilityHidden(true)
                Slider(value: $brushSize, in: 20...120, step: 2)
                    .disabled(isWorking)
                    .accessibilityLabel("Mask brush size")
                    .accessibilityValue("\(Int(brushSize)) pixels")
                    .accessibilityIdentifier("inpainting-brush-size")
                Image(systemName: "circle.fill")
                    .font(.system(size: 18))
                    .accessibilityHidden(true)
                Text("\(Int(brushSize)) px")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }

            HStack {
                Label(
                    maskTool == .paint ? "Painting edit area" : "Erasing mask",
                    systemImage: maskTool.systemImage
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Spacer()
                Button("Clear mask", role: .destructive) {
                    strokes.removeAll()
                    redoStrokes.removeAll()
                }
                .font(.caption.weight(.semibold))
                .disabled(strokes.isEmpty || isWorking)
                .accessibilityIdentifier("inpainting-mask-clear")
            }
        }
        .padding(12)
        .background(
            Color(.secondarySystemBackground),
            in: .rect(cornerRadius: 14)
        )
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

            Button("Use cat example") {
                settings.prompt = "a small orange tabby cat sitting naturally in the doorway, detailed photography"
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
                    Button(downloadButtonTitle) {
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
                    Text("\(manifest.totalSizeInMegabytes) total")
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

            Button {
                presentedSheet = .styles
            } label: {
                Label(
                    settings.styleIDs.isEmpty
                        ? "Add Styles"
                        : "Edit \(settings.styleIDs.count) Active \(settings.styleIDs.count == 1 ? "Style" : "Styles")",
                    systemImage: "paintpalette"
                )
            }
            .buttonStyle(.bordered)
            .disabled(isWorking)
            .accessibilityIdentifier("inpainting-style-picker")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inpainting-model-status")
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            if isWorking {
                GenerationProgressStatus(
                    progress: progress,
                    activity: activity
                )
                .accessibilityIdentifier("inpainting-generation-stage")

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
                PrimaryGenerationButton(
                    title: "Inpaint",
                    systemImage: "pencil.and.outline",
                    isEnabled: canGenerate
                ) {
                    startGeneration()
                }
                .accessibilityIdentifier("inpainting-generate-button")
            }
        }
        .padding(.top, 4)
    }

    private var canGenerate: Bool {
        sourceImage != nil
            && !strokes.isEmpty
            && !settings.trimmedPrompt.isEmpty
            && modelManager.isInstalled
            && settings.styleIDs.allSatisfy(styleManager.isInstalled)
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
            "Optional inpainting download"
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
            if let manifest = modelManager.manifest {
                "\(Int(progress * 100))% of \(manifest.totalSizeInMegabytes) · checksummed"
            } else {
                "\(Int(progress * 100))% · checksummed resources"
            }
        case .notInstalled:
            if let manifest = modelManager.manifest {
                "\(manifest.totalSizeInMegabytes) · downloaded only when you enable Inpainting"
            } else {
                "Downloaded only when you enable Inpainting"
            }
        case let .failed(message):
            message
        }
    }

    private var downloadButtonTitle: String {
        guard let manifest = modelManager.manifest else { return "Download" }
        return "Download \(manifest.totalSizeInMegabytes)"
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
        redoStrokes.removeAll()
        maskTool = .paint
    }

    private func undoMaskStroke() {
        guard let stroke = strokes.popLast() else { return }
        redoStrokes.append(stroke)
    }

    private func redoMaskStroke() {
        guard let stroke = redoStrokes.popLast() else { return }
        strokes.append(stroke)
    }

    private func startGeneration() {
        guard let originalImage = sourceImage else {
            return
        }
        guard let mask = MaskRenderer.makeMask(
            image: originalImage,
            strokes: strokes
        ) else {
            errorMessage = "Paint at least one area for Clover to replace. A fully erased mask has nothing to edit."
            return
        }

        var requestSettings = settings
        requestSettings.stepCount = InpaintingGenerationLimits.clampedStepCount(
            settings.stepCount
        )
        requestSettings.scheduler = .dpmSolver
        requestSettings.previewInterval = min(
            max(settings.previewInterval, 1),
            min(requestSettings.stepCount, 10)
        )
        let token = GenerationCancellationToken()
        let generationID = UUID()
        cancellation = token
        activeGenerationID = generationID
        isWorking = true
        progress = 0
        activity = .loadingModel
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
                        guard activeGenerationID == generationID else { return }
                        progress = update.progress
                        activity = update.activity
                        if let updatePreview = update.preview {
                            preview = updatePreview
                        }
                    }
                }

                guard activeGenerationID == generationID,
                      !token.isCancelled,
                      let image = result.images.first else {
                    throw GenerationError.cancelled
                }
                sourceImage = image.cgImage
                strokes.removeAll()
                redoStrokes.removeAll()
                preview = nil
                var persistedSettings = requestSettings
                if let resolvedSeed = result.resolvedSeed {
                    persistedSettings.seed = resolvedSeed
                    settings.seed = resolvedSeed
                }
                progress = 0.98
                activity = .saving
                _ = try library.add(
                    images: result.images,
                    previewFrames: result.previewFrames,
                    settings: persistedSettings
                )
            } catch GenerationError.cancelled {
                // Cancellation is an expected interaction.
            } catch {
                guard activeGenerationID == generationID else { return }
                preview = nil
                errorMessage = error.localizedDescription
            }
            guard activeGenerationID == generationID else { return }
            isWorking = false
            cancellation = nil
            generationTask = nil
            activeGenerationID = nil
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
        .accessibilityLabel(
            "Inpainting preview, step \(preview.step) of \(preview.stepCount)"
        )
        .accessibilityIdentifier("inpainting-preview")
    }
}

private enum MaskTool: String, CaseIterable, Identifiable, Sendable {
    case paint
    case erase

    var id: Self { self }

    var title: String {
        switch self {
        case .paint: "Paint"
        case .erase: "Erase"
        }
    }

    var systemImage: String {
        switch self {
        case .paint: "paintbrush.fill"
        case .erase: "eraser.fill"
        }
    }
}

private struct MaskStroke: Sendable {
    var points: [CGPoint]
    var width: CGFloat
    var tool: MaskTool
}

private struct MaskEditor: View {
    let image: CGImage
    @Binding var strokes: [MaskStroke]
    let tool: MaskTool
    let brushSize: Double
    let onCommit: () -> Void
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
                            activeStroke = MaskStroke(
                                points: [point],
                                width: brushSize,
                                tool: tool
                            )
                        } else {
                            activeStroke?.points.append(point)
                        }
                    }
                    .onEnded { _ in
                        if let activeStroke {
                            strokes.append(activeStroke)
                            onCommit()
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
        context.drawLayer { layer in
            layer.blendMode = stroke.tool == .paint
                ? .normal
                : .destinationOut
            layer.stroke(
                path,
                with: .color(.white.opacity(0.82)),
                style: StrokeStyle(
                    lineWidth: max(
                        1,
                        stroke.width / CGFloat(image.width) * rect.width
                    ),
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
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
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for stroke in strokes {
            guard let first = stroke.points.first else { continue }
            context.setStrokeColor(
                gray: stroke.tool == .paint ? 1 : 0,
                alpha: 1
            )
            context.setFillColor(
                gray: stroke.tool == .paint ? 1 : 0,
                alpha: 1
            )
            context.setLineWidth(stroke.width)
            if stroke.points.count == 1 {
                context.fillEllipse(
                    in: CGRect(
                        x: first.x * CGFloat(image.width) - stroke.width / 2,
                        y: first.y * CGFloat(image.height) - stroke.width / 2,
                        width: stroke.width,
                        height: stroke.width
                    )
                )
                continue
            }
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
            context.strokePath()
        }
        guard let mask = context.makeImage(), containsPaint(mask) else {
            return nil
        }
        return mask
    }

    private static func containsPaint(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return false
        }
        let count = CFDataGetLength(data)
        return (0..<count).contains { bytes[$0] > 0 }
    }
}

#Preview {
    NavigationStack {
        InpaintingView(
            library: .preview,
            modelManager: InpaintingModelManager(),
            styleManager: ModelManager(previewInstalled: true)
        )
    }
}
