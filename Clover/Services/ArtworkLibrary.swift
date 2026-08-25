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
        settings: GenerationSettings,
        inpaintingSource: CGImage? = nil,
        inpaintingMask: CGImage? = nil
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
                let inpaintingFiles = try persistInpaintingInputs(
                    source: inpaintingSource,
                    mask: inpaintingMask,
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
                        ),
                        inpaintingSourceFilename: inpaintingFiles?.source,
                        inpaintingMaskFilename: inpaintingFiles?.mask
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

    func inpaintingInput(for artwork: Artwork) -> InpaintingStudioInput? {
        guard let sourceFilename = artwork.inpaintingSourceFilename,
              let maskFilename = artwork.inpaintingMaskFilename,
              let source = UIImage(
                  contentsOfFile: directoryURL.appending(path: sourceFilename).path
              )?.cgImage,
              let mask = UIImage(
                  contentsOfFile: directoryURL.appending(path: maskFilename).path
              )?.cgImage else {
            return nil
        }
        return InpaintingStudioInput(sourceImage: source, maskImage: mask)
    }

    func previewFrames(for artwork: Artwork) -> [ArtworkPreviewFrame] {
        artwork.previewFrames
            .filter {
                $0.step > 0
                    && $0.step < artwork.generation.stepCount
                    && fileManager.fileExists(
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

    func stepsArchiveData(for artwork: Artwork) throws -> Data {
        var entries = try previewFrames(for: artwork).map { frame in
            StoredZIPArchive.Entry(
                name: String(format: "step-%04d.jpg", frame.step),
                data: try Data(contentsOf: previewURL(for: artwork, frame: frame))
            )
        }

        entries.append(
            StoredZIPArchive.Entry(
                name: String(
                    format: "step-%04d-final.png",
                    artwork.generation.stepCount
                ),
                data: try Data(contentsOf: imageURL(for: artwork))
            )
        )
        return try StoredZIPArchive.data(entries: entries)
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

    private func persistInpaintingInputs(
        source: CGImage?,
        mask: CGImage?,
        artworkID: UUID,
        artifactDirectory: URL
    ) throws -> (source: String, mask: String)? {
        guard let source, let mask,
              let sourceData = UIImage(cgImage: source).pngData(),
              let maskData = UIImage(cgImage: mask).pngData() else {
            return nil
        }

        let sourceFilename = "\(artworkID.uuidString)/inpainting-source.png"
        let maskFilename = "\(artworkID.uuidString)/inpainting-mask.png"
        try sourceData.write(
            to: artifactDirectory.appending(path: "inpainting-source.png"),
            options: .atomic
        )
        try maskData.write(
            to: artifactDirectory.appending(path: "inpainting-mask.png"),
            options: .atomic
        )
        return (sourceFilename, maskFilename)
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

struct InpaintingStudioInput: @unchecked Sendable {
    let sourceImage: CGImage
    let maskImage: CGImage
}

enum StoredZIPArchive {
    struct Entry {
        let name: String
        let data: Data
    }

    enum ArchiveError: LocalizedError {
        case invalidEntry
        case archiveTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidEntry:
                "A generation frame couldn’t be added to the ZIP."
            case .archiveTooLarge:
                "The generation timeline is too large to export as one ZIP."
            }
        }
    }

    private struct DirectoryEntry {
        let name: Data
        let checksum: UInt32
        let size: UInt32
        let offset: UInt32
    }

    static func data(entries: [Entry]) throws -> Data {
        guard entries.count <= Int(UInt16.max) else {
            throw ArchiveError.archiveTooLarge
        }

        var archive = Data()
        var directoryEntries: [DirectoryEntry] = []
        directoryEntries.reserveCapacity(entries.count)

        for entry in entries {
            guard let name = entry.name.data(using: .utf8),
                  !name.isEmpty,
                  name.count <= Int(UInt16.max),
                  entry.data.count <= Int(UInt32.max),
                  archive.count <= Int(UInt32.max) else {
                throw ArchiveError.invalidEntry
            }

            let size = UInt32(entry.data.count)
            let checksum = crc32(entry.data)
            let offset = UInt32(archive.count)

            archive.appendLittleEndian(UInt32(0x0403_4B50))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0x0021))
            archive.appendLittleEndian(checksum)
            archive.appendLittleEndian(size)
            archive.appendLittleEndian(size)
            archive.appendLittleEndian(UInt16(name.count))
            archive.appendLittleEndian(UInt16(0))
            archive.append(name)
            archive.append(entry.data)

            directoryEntries.append(
                DirectoryEntry(
                    name: name,
                    checksum: checksum,
                    size: size,
                    offset: offset
                )
            )
        }

        guard archive.count <= Int(UInt32.max) else {
            throw ArchiveError.archiveTooLarge
        }
        let directoryOffset = UInt32(archive.count)

        for entry in directoryEntries {
            archive.appendLittleEndian(UInt32(0x0201_4B50))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0x0021))
            archive.appendLittleEndian(entry.checksum)
            archive.appendLittleEndian(entry.size)
            archive.appendLittleEndian(entry.size)
            archive.appendLittleEndian(UInt16(entry.name.count))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt32(0))
            archive.appendLittleEndian(entry.offset)
            archive.append(entry.name)
        }

        let directorySize = archive.count - Int(directoryOffset)
        guard directorySize <= Int(UInt32.max),
              archive.count <= Int(UInt32.max) else {
            throw ArchiveError.archiveTooLarge
        }

        let entryCount = UInt16(directoryEntries.count)
        archive.appendLittleEndian(UInt32(0x0605_4B50))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(entryCount)
        archive.appendLittleEndian(entryCount)
        archive.appendLittleEndian(UInt32(directorySize))
        archive.appendLittleEndian(directoryOffset)
        archive.appendLittleEndian(UInt16(0))
        return archive
    }

    static func crc32(_ data: Data) -> UInt32 {
        var checksum = UInt32.max
        for byte in data {
            let index = Int((checksum ^ UInt32(byte)) & 0xFF)
            checksum = checksumTable[index] ^ (checksum >> 8)
        }
        return checksum ^ UInt32.max
    }

    private static let checksumTable: [UInt32] = (0..<256).map { value in
        var checksum = UInt32(value)
        for _ in 0..<8 {
            checksum = checksum & 1 == 1
                ? (checksum >> 1) ^ 0xEDB8_8320
                : checksum >> 1
        }
        return checksum
    }
}

private extension Data {
    mutating func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) {
            append(contentsOf: $0)
        }
    }
}

extension ArtworkLibrary {
    static var preview: ArtworkLibrary {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CloverPreview-\(UUID().uuidString)")
        return ArtworkLibrary(directoryURL: directory)
    }
}
