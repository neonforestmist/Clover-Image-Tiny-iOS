import SwiftUI

struct ArtworkDetailView: View {
    let artwork: Artwork
    let library: ArtworkLibrary

    @State private var saveError: String?
    @State private var savedToPhotos = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ArtworkImage(artwork: artwork)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 18))

                actions
                metadata
            }
            .padding()
        }
        .environment(library)
        .navigationTitle("Image")
        .navigationBarTitleDisplayMode(.inline)
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
        HStack {
            ShareLink(item: library.imageURL(for: artwork)) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                saveToPhotoLibrary()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(artwork.generation.prompt)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            LabeledContent("Seed", value: "\(artwork.generation.seed)")
            LabeledContent("Steps", value: "\(artwork.generation.stepCount)")
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

    private func saveToPhotoLibrary() {
        guard let image = library.image(for: artwork) else { return }
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
}
