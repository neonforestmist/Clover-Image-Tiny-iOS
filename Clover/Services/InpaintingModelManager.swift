import CryptoKit
import Foundation
import Observation

struct InpaintingModelManifest: Codable, Sendable {
    struct Resource: Codable, Sendable {
        let path: String
        let size: Int64
        let sha256: String
    }

    let schemaVersion: Int
    let model: String
    let baseModel: String
    let minimumIOS: String
    let resolution: [Int]
    let resources: [Resource]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case model
        case baseModel = "base_model"
        case minimumIOS = "minimum_ios"
        case resolution
        case resources
    }

    static let repositoryRevision = "4ac712613e1599b616fa2ca94e24c06bfe110fca"
    static let revisionMarkerName = ".clover-inpainting-revision"

    static let remoteURL = URL(
        string: "https://huggingface.co/neonforestmist/Clover-Image-Tiny-Inpaint-CoreML/resolve/\(repositoryRevision)/manifest.json"
    )!

    static func isRevisionCurrent(at resourcesURL: URL) -> Bool {
        let markerURL = resourcesURL.appending(path: revisionMarkerName)
        guard let storedRevision = try? String(
            contentsOf: markerURL,
            encoding: .utf8
        ) else {
            return false
        }
        return storedRevision.trimmingCharacters(in: .whitespacesAndNewlines)
            == repositoryRevision
    }

    static var hasCurrentInstallation: Bool {
        ModelStorage.hasInpaintingResources
            && isRevisionCurrent(at: ModelStorage.inpaintingResourcesURL)
    }

    var totalSize: Int64 {
        resources.reduce(0) { $0 + $1.size }
    }

    var totalSizeInMegabytes: String {
        let megabytes = Int((Double(totalSize) / 1_000_000).rounded())
        return "\(megabytes.formatted()) MB"
    }

    func downloadURL(for resource: Resource) -> URL {
        var components = URLComponents(
            string: "https://huggingface.co/neonforestmist/Clover-Image-Tiny-Inpaint-CoreML/resolve/\(Self.repositoryRevision)/\(resource.path)"
        )!
        components.queryItems = [
            URLQueryItem(name: "download", value: "true")
        ]
        return components.url!
    }
}

enum InpaintingModelError: LocalizedError {
    case invalidManifest
    case sizeMismatch(String)
    case checksumMismatch(String)
    case incompletePackage

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            "Hugging Face returned an invalid inpainting model manifest."
        case let .sizeMismatch(path):
            "The inpainting download size did not match for \(path)."
        case let .checksumMismatch(path):
            "The inpainting download checksum did not match for \(path)."
        case .incompletePackage:
            "The inpainting model package is incomplete."
        }
    }
}

final class InpaintingModelDownloader: Sendable {
    func fetchManifest() async throws -> InpaintingModelManifest {
        let (data, response) = try await URLSession.shared.data(
            from: InpaintingModelManifest.remoteURL
        )
        guard let response = response as? HTTPURLResponse,
              200..<300 ~= response.statusCode else {
            throw InpaintingModelError.invalidManifest
        }
        let manifest = try JSONDecoder().decode(
            InpaintingModelManifest.self,
            from: data
        )
        guard manifest.schemaVersion == 1,
              manifest.resources.contains(where: {
                  $0.path == "VAEEncoder.mlmodelc/model.mil"
              }),
              manifest.resources.contains(where: {
                  $0.path == "UnetChunk1.mlmodelc/model.mil"
              }) else {
            throw InpaintingModelError.invalidManifest
        }
        return manifest
    }

    func install(
        manifest: InpaintingModelManifest,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let finalURL = ModelStorage.inpaintingResourcesURL
        let stagingURL = finalURL.deletingLastPathComponent()
            .appending(path: "Resources.staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: true
        )

        var completedBytes: Int64 = 0
        for resource in manifest.resources {
            try Task.checkCancellation()
            let destination = stagingURL.appending(path: resource.path)
            if try isValid(resource: resource, at: destination) {
                completedBytes += resource.size
                progress(fraction(completedBytes, manifest.totalSize))
                continue
            }

            // A revision marker is the source of truth for the complete
            // installation, but individual files from an older installation
            // can still be reused after they pass the new manifest checksum.
            // This makes v2 upgrades resumable and avoids downloading shared
            // text encoder, VAE, and safety-checker weights again.
            let previousResource = finalURL.appending(path: resource.path)
            if try isValid(resource: resource, at: previousResource) {
                try copyVerifiedResource(
                    from: previousResource,
                    to: destination
                )
                completedBytes += resource.size
                progress(fraction(completedBytes, manifest.totalSize))
                continue
            }

            let baseCompleted = completedBytes
            let operation = InpaintingFileDownloadOperation()
            try await operation.download(
                from: manifest.downloadURL(for: resource),
                to: destination
            ) { written, _ in
                let capped = min(written, resource.size)
                progress(
                    self.fraction(
                        baseCompleted + capped,
                        manifest.totalSize
                    )
                )
            }
            guard try isValid(resource: resource, at: destination) else {
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: destination.path
                )
                if attributes[.size] as? Int64 != resource.size {
                    throw InpaintingModelError.sizeMismatch(resource.path)
                }
                throw InpaintingModelError.checksumMismatch(resource.path)
            }
            completedBytes += resource.size
        }

