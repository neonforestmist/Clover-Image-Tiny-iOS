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

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case filename
        case previewFrames
        case generation
    }

    init(
        id: UUID,
        createdAt: Date,
        filename: String,
        previewFrames: [ArtworkPreviewFrame] = [],
        generation: GenerationSnapshot
    ) {
        self.id = id
        self.createdAt = createdAt
        self.filename = filename
        self.previewFrames = previewFrames
        self.generation = generation
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
    }
}
