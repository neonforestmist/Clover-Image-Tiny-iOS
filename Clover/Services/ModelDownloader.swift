import CryptoKit
import Foundation

enum ModelDownloadError: LocalizedError {
    case invalidResponse
    case sizeMismatch(String)
    case checksumMismatch(String)
    case incompletePackage

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Hugging Face returned an invalid download response."
        case let .sizeMismatch(path):
            "The downloaded size did not match the catalog for \(path)."
        case let .checksumMismatch(path):
            "Checksum verification failed for \(path)."
        case .incompletePackage:
            "The downloaded model package is incomplete."
        }
    }
}

final class ModelDownloader: Sendable {
    func install(
        variant: ModelCatalog.Variant,
        catalog: ModelCatalog,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let commonRoot = ModelStorage.sharedURL(
            revision: catalog.common.revision
        )
        let variantRoot = ModelStorage.variantURL(
            id: variant.id,
            revision: variant.revision
        )
        let totalBytes = catalog.common.downloadSize + variant.downloadSize
        var completedBytes: Int64 = 0

        completedBytes = try await download(
            files: catalog.common.files,
            revision: catalog.common.revision,
            repository: catalog.common.repository,
            catalog: catalog,
            destinationRoot: commonRoot,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            progress: progress
        )
        completedBytes = try await download(
            files: variant.files,
            revision: variant.revision,
            repository: variant.repository,
            catalog: catalog,
            destinationRoot: variantRoot,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            progress: progress
        )

        let resourcesURL = try assemble(
            variant: variant,
            catalog: catalog,
            commonRoot: commonRoot,
            variantRoot: variantRoot
        )
        guard ModelStorage.isUsableResourcesDirectory(resourcesURL) else {
            throw ModelDownloadError.incompletePackage
        }
        progress(1)
        return resourcesURL
    }

    private func download(
        files: [ModelCatalog.ResourceFile],
        revision: String,
        repository: String?,
        catalog: ModelCatalog,
        destinationRoot: URL,
        completedBytes: Int64,
        totalBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int64 {
        var completedBytes = completedBytes
        try FileManager.default.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: true
        )

        for file in files {
            try Task.checkCancellation()
            let destination = destinationRoot.appending(path: file.path)
            if try isValid(file: file, at: destination) {
                completedBytes += file.size
                progress(fraction(completedBytes, totalBytes))
                continue
            }

            let baseCompleted = completedBytes
            let operation = FileDownloadOperation()
            try await operation.download(
                from: catalog.downloadURL(
                    for: file,
                    revision: revision,
                    repository: repository
                ),
                to: destination
            ) { written, expected in
                let capped = min(written, file.size)
                progress(self.fraction(baseCompleted + capped, totalBytes))
            }
            guard try isValid(file: file, at: destination) else {
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: destination.path
                )
                let size = attributes[.size] as? Int64
                if size != file.size {
                    throw ModelDownloadError.sizeMismatch(file.path)
                }
                throw ModelDownloadError.checksumMismatch(file.path)
            }
            completedBytes += file.size
        }
        return completedBytes
    }

    private func assemble(
        variant: ModelCatalog.Variant,
        catalog: ModelCatalog,
        commonRoot: URL,
        variantRoot: URL
    ) throws -> URL {
        let installRoot = ModelStorage.installationURL(
            id: variant.id,
            revision: variant.revision
        )
        let resourcesURL = installRoot.appending(
            path: "Resources",
            directoryHint: .isDirectory
        )
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: installRoot.path) {
            try fileManager.removeItem(at: installRoot)
        }
        try fileManager.createDirectory(
            at: resourcesURL,
            withIntermediateDirectories: true
        )

        let commonComponents = Set(
            catalog.common.files.compactMap {
                $0.path.split(separator: "/").first.map(String.init)
            }
        )
        let variantComponents = Set(
            variant.files.compactMap {
                $0.path.split(separator: "/").first.map(String.init)
            }
        )
        for component in commonComponents {
            try link(
                component: component,
                from: commonRoot,
                into: resourcesURL
            )
        }
        for component in variantComponents {
            try link(
                component: component,
                from: variantRoot,
                into: resourcesURL
            )
        }
        return resourcesURL
    }

    private func link(
        component: String,
        from sourceRoot: URL,
        into resourcesURL: URL
    ) throws {
        try FileManager.default.createSymbolicLink(
            at: resourcesURL.appending(path: component),
            withDestinationURL: sourceRoot.appending(path: component)
        )
    }

    private func isValid(
        file: ModelCatalog.ResourceFile,
        at url: URL
    ) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        guard attributes[.size] as? Int64 == file.size else {
            return false
        }
        return try Self.sha256(url) == file.sha256
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

private final class FileDownloadOperation:
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
            self.lock.withLock {
                self.task?.cancel()
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
