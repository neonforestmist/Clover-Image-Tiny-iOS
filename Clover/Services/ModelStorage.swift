import Foundation

enum ModelStorage {
    private static let installKeyPrefix = "clover-model-install-"

    /// Prefix marking a model the user side-loaded via the Files app rather
    /// than one downloaded from the catalog.
    static let importedIDPrefix = "imported:"

    /// A style the user placed in On My iPhone › Clover › Imported Styles.
    struct ImportedStyle: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let weightsURL: URL
        let fileSize: Int64?

        var requiresClover: Bool {
            true
        }

        var detail: String {
            guard let fileSize else { return "Clover LoRA" }
            return "Clover LoRA · \(fileSize.formatted(.byteCount(style: .file)))"
        }
    }

    static let rootURL: URL = {
        let fileManager = FileManager.default
        let url = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        .appending(path: "Models", directoryHint: .isDirectory)

        do {
            if !fileManager.fileExists(atPath: url.path) {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
            }

            var visibleResourceURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try visibleResourceURL.setResourceValues(values)
        } catch {
            try? fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }

        return url
    }()

    static var cachedCatalogURL: URL {
        rootURL
            .appending(path: "Catalog", directoryHint: .isDirectory)
            .appending(path: "manifest.json")
    }

    /// Standalone 9-channel inpainting resources copied or downloaded into
    /// the app's Documents container.
    static var inpaintingResourcesURL: URL {
        rootURL
            .appending(path: "Inpainting", directoryHint: .isDirectory)
    }

    static var hasInpaintingResources: Bool {
        isInpaintingResourcesDirectory(inpaintingResourcesURL)
    }

    static func isInpaintingResourcesDirectory(_ url: URL) -> Bool {
        let required = [
            "TextEncoder.mlmodelc",
            "VAEEncoder.mlmodelc",
            "VAEDecoder.mlmodelc",
            "adapter-schema.json",
            "vocab.json",
            "merges.txt",
        ]
        let hasUnet = FileManager.default.fileExists(
            atPath: url
                .appending(path: "Unet.mlmodelc")
                .path
        )
        return hasUnet && required.allSatisfy {
            FileManager.default.fileExists(
                atPath: url.appending(path: $0).path
            )
        }
    }

    /// The user-visible drop folder for side-loaded LoRA styles. It sits at
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

    /// Every supported style in the import folder. A standalone safetensors
    /// file is loaded into Clover's shared stateful U-Net.
    static func importedStyles() -> [ImportedStyle] {
        let root = importedRootURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileSizeKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var styles: [ImportedStyle] = []
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
            ]) else {
                continue
            }

            if values.isRegularFile == true,
               entry.pathExtension.lowercased() == "safetensors",
               let fileSize = values.fileSize,
               fileSize > 8 {
                let filename = entry.lastPathComponent
                styles.append(
                    ImportedStyle(
                        id: importedIDPrefix
                            + "weights:"
                            + filename.lowercased(),
                        name: entry.deletingPathExtension().lastPathComponent,
                        weightsURL: entry,
                        fileSize: Int64(fileSize)
                    )
                )
            }
        }
        return styles.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func sharedURL(revision: String) -> URL {
        sharedRootURL
            .appending(path: revision, directoryHint: .isDirectory)
    }

    static var sharedRootURL: URL {
        rootURL.appending(path: "Shared", directoryHint: .isDirectory)
    }

    static func removeObsoleteSharedRevisions(
        keeping revision: String,
        under root: URL? = nil
    ) {
        guard !revision.isEmpty else { return }
        let sharedRoot = root ?? sharedRootURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: sharedRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for entry in entries where entry.lastPathComponent != revision {
            try? FileManager.default.removeItem(at: entry)
        }
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
            guard importedStyles().contains(where: { $0.id == id }) else {
                return nil
            }
            return resourcesURL(for: "base")
        }

        if let stored = UserDefaults.standard.string(
            forKey: installKeyPrefix + id
        ), !stored.hasPrefix("/") {
            let url = rootURL.appending(
                path: stored,
                directoryHint: .isDirectory
            )
            if isUsableResourcesDirectory(url) {
                return url
            }
        }

        if id == "base",
           let bundleURL = Bundle.main.resourceURL,
           isUsableResourcesDirectory(bundleURL) {
            return bundleURL
        }
        return nil
    }

    static func importedWeightsURL(for id: String) -> URL? {
        guard id.hasPrefix(importedIDPrefix) else { return nil }
        return importedStyles().first { $0.id == id }?.weightsURL
    }

    /// Resolves either a downloaded catalog style or a Files-imported style
    /// to the small safetensors payload consumed by Clover's stateful U-Net.
    static func styleWeightsURL(for id: String) -> URL? {
        if let imported = importedWeightsURL(for: id) {
            return imported
        }
        guard id != "base", let resources = resourcesURL(for: id) else {
            return nil
        }
        let weights = resources.appending(path: "Adapter.safetensors")
        guard FileManager.default.fileExists(atPath: weights.path) else {
            return nil
        }
        return weights
    }

    static func recordInstallation(id: String, resourcesURL: URL) {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let resourceComponents = resourcesURL
            .standardizedFileURL
            .pathComponents
        guard resourceComponents.starts(with: rootComponents) else { return }
        let storedPath = resourceComponents
            .dropFirst(rootComponents.count)
            .joined(separator: "/")
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
            "Unet.mlmodelc",
            "SafetyChecker.mlmodelc",
            "adapter-schema.json",
            "vocab.json",
            "merges.txt",
        ]
        let hasRequiredResources = required.allSatisfy {
            FileManager.default.fileExists(
                atPath: url.appending(path: $0).path
            )
        }
        return hasRequiredResources
    }

    static func isStatefulLoRAResourcesDirectory(_ url: URL) -> Bool {
        isUsableResourcesDirectory(url)
    }

    static func usesCommonRevision(
        _ resourcesURL: URL,
        revision: String
    ) -> Bool {
        guard !revision.isEmpty,
              let installedRevision = try? String(
                contentsOf: resourcesURL.appending(
                    path: ".common-revision"
                ),
                encoding: .utf8
              ) else {
            return false
        }
        return installedRevision.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) == revision
    }
}
