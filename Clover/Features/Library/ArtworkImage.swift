import SwiftUI

struct ArtworkImage: View {
    @Environment(ArtworkLibrary.self) private var library
    let artwork: Artwork

    var body: some View {
        Group {
            if let image = library.image(for: artwork) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ContentUnavailableView(
                    "Image Missing",
                    systemImage: "photo.badge.exclamationmark"
                )
            }
        }
        .clipped()
    }
}

struct ArtworkFrameImage: View {
    @Environment(ArtworkLibrary.self) private var library

    let artwork: Artwork
    let frameIndex: Int

    var body: some View {
        Group {
            if let image = library.frameImage(
                for: artwork,
                at: frameIndex
            ) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ContentUnavailableView(
                    "Image Missing",
                    systemImage: "photo.badge.exclamationmark"
                )
            }
        }
        .clipped()
    }
}

struct ArtworkTimelineControls: View {
    @Environment(ArtworkLibrary.self) private var library

    let artwork: Artwork
    @Binding var selection: Int
    var showsExportAction = false

    private var previews: [ArtworkPreviewFrame] {
        library.previewFrames(for: artwork)
    }

    private var finalIndex: Int { previews.count }

    private var selectedIndex: Int {
        min(max(selection, 0), finalIndex)
    }

    private var selectedStep: Int {
        library.frameStep(for: artwork, at: selectedIndex)
    }

    var body: some View {
        if !previews.isEmpty {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Label(
                        selectedIndex == finalIndex
                            ? "Final image"
                            : "Step \(selectedStep) of \(artwork.generation.stepCount)",
                        systemImage: selectedIndex == finalIndex
                            ? "checkmark.circle.fill"
                            : "circle.dotted"
                    )
                    .font(.subheadline.weight(.semibold))

                    Spacer()

                    Text("\(selectedIndex + 1) of \(finalIndex + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    if showsExportAction {
                        ShareLink(
                            item: library.frameURL(
                                for: artwork,
                                at: selectedIndex
                            )
                        ) {
                            Label(
                                "Export Frame",
                                systemImage: "square.and.arrow.up"
                            )
                            .labelStyle(.iconOnly)
                        }
                        .accessibilityLabel("Export selected frame")
                    }
                }

                Slider(
                    value: Binding(
                        get: { Double(selectedIndex) },
                        set: { selection = Int($0.rounded()) }
                    ),
                    in: 0...Double(finalIndex),
                    step: 1
                )
                .accessibilityLabel("Generation timeline")
                .accessibilityValue(
                    selectedIndex == finalIndex
                        ? "Final image"
                        : "Step \(selectedStep)"
                )
                .accessibilityIdentifier("artwork-timeline-slider")
            }
            .onAppear {
                selection = selectedIndex
            }
        }
    }
}
