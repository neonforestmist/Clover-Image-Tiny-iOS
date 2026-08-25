import CryptoKit
import Foundation
import Observation

struct InpaintingModelManifest: Codable, Sendable {
    struct Resource: Codable, Sendable {
        let path: String
        let remotePath: String?
        let size: Int64
        let sha256: String

        init(
            path: String,
            remotePath: String? = nil,
            size: Int64,
            sha256: String
        ) {
            self.path = path
            self.remotePath = remotePath
            self.size = size
            self.sha256 = sha256
        }

        enum CodingKeys: String, CodingKey {
            case path
            case remotePath = "remote_path"
            case size
            case sha256
        }
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

    static let repositoryRevision = "67b44c84778e94c92ffb8d9086e3f76b38fbfb28"
    /// Identifies the full-float, stateless Core ML pipeline converted from
    /// the published nine-channel Diffusers inpainting checkpoint.
    static let installationVersion = "\(repositoryRevision)-pipeline-v1-fp16"
    static let revisionMarkerName = ".clover-inpainting-revision"

    static let remoteURL = URL(
        string: "https://huggingface.co/neonforestmist/Clover-Image-Tiny-Inpaint-CoreML/resolve/\(repositoryRevision)/manifest-pipeline.json"
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
            == installationVersion
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

    /// Validates only the files owned by the standalone inpainting download.
    /// The tokenizer, text encoder, and VAE decoder are intentionally absent
    /// from this manifest because the installer reuses them from Clover.
    var isValidForInstallation: Bool {
        guard schemaVersion == 3,
              resolution == [512, 512],
              !resources.isEmpty,
              resources.allSatisfy({ resource in
                  resource.size >= 0
                      && Self.isSafeRelativePath(resource.path)
                      && resource.sha256.count == 64
                      && resource.sha256.allSatisfy(\.isHexDigit)
              }) else {
            return false
        }

        let paths = Set(resources.map(\.path))
        func hasCompiledModel(_ name: String) -> Bool {
            [
                "\(name).mlmodelc/metadata.json",
                "\(name).mlmodelc/model.mil",
                "\(name).mlmodelc/weights/weight.bin",
            ].allSatisfy(paths.contains)
        }

        let hasCompiledPipeline = [
            "UnetPipeline.mlmodelc/metadata.json",
            "UnetPipeline.mlmodelc/model0/model.mil",
            "UnetPipeline.mlmodelc/model0/weights/0-weight.bin",
            "UnetPipeline.mlmodelc/model1/model.mil",
            "UnetPipeline.mlmodelc/model1/weights/1-weight.bin",
        ].allSatisfy(paths.contains)

        let hasSingleUnet = hasCompiledModel("Unet")
        let hasChunkedUnet = ["UnetChunk1", "UnetChunk2"]
            .allSatisfy(hasCompiledModel)
        return hasCompiledModel("VAEEncoder")
            && (hasCompiledPipeline || hasSingleUnet || hasChunkedUnet)
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    func downloadURL(for resource: Resource) -> URL {
        let remotePath = resource.remotePath ?? resource.path
        var components = URLComponents(
            string: "https://huggingface.co/neonforestmist/Clover-Image-Tiny-Inpaint-CoreML/resolve/\(Self.repositoryRevision)/\(remotePath)"
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
    case requiresClover

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
        case .requiresClover:
            "Download Clover before installing the inpainting model."
        }
    }
}

final class InpaintingModelDownloader: Sendable {
    static let stagingDirectoryName = "Inpainting.staging"
    static let legacyStagingDirectoryName = "Resources.staging"

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
        guard manifest.isValidForInstallation else {
            throw InpaintingModelError.invalidManifest
        }
        return manifest
    }

    func install(
        manifest: InpaintingModelManifest,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let finalURL = ModelStorage.inpaintingResourcesURL
        let stagingURL = try prepareStagingDirectory(
            parentURL: finalURL.deletingLastPathComponent()
        )
        try installSharedCloverResources(into: stagingURL)

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
            // This makes upgrades resumable and avoids downloading shared
            // text encoder and VAE decoder weights again.
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
        try (InpaintingModelManifest.installationVersion + "\n").write(
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

    /// Migrates the legacy staging folder and preserves verified downloads so
    /// a retry does not need to fetch the large U-Net again. Every write into
    /// this directory is idempotent and verified against the manifest.
    func prepareStagingDirectory(parentURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let stagingURL = parentURL.appending(
            path: Self.stagingDirectoryName,
            directoryHint: .isDirectory
        )
        let legacyURL = parentURL.appending(
            path: Self.legacyStagingDirectoryName,
            directoryHint: .isDirectory
        )

        if itemExists(at: stagingURL) {
            if itemExists(at: legacyURL) {
                try fileManager.removeItem(at: legacyURL)
            }
            return stagingURL
        }
        if itemExists(at: legacyURL) {
            try fileManager.moveItem(at: legacyURL, to: stagingURL)
            return stagingURL
        }

        try fileManager.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: true
        )
        return stagingURL
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

    /// Inpainting has its own U-Net and VAE encoder, but it uses Clover's
    /// tokenizer, text encoder, and VAE decoder. Hard-linking those immutable
    /// files keeps a visible, complete Files-app folder without consuming a
    /// second copy of the main model on device.
    private func installSharedCloverResources(into destinationRoot: URL) throws {
        guard let cloverResources = ModelStorage.resourcesURL(for: "base") else {
            throw InpaintingModelError.requiresClover
        }
        for name in [
            "TextEncoder.mlmodelc",
            "VAEDecoder.mlmodelc",
            "vocab.json",
            "merges.txt",
        ] {
            let source = cloverResources.appending(path: name)
            let destination = destinationRoot.appending(path: name)
            try linkOrCopyTree(from: source, to: destination)
        }
    }

    func linkOrCopyTree(from sourceURL: URL, to destination: URL) throws {
        let source = sourceURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: source.path,
            isDirectory: &isDirectory
        ) else {
            throw InpaintingModelError.requiresClover
        }
        if !isDirectory.boolValue {
            try linkOrCopyFile(from: source, to: destination)
            return
        }

        if itemExists(at: destination) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        guard let enumerator = FileManager.default.enumerator(
            atPath: source.path
        ) else {
            throw InpaintingModelError.requiresClover
        }
        for case let relativePath as String in enumerator {
            let sourceItem = source.appending(path: relativePath)
            let destinationItem = destination.appending(path: relativePath)
            var isChildDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: sourceItem.path,
                isDirectory: &isChildDirectory
            ) else {
                throw InpaintingModelError.requiresClover
            }
            if isChildDirectory.boolValue {
                try FileManager.default.createDirectory(
                    at: destinationItem,
                    withIntermediateDirectories: true
                )
            } else {
                try linkOrCopyFile(from: sourceItem, to: destinationItem)
            }
        }
    }

    private func linkOrCopyFile(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let resolvedSource = source.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let temporaryURL = destination.deletingLastPathComponent().appending(
            path: ".clover-\(UUID().uuidString).tmp"
        )
        defer {
            if itemExists(at: temporaryURL) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        do {
            try fileManager.linkItem(at: resolvedSource, to: temporaryURL)
        } catch {
            if itemExists(at: temporaryURL) {
                try fileManager.removeItem(at: temporaryURL)
            }
            try fileManager.copyItem(at: resolvedSource, to: temporaryURL)
        }

        if itemExists(at: destination) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
    }

    private func itemExists(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
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
        if !InpaintingModelManifest.hasCurrentInstallation {
            state = .notInstalled
        }
    }

    func removeDownload() {
        guard !state.isWorking else { return }
        let fileManager = FileManager.default
        let installedURL = ModelStorage.inpaintingResourcesURL
        let parentURL = installedURL.deletingLastPathComponent()
        let removableURLs = [
            installedURL,
            parentURL.appending(
                path: InpaintingModelDownloader.stagingDirectoryName,
                directoryHint: .isDirectory
            ),
            parentURL.appending(
                path: InpaintingModelDownloader.legacyStagingDirectoryName,
                directoryHint: .isDirectory
            ),
        ]

        for url in removableURLs where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
        manifest = nil
        state = .notInstalled
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
