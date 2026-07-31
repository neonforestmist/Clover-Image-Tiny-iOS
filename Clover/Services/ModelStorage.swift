import Foundation

enum ModelStorage {
    private static let installKeyPrefix = "clover-model-install-"

    static var rootURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appending(path: "Clover", directoryHint: .isDirectory)
        .appending(path: "Models", directoryHint: .isDirectory)
    }

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
