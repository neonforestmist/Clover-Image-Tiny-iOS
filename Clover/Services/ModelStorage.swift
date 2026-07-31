import Foundation

enum ModelStorage {
    private static let installKeyPrefix = "clover-model-install-"

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
        if let stored = UserDefaults.standard.string(
            forKey: installKeyPrefix + id
        ) {
            let url = URL(filePath: stored, directoryHint: .isDirectory)
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

    static func recordInstallation(id: String, resourcesURL: URL) {
        UserDefaults.standard.set(
            resourcesURL.path,
            forKey: installKeyPrefix + id
        )
    }

    static func clearInstallation(id: String) {
        UserDefaults.standard.removeObject(forKey: installKeyPrefix + id)
    }

    static func isUsableResourcesDirectory(_ url: URL) -> Bool {
        let required = [
            "TextEncoder.mlmodelc",
            "UnetChunk1.mlmodelc",
            "UnetChunk2.mlmodelc",
            "VAEDecoder.mlmodelc",
            "SafetyChecker.mlmodelc",
            "vocab.json",
            "merges.txt",
        ]
        return required.allSatisfy {
            FileManager.default.fileExists(
                atPath: url.appending(path: $0).path
            )
        }
    }
}
