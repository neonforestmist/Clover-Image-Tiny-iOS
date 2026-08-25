import Foundation

struct ArtworkPreviewFrame: Codable, Identifiable, Sendable, Equatable {
    let step: Int
    let stepCount: Int
    let filename: String

    var id: String { filename }
}

struct Artwork: Codable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let filename: String
    let previewFrames: [ArtworkPreviewFrame]
    let generation: GenerationSnapshot
    /// Present for inpainting results saved by current releases. Older
    /// artworks decode these as nil and continue to open in Create.
    let inpaintingSourceFilename: String?
    let inpaintingMaskFilename: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case filename
        case previewFrames
        case generation
        case inpaintingSourceFilename
        case inpaintingMaskFilename
    }

    init(
        id: UUID,
        createdAt: Date,
        filename: String,
        previewFrames: [ArtworkPreviewFrame] = [],
        generation: GenerationSnapshot,
        inpaintingSourceFilename: String? = nil,
        inpaintingMaskFilename: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.filename = filename
        self.previewFrames = previewFrames
        self.generation = generation
        self.inpaintingSourceFilename = inpaintingSourceFilename
        self.inpaintingMaskFilename = inpaintingMaskFilename
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        filename = try container.decode(String.self, forKey: .filename)
        previewFrames = try container.decodeIfPresent(
            [ArtworkPreviewFrame].self,
            forKey: .previewFrames
        ) ?? []
        generation = try container.decode(
            GenerationSnapshot.self,
            forKey: .generation
        )
        inpaintingSourceFilename = try container.decodeIfPresent(
            String.self,
            forKey: .inpaintingSourceFilename
        )
        inpaintingMaskFilename = try container.decodeIfPresent(
            String.self,
            forKey: .inpaintingMaskFilename
        )
    }
}
