import SwiftUI

struct OutputCanvas: View {
    let artworks: [Artwork]
    let phase: GenerationStore.Phase

    @State private var selection = 0

    var body: some View {
        Group {
            if artworks.isEmpty {
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
                ArtworkImage(artwork: artwork)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: artworks.count > 1 ? .always : .never))
    }

    private var loadingOverlay: some View {
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
        .clipShape(.rect(cornerRadius: 22))
    }
}
