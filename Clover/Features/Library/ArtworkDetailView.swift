import SwiftUI
import UniformTypeIdentifiers

struct ArtworkDetailView: View {
    let artwork: Artwork
    let library: ArtworkLibrary
    @Environment(Route.self) private var route

    @State private var saveError: String?
    @State private var savedToPhotos = false
    @State private var frameSelection: Int
    @State private var archiveDocument = ArtworkArchiveDocument()
    @State private var isExportingArchive = false

    init(artwork: Artwork, library: ArtworkLibrary) {
        self.artwork = artwork
        self.library = library
        _frameSelection = State(initialValue: artwork.previewFrames.count)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ArtworkFrameImage(
                    artwork: artwork,
                    frameIndex: frameSelection
                )
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 22, style: .continuous))

                ArtworkTimelineControls(
                    artwork: artwork,
                    selection: $frameSelection
                )

                actions
                metadata
            }
            .padding()
        }
        .environment(library)
        .navigationTitle("Image")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $isExportingArchive,
            document: archiveDocument,
            contentType: .zip,
            defaultFilename: "Clover-Steps-\(artwork.id.uuidString.prefix(8)).zip"
        ) { result in
            if case let .failure(error) = result {
                let cocoaError = error as NSError
                if cocoaError.domain != NSCocoaErrorDomain
                    || cocoaError.code != NSUserCancelledError {
                    saveError = error.localizedDescription
                }
            }
        }
        .alert(
            savedToPhotos ? "Saved to Photos" : "Couldn’t Save",
            isPresented: Binding(
                get: { savedToPhotos || saveError != nil },
                set: {
                    if !$0 {
                        savedToPhotos = false
                        saveError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            if let saveError {
                Text(saveError)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ShareLink(
                    item: library.frameURL(
                        for: artwork,
                        at: frameSelection
                    )
                ) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    saveToPhotoLibrary()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
            }

            Button {
                exportStepsArchive()
            } label: {
                Label("Download Steps as ZIP", systemImage: "arrow.down.doc")
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("download-steps-zip")

            Button {
                loadIntoStudio()
            } label: {
                Label("Load Settings into Studio", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: StudioMetrics.cardCorner))
        .controlSize(.large)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(artwork.generation.prompt)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            LabeledContent("Seed", value: "\(artwork.generation.seed)")
            LabeledContent("Steps", value: "\(artwork.generation.stepCount)")
            if !library.previewFrames(for: artwork).isEmpty {
                LabeledContent(
                    "Timeline",
                    value: "\(library.previewFrames(for: artwork).count + 1) frames"
                )
            }
            LabeledContent(
                "Guidance",
                value: artwork.generation.guidanceScale.formatted(
                    .number.precision(.fractionLength(1))
                )
            )
            LabeledContent("Scheduler", value: artwork.generation.scheduler.title)
            LabeledContent(
                "Created",
                value: artwork.createdAt.formatted(date: .abbreviated, time: .shortened)
            )
        }
        .padding(16)
        .background(
            Color(.secondarySystemBackground),
            in: .rect(cornerRadius: 16)
        )
    }

    private func loadIntoStudio() {
        if let input = library.inpaintingInput(for: artwork) {
            var settings = GenerationSettings.inpaintingDefaults
            settings.adopt(artwork.generation)
            route.openInpainting(
                with: settings,
                sourceImage: input.sourceImage,
                maskImage: input.maskImage
            )
        } else {
            var settings = GenerationSettings()
            settings.adopt(artwork.generation)
            route.openCreate(with: settings)
        }
    }

    private func saveToPhotoLibrary() {
        guard let image = library.frameImage(
            for: artwork,
            at: frameSelection
        ) else { return }
        Task {
            do {
                try await PhotoLibrarySaver.save(image)
                savedToPhotos = true
                HapticManager.success()
            } catch {
                saveError = error.localizedDescription
                HapticManager.error()
            }
        }
    }

    private func exportStepsArchive() {
        do {
            archiveDocument = ArtworkArchiveDocument(
                data: try library.stepsArchiveData(for: artwork)
            )
            isExportingArchive = true
        } catch {
            saveError = error.localizedDescription
        }
    }
}

private struct ArtworkArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
