import Foundation

enum ModelStorage {
    private static let installKeyPrefix = "clover-model-install-"
    private static let unusedCommonComponents: Set<String> = [
        "SafetyChecker.mlmodelc",
    ]

    /// Prefix marking a model the user side-loaded via the Files app rather
    /// than one downloaded from the catalog.
    static let importedIDPrefix = "imported:"

    /// A style the user placed in On My iPhone › Clover › Imported Styles.
    struct ImportedStyle: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let weightsURL: URL
        let fileSize: Int64?
        let trigger: String?

        var requiresClover: Bool {
            true
        }

        var detail: String {
            guard let fileSize else { return "Clover LoRA" }
            return "Clover LoRA · \(fileSize.formatted(.byteCount(style: .file)))"
        }
    }

    private struct ImportedStyleMetadata: Codable {
        var trigger: String?
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
            "TextEncoder.mlmodelc/model.mil",
            "VAEEncoder.mlmodelc/model.mil",
            "VAEDecoder.mlmodelc/model.mil",
            "vocab.json",
            "merges.txt",
        ]
        let hasSingleUnet = [
            "UnetPipeline.mlmodelc",
            "Unet.mlmodelc",
        ].contains {
            FileManager.default.fileExists(atPath: url.appending(path: $0).path)
        }
        let hasChunkedUnet = ["UnetChunk1.mlmodelc", "UnetChunk2.mlmodelc"]
            .allSatisfy {
                FileManager.default.fileExists(
                    atPath: url.appending(path: $0).path
                )
            }
        return (hasSingleUnet || hasChunkedUnet) && required.allSatisfy {
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
                        fileSize: Int64(fileSize),
                        trigger: importedTrigger(for: entry)
                    )
                )
            }
        }
        return styles.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func setImportedTrigger(
        _ trigger: String?,
        for weightsURL: URL
    ) throws {
        let cleaned = trigger.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ","))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let metadataURL = importedMetadataURL(for: weightsURL)
        if cleaned?.isEmpty != false {
            if FileManager.default.fileExists(atPath: metadataURL.path) {
                try FileManager.default.removeItem(at: metadataURL)
            }
            return
        }
        let data = try JSONEncoder().encode(
            ImportedStyleMetadata(trigger: cleaned)
        )
        try data.write(to: metadataURL, options: .atomic)
    }

    private static func importedTrigger(for weightsURL: URL) -> String? {
        let metadataURL = importedMetadataURL(for: weightsURL)
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(
                  ImportedStyleMetadata.self,
                  from: data
              ) else {
            return nil
        }
        let cleaned = metadata.trigger?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return cleaned?.isEmpty == false ? cleaned : nil
    }

    private static func importedMetadataURL(for weightsURL: URL) -> URL {
        weightsURL
            .deletingPathExtension()
            .appendingPathExtension("clover-style.json")
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

    /// Clover intentionally constructs both generation pipelines without a
    /// safety checker. Older catalogs nevertheless installed its 580 MB model,
    /// which can leave too little room for Core ML to compile the inpainting
    /// execution plan. Reclaim that unused model and abandoned Core ML plan
    /// staging bundles; both are private, rebuildable app data.
    static func reclaimUnusedRuntimeFiles() {
        let fileManager = FileManager.default
        if let revisions = try? fileManager.contentsOfDirectory(
            at: sharedRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for revision in revisions {
                for component in unusedCommonComponents {
                    try? fileManager.removeItem(
                        at: revision.appending(path: component)
                    )
                }
            }
        }

        let inpaintingURL = inpaintingResourcesURL
        let hasStatelessChunks = ["UnetChunk1.mlmodelc", "UnetChunk2.mlmodelc"]
            .allSatisfy {
                fileManager.fileExists(
                    atPath: inpaintingURL.appending(path: $0).path
                )
            }
        let statelessMigrationMarker = inpaintingURL.appending(
            path: ".clover-stateless-runtime-cleaned"
        )
        if hasStatelessChunks,
           !fileManager.fileExists(atPath: statelessMigrationMarker.path) {
            // The stateless release replaces the former full stateful U-Net.
            // Keeping both consumes another ~821 MB on the phone and can leave
            // Core ML without enough room to build the new execution plans.
            try? fileManager.removeItem(
                at: inpaintingURL.appending(path: "Unet.mlmodelc")
            )
        }

        guard let caches = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return }
        let bundleCache = caches
            .appending(path: Bundle.main.bundleIdentifier ?? "", directoryHint: .isDirectory)
            .appending(path: "com.apple.e5rt.e5bundlecache", directoryHint: .isDirectory)
        if hasStatelessChunks,
           !fileManager.fileExists(atPath: statelessMigrationMarker.path) {
            // Plans compiled for the stateful model are incompatible with the
            // stateless chunks and are entirely rebuildable.
            try? fileManager.removeItem(at: bundleCache)
            try? "cleaned\n".write(
                to: statelessMigrationMarker,
                atomically: true,
                encoding: .utf8
            )
            return
        }
        guard let enumerator = fileManager.enumerator(
            at: bundleCache,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var abandonedBundles: [URL] = []
        for case let url as URL in enumerator
        where url.lastPathComponent.contains(".tmp.") {
            abandonedBundles.append(url)
            enumerator.skipDescendants()
        }
        for url in abandonedBundles {
            try? fileManager.removeItem(at: url)
        }
    }

    static func runtimeCommonFiles(
        _ files: [ModelCatalog.ResourceFile]
    ) -> [ModelCatalog.ResourceFile] {
        files.filter { file in
            guard let component = file.path.split(separator: "/").first else {
                return false
            }
            return !unusedCommonComponents.contains(String(component))
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
            if isUsableInstallationDirectory(url, id: id) {
                return url
            }
        }

        // The visible model folder is the durable source of truth. Recover
        // its lightweight UserDefaults pointer after an app restore, test
        // reset, or preferences migration instead of asking the user to
        // download gigabytes that are already present in Documents.
        let installedRoot = rootURL
            .appending(path: "Installed", directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory)
        if let candidates = try? FileManager.default.contentsOfDirectory(
            at: installedRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let recovered = candidates.map { candidate in
                let nested = candidate.appending(
                    path: "Resources",
                    directoryHint: .isDirectory
                )
                return isUsableInstallationDirectory(nested, id: id)
                    ? nested
                    : candidate
            }
            .filter { isUsableInstallationDirectory($0, id: id) }
            .sorted(by: { left, right in
                let leftDate = (try? left.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                let rightDate = (try? right.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            })
            .first
            if let recovered {
                recordInstallation(id: id, resourcesURL: recovered)
                return recovered
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
        guard id != "base" else {
            return nil
        }

        if let resources = resourcesURL(for: id) {
            let weights = resources.appending(path: "Adapter.safetensors")
            if FileManager.default.fileExists(atPath: weights.path) {
                return weights
            }
        }

        // Variant payloads are the durable source of truth; Installed only
        // contains lightweight links. Recover directly from a downloaded
        // adapter after an Xcode reinstall, app-container migration, or lost
        // UserDefaults pointer so generation never asks for a second download.
        let variantRoot = rootURL
            .appending(path: "Variants", directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory)
        guard let revisions = try? FileManager.default.contentsOfDirectory(
            at: variantRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return revisions.compactMap { revision -> URL? in
            let weights = revision.appending(path: "Adapter.safetensors")
            return FileManager.default.fileExists(atPath: weights.path)
                ? weights
                : nil
        }
        .sorted { left, right in
            let leftDate = (try? left.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            let rightDate = (try? right.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }
        .first
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

    private static func isUsableInstallationDirectory(
        _ url: URL,
        id: String
    ) -> Bool {
        if id == "base" {
            return isUsableResourcesDirectory(url)
        }
        return FileManager.default.fileExists(
            atPath: url.appending(path: "Adapter.safetensors").path
        )
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
