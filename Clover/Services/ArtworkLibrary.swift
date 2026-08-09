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
        previewFrames: [GeneratedPreviewFrame] = [],
        settings: GenerationSettings
    ) throws -> [Artwork] {
        var additions: [Artwork] = []

        for generated in images {
            let id = UUID()
            let artifactDirectory = directoryURL.appending(
                path: id.uuidString,
                directoryHint: .isDirectory
            )
            let filename = "\(id.uuidString)/final.png"
            let url = directoryURL.appending(path: filename)
            guard
                let data = UIImage(cgImage: generated.cgImage).pngData()
            else {
                continue
            }

            do {
                try fileManager.createDirectory(
                    at: artifactDirectory,
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)

                let previews = try persistPreviewFrames(
                    previewFrames,
                    forImageIndex: generated.imageIndex,
                    artworkID: id,
                    artifactDirectory: artifactDirectory
                )

                additions.append(
                    Artwork(
                        id: id,
                        createdAt: .now,
                        filename: filename,
                        previewFrames: previews,
                        generation: GenerationSnapshot(
                            settings: settings,
                            imageIndex: generated.imageIndex
                        )
                    )
                )
            } catch {
                try? fileManager.removeItem(at: artifactDirectory)
                throw error
            }
        }

        artworks.insert(contentsOf: additions, at: 0)
        try persist()
        return additions
    }

    func delete(_ artwork: Artwork) {
        let artifactDirectory = directoryURL.appending(
            path: artwork.id.uuidString,
            directoryHint: .isDirectory
        )
        if fileManager.fileExists(atPath: artifactDirectory.path) {
            try? fileManager.removeItem(at: artifactDirectory)
        } else {
            try? fileManager.removeItem(at: imageURL(for: artwork))
            for preview in artwork.previewFrames {
                try? fileManager.removeItem(
                    at: previewURL(for: artwork, frame: preview)
                )
            }
        }
        artworks.removeAll { $0.id == artwork.id }
        try? persist()
    }

    func imageURL(for artwork: Artwork) -> URL {
        directoryURL.appending(path: artwork.filename)
    }

    func image(for artwork: Artwork) -> UIImage? {
        UIImage(contentsOfFile: imageURL(for: artwork).path)
    }

    func previewFrames(for artwork: Artwork) -> [ArtworkPreviewFrame] {
        artwork.previewFrames
            .filter {
                fileManager.fileExists(
                    atPath: previewURL(for: artwork, frame: $0).path
                )
            }
            .sorted { lhs, rhs in
                if lhs.step == rhs.step {
                    return lhs.filename < rhs.filename
                }
                return lhs.step < rhs.step
            }
    }

    func previewURL(
        for artwork: Artwork,
        frame: ArtworkPreviewFrame
    ) -> URL {
        directoryURL.appending(path: frame.filename)
    }

    func previewImage(
        for artwork: Artwork,
        frame: ArtworkPreviewFrame
    ) -> UIImage? {
        UIImage(
            contentsOfFile: previewURL(for: artwork, frame: frame).path
        )
    }

    func frameURL(for artwork: Artwork, at index: Int) -> URL {
        let previews = previewFrames(for: artwork)
        guard previews.indices.contains(index) else {
            return imageURL(for: artwork)
        }
        return previewURL(for: artwork, frame: previews[index])
    }

    func frameImage(for artwork: Artwork, at index: Int) -> UIImage? {
        let previews = previewFrames(for: artwork)
        guard previews.indices.contains(index) else {
            return image(for: artwork)
        }
        return previewImage(for: artwork, frame: previews[index])
    }

    func frameStep(for artwork: Artwork, at index: Int) -> Int {
        let previews = previewFrames(for: artwork)
        guard previews.indices.contains(index) else {
            return artwork.generation.stepCount
        }
        return previews[index].step
    }

    private func persistPreviewFrames(
        _ frames: [GeneratedPreviewFrame],
        forImageIndex imageIndex: Int,
        artworkID: UUID,
        artifactDirectory: URL
    ) throws -> [ArtworkPreviewFrame] {
        let selectedFrames = Dictionary(
            frames
                .filter {
                    $0.imageIndex == imageIndex && $0.step < $0.stepCount
                }
                .map { ($0.step, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        .values
        .sorted { $0.step < $1.step }

        guard !selectedFrames.isEmpty else { return [] }

        let previewsDirectory = artifactDirectory.appending(
            path: "previews",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: previewsDirectory,
            withIntermediateDirectories: true
        )

        return try selectedFrames.map { frame in
            let leafFilename = String(
                format: "step-%04d.jpg",
                frame.step
            )
            let relativeFilename = "\(artworkID.uuidString)/previews/\(leafFilename)"
            try frame.jpegData.write(
                to: directoryURL.appending(path: relativeFilename),
                options: .atomic
            )
            return ArtworkPreviewFrame(
                step: frame.step,
                stepCount: frame.stepCount,
                filename: relativeFilename
            )
        }
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
