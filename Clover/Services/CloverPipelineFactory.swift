import CoreML
import Foundation
import StableDiffusion

enum CloverPipelineError: LocalizedError {
    case importedStyleRequiresStatefulClover

    var errorDescription: String? {
        switch self {
        case .importedStyleRequiresStatefulClover:
            "Imported .safetensors styles require the current Clover model."
        }
    }
}

enum CloverPipelineFactory {
    private struct FunctionManifest: Decodable {
        let functions: [String: String]
    }

    private static var isSafetyCheckerDisabled: Bool {
        UserDefaults.standard.bool(forKey: "DisableSafetyChecker")
    }

    static func make(
        resourcesURL: URL,
        modelID: String,
        styleWeightsURL: URL? = nil,
        configuration: MLModelConfiguration
    ) throws -> StableDiffusionPipeline {
        let urls = StableDiffusionPipeline.ResourceURLs(
            resourcesAt: resourcesURL
        )
        let adapterSchemaURL = resourcesURL.appending(
            path: "adapter-schema.json"
        )
        if FileManager.default.fileExists(atPath: urls.unetURL.path),
           FileManager.default.fileExists(atPath: adapterSchemaURL.path) {
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

        if styleWeightsURL != nil {
            throw CloverPipelineError.importedStyleRequiresStatefulClover
        }

        let functionManifestURL = resourcesURL.appending(
            path: "functions.json"
        )
        guard let data = try? Data(contentsOf: functionManifestURL),
              let manifest = try? JSONDecoder().decode(
                FunctionManifest.self,
                from: data
              ),
              let functionName = manifest.functions[modelID] else {
            // Compatibility with the original single-function Core ML
            // packages already installed by earlier app builds.
            return try StableDiffusionPipeline(
                resourcesAt: resourcesURL,
                controlNet: [],
                configuration: configuration,
                disableSafety: isSafetyCheckerDisabled,
                reduceMemory: true
            )
        }

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
        unetConfiguration.functionName = functionName
        let unet = Unet(
            chunksAt: [
                urls.unetChunk1URL,
                urls.unetChunk2URL,
            ],
            configuration: unetConfiguration
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

        // Mutable Core ML state is currently execution-planned reliably on
        // the GPU. Other pipeline components still honor the user's setting.
        let unetConfiguration = configuration.copy()
            as! MLModelConfiguration
        unetConfiguration.computeUnits = .cpuAndGPU
        unetConfiguration.functionName = nil
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
