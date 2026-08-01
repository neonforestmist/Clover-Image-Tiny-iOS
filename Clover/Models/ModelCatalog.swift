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
        /// The full fused U-Net size for a style, before it shares Clover's base weights.
        /// This is display metadata, not an additional download requirement.
        let styleModelSize: Int64?
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
            case styleModelSize = "style_model_size"
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

    // Metadata-only fallback shown before the first catalog refresh. Sizes and
    // triggers mirror the live per-style catalog; `files` are intentionally
    // empty so downloads wait for the verified manifest fetched on appear.
    static let bootstrap = ModelCatalog(
        schemaVersion: 2,
        catalogVersion: "loading",
        repository: "neonforestmist/Clover-Image-Tiny-CoreML",
        minimumIOS: "18.0",
        resolution: [512, 512],
        common: ResourceGroup(
            repository: nil,
            revision: "",
            downloadSize: 955_481_353,
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
                functionName: nil,
                repository: nil,
                revision: "",
                downloadSize: 647_756_972,
                styleModelSize: nil,
                files: []
            ),
            Variant(
                id: "monet",
                name: "Monet",
                summary: "Luminous impressionist color and brushwork",
                trigger: "Monet Style",
                sourceLoRA: "neonforestmist/clover-image-tiny-monet-lora",
                dataset: "neonforestmist/GPT_Monet_Style_Images",
                functionName: nil,
                repository: "neonforestmist/clover-image-tiny-monet-lora-coreml",
                revision: "",
                downloadSize: 647_756_986,
                styleModelSize: 647_756_986,
                files: []
            ),
            Variant(
                id: "pointillism",
                name: "Pointillism",
                summary: "Dense paint dots and luminous optical color",
                trigger: "pointillism painting",
                sourceLoRA: "neonforestmist/clover-image-tiny-pointillism-lora",
                dataset: "neonforestmist/GPT_Pointillism_Style_Images",
                functionName: nil,
                repository: "neonforestmist/clover-image-tiny-pointillism-lora-coreml",
                revision: "",
                downloadSize: 647_756_998,
                styleModelSize: 647_756_998,
                files: []
            ),
            Variant(
                id: "watercolor-anime",
                name: "Watercolor Anime",
                summary: "Transparent washes, soft ink, and paper texture",
                trigger: "watercolor anime",
                sourceLoRA: "neonforestmist/clover-image-tiny-watercolor-anime-lora",
                dataset: "neonforestmist/GPT_Watercolor_Anime_Style_Images",
                functionName: nil,
                repository: "neonforestmist/clover-image-tiny-watercolor-anime-lora-coreml",
                revision: "",
                downloadSize: 647_756_998,
                styleModelSize: 647_756_998,
                files: []
            )
        ]
    )

    func variant(id: String) -> Variant? {
        variants.first { $0.id == id }
    }

    var baseVariant: Variant? {
        variants.first { $0.id == "base" }
    }

    var styleVariants: [Variant] {
        variants.filter { $0.id != "base" }
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
