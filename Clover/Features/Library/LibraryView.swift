import SwiftUI

struct LibraryView: View {
    let library: ArtworkLibrary

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

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
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(library.artworks) { artwork in
                            NavigationLink(value: artwork.id) {
                                ArtworkImage(artwork: artwork)
                                    .aspectRatio(1, contentMode: .fill)
                            }
                            .accessibilityIdentifier("artwork-tile")
                            .buttonStyle(.plain)
                            .contextMenu {
                                ShareLink(item: library.imageURL(for: artwork))
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    library.delete(artwork)
                                }
                            }
                        }
                    }
                }
            }
        }
        .environment(library)
        .navigationTitle("Library")
        .navigationDestination(for: UUID.self) { id in
            if let artwork = library.artworks.first(where: { $0.id == id }) {
                ArtworkDetailView(artwork: artwork, library: library)
            }
        }
    }
}

#Preview {
    NavigationStack {
        LibraryView(library: .preview)
    }
}
