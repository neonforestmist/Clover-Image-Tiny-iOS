import Foundation

enum ModelStorage {
    private static let installKeyPrefix = "clover-model-install-"

    /// Prefix marking a model the user side-loaded via the Files app rather
    /// than one downloaded from the catalog.
    static let importedIDPrefix = "imported:"

    /// A Core ML model the user placed in On My iPhone › Clover › Imported Styles.
    struct ImportedModel: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let resourcesURL: URL
    }

    static let rootURL: URL = {
        let fileManager = FileManager.default
        let visibleURL = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        .appending(path: "Models", directoryHint: .isDirectory)
        let legacyURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appending(path: "Clover", directoryHint: .isDirectory)
        .appending(path: "Models", directoryHint: .isDirectory)

        do {
            let legacyExists = fileManager.fileExists(
                atPath: legacyURL.path
            )
            let legacyIsCompatibilityLink = (
                try? fileManager.destinationOfSymbolicLink(
                    atPath: legacyURL.path
                )
            ) != nil
            var visibleExists = fileManager.fileExists(
                atPath: visibleURL.path
            )

            if legacyExists, !legacyIsCompatibilityLink, visibleExists {
                let visibleContents = try fileManager.contentsOfDirectory(
                    at: visibleURL,
                    includingPropertiesForKeys: nil
                )
                if visibleContents.isEmpty {
                    try fileManager.removeItem(at: visibleURL)
                    visibleExists = false
                }
            }

            if legacyExists, !legacyIsCompatibilityLink, !visibleExists {
                try fileManager.createDirectory(
                    at: visibleURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: legacyURL, to: visibleURL)
            } else if !visibleExists {
                try fileManager.createDirectory(
                    at: visibleURL,
                    withIntermediateDirectories: true
                )
            }

            // Existing installation records and assembled model symlinks use
            // the legacy absolute path. This compatibility link keeps
            // migrated downloads usable without downloading them again.
            if !fileManager.fileExists(atPath: legacyURL.path),
               !legacyIsCompatibilityLink {
                try fileManager.createDirectory(
                    at: legacyURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.createSymbolicLink(
                    at: legacyURL,
                    withDestinationURL: visibleURL
                )
            }

            var visibleResourceURL = visibleURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try visibleResourceURL.setResourceValues(values)
        } catch {
            // New downloads still target Documents if migration fails. The
            // downloader will surface any later file-system error.
            try? fileManager.createDirectory(
                at: visibleURL,
                withIntermediateDirectories: true
            )
        }

        return visibleURL
    }()

    static var cachedCatalogURL: URL {
        rootURL
            .appending(path: "Catalog", directoryHint: .isDirectory)
            .appending(path: "manifest.json")
    }

    /// The user-visible drop folder for side-loaded Core ML models. It sits at
    /// the top level of the app's Documents container, so in the Files app it
    /// appears as On My iPhone › Clover › Imported Styles.
    static var importedRootURL: URL {
        let documents = rootURL.deletingLastPathComponent()
        let url = documents.appending(
            path: "Imported Styles",
            directoryHint: .isDirectory
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
        return url
    }

    /// Every valid Core ML model the user has dropped into the import folder.
    /// A folder counts if it is itself a usable resources directory or directly
    /// contains exactly one usable resources directory (e.g. an unzipped
    /// `Resources` folder from the Core ML conversion tooling).
    static func importedModels() -> [ImportedModel] {
        let root = importedRootURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var models: [ImportedModel] = []
        for entry in entries {
            guard (try? entry.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory) == true else {
                continue
            }
            guard let resources = resolveImportedResources(entry) else {
                continue
            }
            let name = entry.deletingPathExtension().lastPathComponent
            models.append(
                ImportedModel(
                    id: importedIDPrefix + name,
                    name: name,
                    resourcesURL: resources
                )
            )
        }
        return models.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func resolveImportedResources(_ folder: URL) -> URL? {
        if isUsableResourcesDirectory(folder) {
            return folder
        }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let usable = children.filter {
            ((try? $0.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory) == true)
                && isUsableResourcesDirectory($0)
        }
        return usable.count == 1 ? usable.first : nil
    }

    static func sharedURL(revision: String) -> URL {
        rootURL
            .appending(path: "Shared", directoryHint: .isDirectory)
            .appending(path: revision, directoryHint: .isDirectory)
    }

    static func variantURL(id: String, revision: String) -> URL {
        rootURL
            .appending(path: "Variants", directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory)
            .appending(path: revision, directoryHint: .isDirectory)
    }

    static func installationURL(id: String, revision: String) -> URL {
        rootURL
            .appending(path: "Installed", directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory)
            .appending(path: revision, directoryHint: .isDirectory)
    }

    static func resourcesURL(for id: String) -> URL? {
        if id.hasPrefix(importedIDPrefix) {
            return importedModels().first { $0.id == id }?.resourcesURL
        }

        if let stored = UserDefaults.standard.string(
            forKey: installKeyPrefix + id
        ) {
            for url in installationCandidates(for: stored) {
                if isUsableResourcesDirectory(url) {
                    if stored.hasPrefix("/") {
                        recordInstallation(id: id, resourcesURL: url)
                    }
                    return url
                }
            }
        }

        if id == "base",
           let bundleURL = Bundle.main.resourceURL,
           isUsableResourcesDirectory(bundleURL) {
            return bundleURL
        }
        return nil
    }

    static func recordInstallation(id: String, resourcesURL: URL) {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let resourceComponents = resourcesURL
            .standardizedFileURL
            .pathComponents
        let storedPath: String
        if resourceComponents.starts(with: rootComponents) {
            storedPath = resourceComponents
                .dropFirst(rootComponents.count)
                .joined(separator: "/")
        } else {
            storedPath = resourcesURL.path
        }
        UserDefaults.standard.set(
            storedPath,
            forKey: installKeyPrefix + id
        )
    }

    static func clearInstallation(id: String) {
        UserDefaults.standard.removeObject(forKey: installKeyPrefix + id)
    }

    static func isUsableResourcesDirectory(_ url: URL) -> Bool {
        let required = [
            "TextEncoder.mlmodelc",
            "VAEDecoder.mlmodelc",
            "SafetyChecker.mlmodelc",
            "vocab.json",
            "merges.txt",
        ]
        let hasRequiredResources = required.allSatisfy {
            FileManager.default.fileExists(
                atPath: url.appending(path: $0).path
            )
        }
        let hasSingleUNet = FileManager.default.fileExists(
            atPath: url.appending(path: "Unet.mlmodelc").path
        )
        let hasChunkedUNet = [
            "UnetChunk1.mlmodelc",
            "UnetChunk2.mlmodelc",
        ].allSatisfy {
            FileManager.default.fileExists(
                atPath: url.appending(path: $0).path
            )
        }
        return hasRequiredResources && (hasSingleUNet || hasChunkedUNet)
    }

    static func isStatefulLoRAResourcesDirectory(_ url: URL) -> Bool {
        isUsableResourcesDirectory(url)
            && FileManager.default.fileExists(
                atPath: url.appending(path: "Unet.mlmodelc").path
            )
            && FileManager.default.fileExists(
                atPath: url.appending(path: "adapter-schema.json").path
            )
    }

    static func isMultifunctionResourcesDirectory(_ url: URL) -> Bool {
        isUsableResourcesDirectory(url)
            && FileManager.default.fileExists(
                atPath: url.appending(path: "functions.json").path
            )
    }

    private static func installationCandidates(
        for storedPath: String
    ) -> [URL] {
        if !storedPath.hasPrefix("/") {
            return [
                rootURL.appending(
                    path: storedPath,
                    directoryHint: .isDirectory
                )
            ]
        }

        var candidates = [
            URL(filePath: storedPath, directoryHint: .isDirectory)
        ]
        if let modelsRange = storedPath.range(
            of: "/Models/",
            options: .backwards
        ) {
            let relativePath = String(
                storedPath[modelsRange.upperBound...]
            )
            candidates.append(
                rootURL.appending(
                    path: relativePath,
                    directoryHint: .isDirectory
                )
            )
        }
        return candidates
    }
}
