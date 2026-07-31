import Foundation

struct ModelCatalog: Codable, Equatable, Sendable {
    struct ResourceFile: Codable, Equatable, Sendable {
        let path: String
        let remotePath: String
        let size: Int64
        let sha256: String

        enum CodingKeys: String, CodingKey {
            case path
            case remotePath = "remote_path"
            case size
            case sha256
        }
    }

    struct ResourceGroup: Codable, Equatable, Sendable {
        let repository: String?
        let revision: String
        let downloadSize: Int64
        let files: [ResourceFile]

        enum CodingKeys: String, CodingKey {
            case repository
            case revision
            case downloadSize = "download_size"
            case files
        }
    }

    struct Variant: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let summary: String
        let trigger: String?
        let sourceLoRA: String?
        let dataset: String?
        let functionName: String?
        let repository: String?
        let revision: String
        let downloadSize: Int64
        let files: [ResourceFile]

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case summary
            case trigger
            case sourceLoRA = "source_lora"
            case dataset
            case functionName = "function_name"
            case repository
            case revision
            case downloadSize = "download_size"
            case files
        }

        var coreMLFunctionName: String {
            functionName
                ?? id.replacingOccurrences(of: "-", with: "_")
        }
    }

    let schemaVersion: Int
    let catalogVersion: String
    let repository: String
    let minimumIOS: String
    let resolution: [Int]
    let common: ResourceGroup
    let variants: [Variant]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case catalogVersion = "catalog_version"
        case repository
        case minimumIOS = "minimum_ios"
        case resolution
        case common
        case variants
    }

    static let remoteURL = URL(
        string: "https://huggingface.co/neonforestmist/Clover-Image-Tiny-CoreML/resolve/main/manifest.json"
    )!

    static let bootstrap = ModelCatalog(
        schemaVersion: 2,
        catalogVersion: "loading",
        repository: "neonforestmist/Clover-Image-Tiny-CoreML",
        minimumIOS: "18.0",
        resolution: [512, 512],
        common: ResourceGroup(
            repository: nil,
            revision: "",
            downloadSize: 0,
            files: []
        ),
        variants: [
            Variant(
                id: "base",
                name: "Clover",
                summary: "Original Clover Image Tiny",
                trigger: nil,
                sourceLoRA: nil,
                dataset: nil,
                functionName: "base",
                repository: nil,
                revision: "",
                downloadSize: 0,
                files: []
            )
        ]
    )

    func variant(id: String) -> Variant? {
        variants.first { $0.id == id }
    }

    func downloadURL(
        for file: ResourceFile,
        revision: String,
        repository resourceRepository: String? = nil
    ) -> URL {
        var components = URLComponents(string: "https://huggingface.co")!
        let repository = resourceRepository ?? repository
        components.path = "/\(repository)/resolve/\(revision)/\(file.remotePath)"
        components.queryItems = [URLQueryItem(name: "download", value: "true")]
        return components.url!
    }

    var hubURL: URL {
        URL(string: "https://huggingface.co/\(repository)")!
    }
}
