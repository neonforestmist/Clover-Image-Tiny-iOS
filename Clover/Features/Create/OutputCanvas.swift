import SwiftUI

struct OutputCanvas: View {
    @Environment(ArtworkLibrary.self) private var library

    let artworks: [Artwork]
    let phase: GenerationStore.Phase
    let preview: GenerationPreview?
    let activity: GenerationActivity

    @State private var selection = 0
    @Binding var frameSelection: Int

    init(
        artworks: [Artwork],
        phase: GenerationStore.Phase,
        preview: GenerationPreview?,
        activity: GenerationActivity,
        frameSelection: Binding<Int> = .constant(0)
    ) {
        self.artworks = artworks
        self.phase = phase
        self.preview = preview
        self.activity = activity
        _frameSelection = frameSelection
    }

    var body: some View {
        ZStack {
            if phase.isWorking || !artworks.isEmpty {
                canvasContent
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Checkerboard())
                    .cloverContinuousClip(StudioMetrics.canvasCorner)
                    .padding(16)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("output-canvas")
        .onChange(of: artworkIDs, initial: true) {
            selection = 0
            selectFinalFrame()
        }
        .onChange(of: selection) {
            selectFinalFrame()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Ready to Create", systemImage: "photo.badge.plus")
        } description: {
            Text("Enter a prompt below. Generation runs entirely on this device.")
        }
        .padding(32)
    }

    @ViewBuilder
    private var canvasContent: some View {
        ZStack {
            if let preview, phase.isWorking {
                previewImage(preview)
            } else if !artworks.isEmpty {
                artworkPager
                    .transition(.opacity.animation(.easeIn(duration: 0.25)))
            }

            if phase.isWorking {
                loadingOverlay
            }
        }
    }

    private var artworkIDs: [UUID] {
        artworks.map(\.id)
    }

    private var currentArtwork: Artwork? {
        guard artworks.indices.contains(selection) else { return nil }
        return artworks[selection]
    }

    private var artworkPager: some View {
        TabView(selection: $selection) {
            ForEach(Array(artworks.enumerated()), id: \.element.id) { index, artwork in
                ArtworkFrameImage(
                    artwork: artwork,
                    frameIndex: index == selection ? frameSelection : 0
                )
                .scaledToFit()
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: artworks.count > 1 ? .always : .never))
    }

    private func selectFinalFrame() {
        guard let currentArtwork else {
            frameSelection = 0
            return
        }
        frameSelection = library.previewFrames(for: currentArtwork).count
    }

    private func previewImage(_ preview: GenerationPreview) -> some View {
        Image(decorative: preview.cgImage, scale: 1)
            .resizable()
            .scaledToFit()
            .accessibilityLabel(
                "Generation preview, image \(preview.imageIndex + 1), step \(preview.step) of \(preview.stepCount)"
            )
            .accessibilityIdentifier("generation-preview")
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        if preview == nil {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.accentColor)
                Text(phase == .preparing ? "Preparing model…" : activity.title)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .capsule)
            .accessibilityElement(children: .combine)
        } else {
            VStack {
                Spacer()
                Label(activity.title, systemImage: "sparkles")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.bottom, 14)
            }
        }
    }
}
