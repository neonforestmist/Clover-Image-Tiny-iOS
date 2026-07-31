import Foundation
import Observation

@MainActor
@Observable
final class ModelManager {
    enum InstallState: Equatable {
        case notInstalled
        case downloading(Double)
        case installed
        case failed(String)
    }

    private(set) var catalog: ModelCatalog
    private(set) var states: [String: InstallState] = [:]
    private(set) var isRefreshing = false
    var errorMessage: String?

    @ObservationIgnored
    private let downloader = ModelDownloader()
    @ObservationIgnored
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored
    private let previewInstalled: Bool

    init(previewInstalled: Bool? = nil) {
        self.previewInstalled = previewInstalled
            ?? ProcessInfo.processInfo.arguments.contains("-ui-testing-preview")
        catalog = Self.cachedCatalog() ?? .bootstrap
        refreshInstallStates()
    }

    func refreshCatalog() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let (data, response) = try await URLSession.shared.data(
                from: ModelCatalog.remoteURL
            )
            guard let response = response as? HTTPURLResponse,
                  200..<300 ~= response.statusCode else {
                throw ModelDownloadError.invalidResponse
            }
            let remote = try JSONDecoder().decode(ModelCatalog.self, from: data)
            guard remote.schemaVersion == 1 else {
                throw ModelDownloadError.invalidResponse
            }
            catalog = remote
            try Self.cache(data)
            refreshInstallStates()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func state(for id: String) -> InstallState {
        if previewInstalled {
            return .installed
        }
        return states[id] ?? .notInstalled
    }

    func isInstalled(_ id: String) -> Bool {
        state(for: id) == .installed
    }

    func variant(id: String) -> ModelCatalog.Variant? {
        catalog.variant(id: id)
    }

    func download(_ variant: ModelCatalog.Variant) {
        guard downloadTasks[variant.id] == nil,
              !variant.files.isEmpty,
              !catalog.common.files.isEmpty else {
            return
        }
        states[variant.id] = .downloading(0)
        downloadTasks[variant.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let resourcesURL = try await downloader.install(
                    variant: variant,
                    catalog: catalog
                ) { progress in
                    Task { @MainActor in
                        self.states[variant.id] = .downloading(progress)
                    }
                }
                guard !Task.isCancelled else { return }
                ModelStorage.recordInstallation(
                    id: variant.id,
                    resourcesURL: resourcesURL
                )
                states[variant.id] = .installed
            } catch is CancellationError {
                states[variant.id] = .notInstalled
            } catch {
                states[variant.id] = .failed(error.localizedDescription)
            }
            downloadTasks[variant.id] = nil
        }
    }

    func cancelDownload(_ id: String) {
        downloadTasks[id]?.cancel()
        downloadTasks[id] = nil
        states[id] = .notInstalled
    }

    func remove(_ variant: ModelCatalog.Variant) {
        cancelDownload(variant.id)
        let root = ModelStorage.rootURL
            .appending(path: "Installed", directoryHint: .isDirectory)
            .appending(path: variant.id, directoryHint: .isDirectory)
        let variantFiles = ModelStorage.rootURL
            .appending(path: "Variants", directoryHint: .isDirectory)
            .appending(path: variant.id, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: variantFiles)
        ModelStorage.clearInstallation(id: variant.id)
        states[variant.id] = .notInstalled
    }

    func requiredDownloadSize(for variant: ModelCatalog.Variant) -> Int64 {
        let commonInstalled = catalog.variants.contains {
            isInstalled($0.id)
        }
        return variant.downloadSize
            + (commonInstalled ? 0 : catalog.common.downloadSize)
    }

    private func refreshInstallStates() {
        for variant in catalog.variants
        where downloadTasks[variant.id] == nil {
            states[variant.id] = ModelStorage.resourcesURL(for: variant.id) == nil
                ? .notInstalled
                : .installed
        }
    }

    private static func cachedCatalog() -> ModelCatalog? {
        guard let data = try? Data(
            contentsOf: ModelStorage.cachedCatalogURL
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(ModelCatalog.self, from: data)
    }

    private static func cache(_ data: Data) throws {
        let url = ModelStorage.cachedCatalogURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
