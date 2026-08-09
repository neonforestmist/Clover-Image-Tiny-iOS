import SwiftUI

struct OutputCanvas: View {
    @Environment(ArtworkLibrary.self) private var library

    let artworks: [Artwork]
    let phase: GenerationStore.Phase
    let preview: GenerationPreview?

    @State private var selection = 0
    @State private var frameSelection = 0

    var body: some View {
        VStack(spacing: 12) {
            canvas

            if !phase.isWorking, let currentArtwork {
                ArtworkTimelineControls(
                    artwork: currentArtwork,
                    selection: $frameSelection,
                    showsExportAction: true
                )
                .padding(.horizontal, 4)
            }
        }
        .onChange(of: artworkIDs, initial: true) {
            selection = 0
            selectFinalFrame()
        }
        .onChange(of: selection) {
            selectFinalFrame()
        }
    }

    private var canvas: some View {
        Group {
            if let preview, phase.isWorking {
                previewImage(preview)
            } else if artworks.isEmpty {
                emptyState
            } else {
                artworkPager
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .clipShape(.rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(.separator.opacity(0.35))
        }
        .overlay {
            if phase.isWorking {
                loadingOverlay
            }
        }
        .accessibilityIdentifier("output-canvas")
    }

    private var artworkIDs: [UUID] {
        artworks.map(\.id)
    }

    private var currentArtwork: Artwork? {
        guard artworks.indices.contains(selection) else { return nil }
        return artworks[selection]
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Ready to Create", systemImage: "photo.badge.plus")
        } description: {
            Text("Describe an image, tune the parameters, then generate on device.")
        }
    }

    private var artworkPager: some View {
        TabView(selection: $selection) {
            ForEach(Array(artworks.enumerated()), id: \.element.id) { index, artwork in
                ArtworkFrameImage(
                    artwork: artwork,
                    frameIndex: index == selection ? frameSelection : 0
                )
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

    private var loadingOverlay: some View {
        Group {
            if let preview {
                VStack {
                    Spacer()
                    Label(
                        "Image \(preview.imageIndex + 1) · Step \(preview.step) of \(preview.stepCount)",
                        systemImage: "sparkles"
                    )
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding()
                }
            } else {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)

                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text(phase == .preparing ? "Preparing model…" : "Creating locally…")
                            .font(.subheadline.weight(.medium))
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: 22))
    }
}
