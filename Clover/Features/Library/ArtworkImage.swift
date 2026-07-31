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
