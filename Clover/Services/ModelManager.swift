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

    static let baseID = "base"

    private(set) var catalog: ModelCatalog
    private(set) var states: [String: InstallState] = [:]
    /// Core ML models the user side-loaded through the Files app.
    private(set) var imported: [ModelStorage.ImportedModel] = []
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
        refreshImported()
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
            guard 1...3 ~= remote.schemaVersion else {
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

    /// Re-scan the Files import folder. Cheap; safe to call when the picker appears.
    func refreshImported() {
        imported = ModelStorage.importedModels()
    }

    func state(for id: String) -> InstallState {
        if previewInstalled {
            return .installed
        }
        if id.hasPrefix(ModelStorage.importedIDPrefix) {
            return imported.contains { $0.id == id } ? .installed : .notInstalled
        }
        return states[id] ?? .notInstalled
    }

    func isInstalled(_ id: String) -> Bool {
        state(for: id) == .installed
    }

    /// Clover's base model must exist before any style can be installed or used.
    var isBaseInstalled: Bool {
        isInstalled(Self.baseID)
    }

    /// A style is locked until the base Clover model is installed.
    func isLocked(_ variant: ModelCatalog.Variant) -> Bool {
        variant.id != Self.baseID && !isBaseInstalled
    }

    /// Whether a Download button should be offered for this variant right now.
    func canDownload(_ variant: ModelCatalog.Variant) -> Bool {
        guard !catalog.common.files.isEmpty else { return false }
        if variant.id == Self.baseID { return true }
        return isBaseInstalled
    }

    func variant(id: String) -> ModelCatalog.Variant? {
        catalog.variant(id: id)
    }

    func importedModel(id: String) -> ModelStorage.ImportedModel? {
        imported.first { $0.id == id }
    }

    /// A friendly name for any selectable model, including imported ones.
    func displayName(for id: String) -> String? {
        variant(id: id)?.name ?? importedModel(id: id)?.name
    }

    func download(_ variant: ModelCatalog.Variant) {
        guard downloadTasks[variant.id] == nil,
              canDownload(variant) else {
            return
        }

        // Styles reuse Clover's already-installed shared components, so they
        // never re-download the large base weights.
        let reuseCommon = variant.id != Self.baseID && isBaseInstalled

        states[variant.id] = .downloading(0)
        downloadTasks[variant.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let resourcesURL = try await downloader.install(
                    variant: variant,
                    catalog: catalog,
                    reuseCommon: reuseCommon
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

        if variant.id == Self.baseID {
            // Every style links to Clover's shared components, so removing the
            // base model removes the styles that depend on it too.
            for style in catalog.variants where style.id != Self.baseID {
                cancelDownload(style.id)
                removeInstalledFiles(id: style.id)
                states[style.id] = .notInstalled
            }
            try? FileManager.default.removeItem(
                at: ModelStorage.sharedURL(revision: catalog.common.revision)
            )
        }

        removeInstalledFiles(id: variant.id)
        states[variant.id] = .notInstalled
    }

    func requiredDownloadSize(for variant: ModelCatalog.Variant) -> Int64 {
        if variant.id == Self.baseID {
            return catalog.common.downloadSize + variant.downloadSize
        }
        // Once Clover is installed a style only adds its own (often shared and
        // therefore zero-byte) files.
        return variant.downloadSize
            + (isBaseInstalled ? 0 : catalog.common.downloadSize)
    }

    private func removeInstalledFiles(id: String) {
        let installed = ModelStorage.rootURL
            .appending(path: "Installed", directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory)
        let variantFiles = ModelStorage.rootURL
            .appending(path: "Variants", directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: installed)
        try? FileManager.default.removeItem(at: variantFiles)
        ModelStorage.clearInstallation(id: id)
    }

    private func refreshInstallStates() {
        for variant in catalog.variants where downloadTasks[variant.id] == nil {
            if catalog.schemaVersion >= 3 {
                let resourcesURL = ModelStorage.installationURL(
                    id: variant.id,
                    revision: variant.revision
                ).appending(
                    path: "Resources",
                    directoryHint: .isDirectory
                )
                let hasAdapter = FileManager.default.fileExists(
                    atPath: resourcesURL.appending(
                        path: "Adapter.safetensors"
                    ).path
                )
                let isCurrent = !variant.revision.isEmpty
                    && ModelStorage.isStatefulLoRAResourcesDirectory(
                        resourcesURL
                    )
                    && (variant.id == Self.baseID || hasAdapter)
                if isCurrent {
                    ModelStorage.recordInstallation(
                        id: variant.id,
                        resourcesURL: resourcesURL
                    )
                } else {
                    ModelStorage.clearInstallation(id: variant.id)
                }
                states[variant.id] = isCurrent
                    ? .installed
                    : .notInstalled
            } else {
                states[variant.id] = ModelStorage.resourcesURL(
                    for: variant.id
                ) == nil ? .notInstalled : .installed
            }
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
