import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class ArtworkLibrary {
    private(set) var artworks: [Artwork] = []

    private let fileManager: FileManager
    private let directoryURL: URL
    private let indexURL: URL

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.fileManager = fileManager

        let root = directoryURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "Clover", directoryHint: .isDirectory)
        self.directoryURL = root
        indexURL = root.appending(path: "artworks.json")

        if ProcessInfo.processInfo.arguments.contains("-ui-testing-reset") {
            try? fileManager.removeItem(at: root)
        }
        try? fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        restore()
    }

    func add(
        images: [GeneratedImage],
        settings: GenerationSettings
    ) throws -> [Artwork] {
        var additions: [Artwork] = []

        for (index, generated) in images.enumerated() {
            let id = UUID()
            let filename = "\(id.uuidString).png"
            let url = directoryURL.appending(path: filename)
            guard
                let data = UIImage(cgImage: generated.cgImage).pngData()
            else {
                continue
            }
            try data.write(to: url, options: .atomic)

            additions.append(
                Artwork(
                    id: id,
                    createdAt: .now,
                    filename: filename,
                    generation: GenerationSnapshot(
                        settings: settings,
                        imageIndex: index
                    )
                )
            )
        }

        artworks.insert(contentsOf: additions, at: 0)
        try persist()
        return additions
    }

    func delete(_ artwork: Artwork) {
        try? fileManager.removeItem(at: imageURL(for: artwork))
        artworks.removeAll { $0.id == artwork.id }
        try? persist()
    }

    func imageURL(for artwork: Artwork) -> URL {
        directoryURL.appending(path: artwork.filename)
    }

    func image(for artwork: Artwork) -> UIImage? {
        UIImage(contentsOfFile: imageURL(for: artwork).path)
    }

    private func restore() {
        guard
            let data = try? Data(contentsOf: indexURL),
            let decoded = try? JSONDecoder().decode([Artwork].self, from: data)
        else {
            artworks = []
            return
        }
        artworks = decoded.filter {
            fileManager.fileExists(atPath: imageURL(for: $0).path)
        }
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(artworks).write(to: indexURL, options: .atomic)
    }
}

extension ArtworkLibrary {
    static var preview: ArtworkLibrary {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CloverPreview-\(UUID().uuidString)")
        return ArtworkLibrary(directoryURL: directory)
    }
}
