import PhotosUI
import SwiftUI
import UIKit

struct InpaintingView: View {
    let library: ArtworkLibrary
    let modelManager: InpaintingModelManager
    let styleManager: ModelManager
    @Binding var settings: GenerationSettings

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var sourceImage: CGImage?
    @State private var strokes: [MaskStroke] = []
    @State private var redoStrokes: [MaskStroke] = []
    @State private var maskTool: MaskTool = .paint
    @State private var brushSize = 56.0
    @State private var presentedSheet: InpaintingSheet?
    @State private var isWorking = false
    @State private var progress = 0.0
    @State private var activity = GenerationActivity.loadingModel
    @State private var preview: GenerationPreview?
    @State private var errorMessage: String?
    @State private var cancellation: GenerationCancellationToken?
    @State private var generationTask: Task<Void, Never>?
    @State private var activeGenerationID: UUID?
    @State private var promptIsFocused = false
    @Environment(Route.self) private var route

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

    private enum ScrollTarget: Hashable {
        case prompt
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    canvas

                    if sourceImage != nil {
                        maskControls
                    }

                    generationSection
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.immediately)
            .scrollIndicators(.automatic)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Inpaint")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Parameters", systemImage: "slider.horizontal.3") {
                        presentedSheet = .settings
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("inpainting-settings-button")
                    .disabled(isWorking)
                }
            }
            .sheet(item: $presentedSheet) { destination in
                switch destination {
                case .settings:
                    InpaintingSettingsSheet(
                        settings: $settings,
                        manager: styleManager
                    )
                case let .crop(source):
                    InpaintingCropSheet(image: source.image) { croppedImage in
                        selectedPhoto = nil
                        presentedSheet = nil
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
                selectedPhoto = nil
                presentedSheet = nil
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
            .onChange(of: promptIsFocused) { _, isFocused in
                if isFocused {
                    revealPrompt(using: proxy)
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillChangeFrameNotification
                )
            ) { _ in
                if promptIsFocused {
                    revealPrompt(using: proxy)
                }
            }
        }
    }

    private func revealPrompt(using proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(ScrollTarget.prompt, anchor: .bottom)
        }
    }

    private var canvas: some View {
        ZStack {
            if isWorking, let preview {
                InpaintingPreviewCanvas(preview: preview)
            } else if let sourceImage {
                MaskEditor(
                    image: sourceImage,
                    strokes: $strokes,
                    tool: maskTool,
                    brushSize: brushSize
                ) {
                    redoStrokes.removeAll()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Mask drawing canvas")
                .accessibilityIdentifier("inpainting-mask-editor")
                .allowsHitTesting(!isWorking)
            } else {
                ContentUnavailableView {
                    Label("Choose an Image", systemImage: "photo.badge.plus")
                } description: {
                    Text("Then paint over the part Clover should replace.")
                } actions: {
                    initialPhotoPicker
                    Button("Use Clover Sample") {
                        loadSampleImage()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("inpainting-sample-button")
                }
            }

        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 680)
        .clipped()
        .background(Color(.secondarySystemBackground))
        .cloverContinuousClip(StudioMetrics.cardCorner)
        .overlay {
            RoundedRectangle(
                cornerRadius: StudioMetrics.cardCorner,
                style: .continuous
            )
            .strokeBorder(StudioPalette.hairline.opacity(0.5))
        }
    }

    private var initialPhotoPicker: some View {
        PhotosPicker(
            selection: $selectedPhoto,
            matching: .images,
            photoLibrary: .shared()
        ) {
            Label("Choose Image", systemImage: "photo.on.rectangle")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(isWorking)
        .accessibilityIdentifier("inpainting-source-picker")
    }

    private var replacePhotoPicker: some View {
        PhotosPicker(
            selection: $selectedPhoto,
            matching: .images,
            photoLibrary: .shared()
        ) {
            Label("Replace Image", systemImage: "photo.on.rectangle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isWorking)
        .accessibilityIdentifier("inpainting-replace-image")
    }

    private var maskControls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
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

            VStack(spacing: 8) {
                HStack {
                    Label("Brush Size", systemImage: "circle.dotted")
                    Spacer()
                    Text("\(Int(brushSize)) px")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)

                Slider(value: $brushSize, in: 20...120, step: 2)
                    .disabled(isWorking)
                    .accessibilityLabel("Mask brush size")
                    .accessibilityValue("\(Int(brushSize)) pixels")
                    .accessibilityIdentifier("inpainting-brush-size")
            }

            HStack(spacing: 12) {
                replacePhotoPicker

                Button(role: .destructive) {
                    strokes.removeAll()
                    redoStrokes.removeAll()
                } label: {
                    Label("Clear Mask", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(strokes.isEmpty || isWorking)
                .accessibilityIdentifier("inpainting-mask-clear")
            }
        }
    }

    private var generationSection: some View {
        VStack(spacing: 12) {
            if isWorking {
                GenerationProgressStatus(
                    progress: progress,
                    activity: activity
                )
                .accessibilityIdentifier("inpainting-generation-stage")
            }

            promptField

            if !modelManager.isInstalled, !isWorking {
                modelWarningBanner
            }

            if isWorking {
                Button(role: .cancel) {
                    cancellation?.cancel()
                    generationTask?.cancel()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("inpainting-generate-button")
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
        .frame(maxWidth: .infinity)
    }

    private var promptField: some View {
        PromptTokenEditor(
            text: inpaintingPromptBody,
            tokens: styleTriggerTokens,
            placeholder: "Describe what should replace the painted area\u{2026}",
            accessibilityLabel: "Inpainting prompt",
            accessibilityIdentifier: "inpainting-prompt-field",
            minimumHeight: 52,
            removeToken: removeStyle,
            onFocusChange: { promptIsFocused = $0 }
        )
        .id(ScrollTarget.prompt)
    }

    private var modelWarningBanner: some View {
        HStack {
            Button {
                route.open(.models)
            } label: {
                Label(
                    modelWarningInlineText,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .accessibilityIdentifier("inpainting-open-models")

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inpainting-model-status")
    }

    private var modelWarningInlineText: String {
        if !styleManager.isBaseInstalled {
            return "Download Clover from Models before inpainting."
        }
        switch modelManager.state {
        case .checking:
            return "Checking the Inpainting model."
        case .downloading:
            return "Downloading the Inpainting model."
        case .failed:
            return "The Inpainting model download failed. Open Models to retry."
        case .notInstalled:
            return "Download the Inpainting model from Models before inpainting."
        case .installed:
            return "Inpainting model ready."
        }
    }

    private var inpaintingPromptBody: Binding<String> {
        Binding(
            get: {
                settings.promptBody(
                    removingStyleTriggers: styleTriggerTokens.map(\.title)
                )
            },
            set: { body in
                settings.setPromptBody(
                    body,
                    styleTriggers: styleTriggerTokens.map(\.title)
                )
            }
        )
    }

    private var styleTriggerTokens: [PromptToken] {
        settings.styleIDs.compactMap { id in
            let trigger = styleManager.variant(id: id)?.trigger
                ?? styleManager.importedStyle(id: id)?.trigger
            return trigger.map { PromptToken(id: id, title: $0) }
        }
    }

    private func removeStyle(_ id: String) {
        let previousTokens = styleTriggerTokens
        settings.styleIDs.removeAll { $0 == id }
        settings.styleStrengths[id] = nil
        let nextTokens = styleTriggerTokens
        settings.applyStyleTriggers(
            nextTokens.map(\.title),
            replacing: previousTokens.map(\.title)
        )
        settings.persist()
    }

    private var canGenerate: Bool {
        sourceImage != nil
            && !strokes.isEmpty
            && !settings.trimmedPrompt.isEmpty
            && modelManager.isInstalled
            && settings.styleIDs.allSatisfy(styleManager.isInstalled)
    }

    private func loadSelectedPhoto() async {
        guard let selectedPhoto else { return }
        let data = try? await selectedPhoto.loadTransferable(type: Data.self)

        await MainActor.run {
            // A PhotosPickerItem remains selected until it is explicitly
            // consumed. Clear it before presenting the crop destination so
            // returning to this tab cannot load and present the same item.
            self.selectedPhoto = nil

            guard let data,
                  let image = UIImage(data: data)?.cloverNormalized,
                  let cgImage = image.cgImage else {
                errorMessage = "The selected image couldn’t be opened."
                return
            }

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
        context.blendMode = stroke.tool == .paint
            ? .normal
            : .destinationOut
        context.stroke(
            path,
            with: .color(.white),
            style: StrokeStyle(
                lineWidth: max(
                    1,
                    stroke.width / CGFloat(image.width) * rect.width
                ),
                lineCap: .round,
                lineJoin: .round
            )
        )
        context.blendMode = .normal
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
            styleManager: ModelManager(previewInstalled: true),
            settings: .constant(.inpaintingDefaults)
        )
        .environment(Route())
    }
}