        guard ModelStorage.isInpaintingResourcesDirectory(stagingURL),
              FileManager.default.fileExists(atPath: stagingURL.path) else {
            throw InpaintingModelError.incompletePackage
        }
        try (InpaintingModelManifest.repositoryRevision + "\n").write(
            to: stagingURL.appending(
                path: InpaintingModelManifest.revisionMarkerName
            ),
            atomically: true,
            encoding: .utf8
        )
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: stagingURL, to: finalURL)
        progress(1)
        return finalURL
    }

    private func copyVerifiedResource(
        from source: URL,
        to destination: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func isValid(
        resource: InpaintingModelManifest.Resource,
        at url: URL
    ) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        guard attributes[.size] as? Int64 == resource.size else {
            return false
        }
        return try Self.sha256(url) == resource.sha256
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024),
              !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func fraction(_ completed: Int64, _ total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

@MainActor
@Observable
final class InpaintingModelManager {
    enum State: Equatable {
        case notInstalled
        case checking
        case downloading(Double)
        case installed
        case failed(String)

        var isWorking: Bool {
            switch self {
            case .checking, .downloading: true
            case .notInstalled, .installed, .failed: false
            }
        }
    }

    private(set) var state: State
    private(set) var manifest: InpaintingModelManifest?

    @ObservationIgnored
    private let downloader = InpaintingModelDownloader()
    @ObservationIgnored
    private var task: Task<Void, Never>?

    init() {
        state = InpaintingModelManifest.hasCurrentInstallation
            ? .installed
            : .notInstalled
    }

    var isInstalled: Bool {
        state == .installed && InpaintingModelManifest.hasCurrentInstallation
    }

    func refresh() async {
        if InpaintingModelManifest.hasCurrentInstallation {
            state = .installed
            return
        }
        guard !state.isWorking else { return }
        state = .checking
        do {
            manifest = try await downloader.fetchManifest()
            state = .notInstalled
        } catch is CancellationError {
            state = .notInstalled
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func download() {
        guard task == nil, !isInstalled else { return }
        state = .checking
        let downloader = downloader
        task = Task { [weak self, downloader] in
            guard let self else { return }
            do {
                let manifest = try await downloader.fetchManifest()
                self.manifest = manifest
                state = .downloading(0)
                _ = try await downloader.install(manifest: manifest) { progress in
                    Task { @MainActor in
                        self.state = .downloading(progress)
                    }
                }
                state = .installed
            } catch is CancellationError {
                state = InpaintingModelManifest.hasCurrentInstallation
                    ? .installed
                    : .notInstalled
            } catch {
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if !InpaintingModelManifest.hasCurrentInstallation {
            state = .notInstalled
        }
    }
}

private final class InpaintingFileDownloadOperation:
    NSObject,
    URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL?
    private var progress: (@Sendable (Int64, Int64) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var moveError: Error?

    func download(
        from source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                    self.destination = destination
                    self.progress = progress
                    let configuration = URLSessionConfiguration.default
                    configuration.waitsForConnectivity = true
                    configuration.timeoutIntervalForResource = 60 * 60
                    let session = URLSession(
                        configuration: configuration,
                        delegate: self,
                        delegateQueue: nil
                    )
                    self.session = session
                    let task = session.downloadTask(with: source)
                    self.task = task
                    task.resume()
                }
            }
        } onCancel: {
            lock.withLock {
                task?.cancel()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let destination else { return }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        finish(error ?? moveError)
    }

    private func finish(_ error: Error?) {
        let continuation = lock.withLock {
            let current = self.continuation
            self.continuation = nil
            return current
        }
        guard let continuation else { return }
        session?.finishTasksAndInvalidate()
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
