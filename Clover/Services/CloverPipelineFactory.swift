import CoreML
import Foundation
import StableDiffusion

enum CloverPipelineError: LocalizedError {
    case importedStyleRequiresStatefulClover
    case incompatibleResources

    var errorDescription: String? {
        switch self {
        case .importedStyleRequiresStatefulClover:
            "Imported .safetensors styles require the current Clover model."
        case .incompatibleResources:
            "These model files aren’t compatible with this version of Clover. Remove the download and install Clover again."
        }
    }
}

enum CloverPipelineFactory {
    static var isSafetyCheckerDisabled: Bool {
        UserDefaults.standard.bool(forKey: "DisableSafetyChecker")
    }

    static func make(
        resourcesURL: URL,
        styleWeightsURL: URL? = nil,
        configuration: MLModelConfiguration
    ) throws -> StableDiffusionPipeline {
        let urls = StableDiffusionPipeline.ResourceURLs(
            resourcesAt: resourcesURL
        )
        let adapterSchemaURL = resourcesURL.appending(
            path: "adapter-schema.json"
        )
        guard FileManager.default.fileExists(atPath: urls.unetURL.path),
              FileManager.default.fileExists(
                atPath: adapterSchemaURL.path
              ) else {
            if styleWeightsURL != nil {
                throw CloverPipelineError.importedStyleRequiresStatefulClover
            }
            throw CloverPipelineError.incompatibleResources
        }

        let adapterURL = styleWeightsURL ?? resourcesURL.appending(
            path: "Adapter.safetensors"
        )
        let adapter = FileManager.default.fileExists(
            atPath: adapterURL.path
        ) ? try LoRAAdapter(
            weightsAt: adapterURL,
            schemaAt: adapterSchemaURL
        ) : nil

        return try makeStatefulLoRAPipeline(
            urls: urls,
            adapter: adapter,
            configuration: configuration
        )
    }

    private static func makeStatefulLoRAPipeline(
        urls: StableDiffusionPipeline.ResourceURLs,
        adapter: LoRAAdapter?,
        configuration: MLModelConfiguration
    ) throws -> StableDiffusionPipeline {
        let tokenizer = try BPETokenizer(
            mergesAt: urls.mergesURL,
            vocabularyAt: urls.vocabURL
        )
        let textEncoder = TextEncoder(
            tokenizer: tokenizer,
            modelAt: urls.textEncoderURL,
            configuration: configuration
        )

        let unetConfiguration = configuration.copy()
            as! MLModelConfiguration
        let unet = Unet(
            modelAt: urls.unetURL,
            configuration: unetConfiguration,
            loraAdapter: adapter
        )
        let decoder = Decoder(
            modelAt: urls.decoderURL,
            configuration: configuration
        )
        let safetyChecker = makeSafetyChecker(
            at: urls.safetyCheckerURL,
            configuration: configuration
        )

        return StableDiffusionPipeline(
            textEncoder: textEncoder,
            unet: unet,
            decoder: decoder,
            encoder: nil,
            safetyChecker: safetyChecker,
            reduceMemory: true
        )
    }

    private static func makeSafetyChecker(
        at url: URL,
        configuration: MLModelConfiguration
    ) -> SafetyChecker? {
        guard !isSafetyCheckerDisabled,
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return SafetyChecker(
            modelAt: url,
            configuration: configuration
        )
    }
}
