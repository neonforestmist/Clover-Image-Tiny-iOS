import SwiftUI

struct LibraryView: View {
    let library: ArtworkLibrary
    @Environment(Route.self) private var route
    @State private var query = ""

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    private var filtered: [Artwork] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return library.artworks }
        return library.artworks.filter {
            $0.generation.prompt.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        Group {
            if library.artworks.isEmpty {
                ContentUnavailableView(
                    "No Images Yet",
                    systemImage: "square.grid.2x2",
                    description: Text("Images you generate appear here and stay on this device.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(filtered) { artwork in
                            NavigationLink(value: artwork.id) {
                                ArtworkImage(artwork: artwork)
                                    .aspectRatio(1, contentMode: .fill)
                                    .cloverContinuousClip(StudioMetrics.cardCorner)
                                    .overlay(alignment: .bottomLeading) {
                                        if !artwork.previewFrames.isEmpty {
                                            Image(systemName: "film.stack.fill")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.white)
                                                .padding(5)
                                                .background(.black.opacity(0.45), in: .circle)
                                                .padding(6)
                                        }
                                    }
                            }
                            .accessibilityIdentifier("artwork-tile")
                            .buttonStyle(.plain)
                            .contextMenu {
                                ShareLink(item: library.imageURL(for: artwork))
                                Button("Load Settings into Studio", systemImage: "slider.horizontal.3") {
                                    loadIntoStudio(artwork)
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    library.delete(artwork)
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .environment(library)
        .navigationTitle("Library")
        .searchable(text: $query, prompt: "Search prompts")
        .navigationDestination(for: UUID.self) { id in
            if let artwork = library.artworks.first(where: { $0.id == id }) {
                ArtworkDetailView(artwork: artwork, library: library)
            }
        }
    }

    private func loadIntoStudio(_ artwork: Artwork) {
        var settings = GenerationSettings()
        settings.adopt(artwork.generation)
        route.openCreate(with: settings)
    }
}

#Preview {
    NavigationStack {
        LibraryView(library: .preview)
            .environment(Route())
    }
}
