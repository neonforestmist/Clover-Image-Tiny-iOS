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

    /// Builds the standalone 9-channel inpainting pipeline. Inpainting
    /// resources intentionally do not use Clover's stateful style adapter
    /// contract; they contain their own U-Net and VAE encoder.
    static func makeInpainting(
        resourcesURL: URL,
        configuration: MLModelConfiguration
    ) throws -> StableDiffusionPipeline {
        let urls = StableDiffusionPipeline.ResourceURLs(
            resourcesAt: resourcesURL
        )
        let hasFullUnet = FileManager.default.fileExists(
            atPath: urls.unetURL.path
        )
        let hasChunkedUnet = FileManager.default.fileExists(
            atPath: urls.unetChunk1URL.path
        ) && FileManager.default.fileExists(
            atPath: urls.unetChunk2URL.path
        )
        guard (hasFullUnet || hasChunkedUnet),
              FileManager.default.fileExists(atPath: urls.encoderURL.path) else {
            throw CloverPipelineError.incompatibleResources
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
        let unet: Unet
        if FileManager.default.fileExists(atPath: urls.unetChunk1URL.path),
           FileManager.default.fileExists(atPath: urls.unetChunk2URL.path) {
            unet = Unet(
                chunksAt: [urls.unetChunk1URL, urls.unetChunk2URL],
                configuration: configuration
            )
        } else {
            unet = Unet(
                modelAt: urls.unetURL,
                configuration: configuration
            )
        }
        let decoder = Decoder(
            modelAt: urls.decoderURL,
            configuration: configuration
        )
        let encoder = Encoder(
            modelAt: urls.encoderURL,
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
            encoder: encoder,
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

        let unetConfiguration = configuration.copy()
            as! MLModelConfiguration
        let fallbackComputeUnits: MLComputeUnits?
        #if targetEnvironment(simulator)
        unetConfiguration.computeUnits = .cpuOnly
        fallbackComputeUnits = nil
        #else
        // Clover's mutable LoRA state is not supported by the Neural Engine
        // execution planner. The GPU backend supports the stateful U-Net;
        // CPU remains a safe fallback if a device cannot build the GPU plan.
        // The remaining models continue to use the selected compute target.
        unetConfiguration.computeUnits = .cpuAndGPU
        fallbackComputeUnits = .cpuOnly
        #endif
        let unet = Unet(
            modelAt: urls.unetURL,
            configuration: unetConfiguration,
            loraAdapter: adapter,
            fallbackComputeUnits: fallbackComputeUnits
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
