import Foundation

struct Artwork: Codable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let filename: String
    let generation: GenerationSnapshot
}
