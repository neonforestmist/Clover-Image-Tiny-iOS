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

enum CreateRuntimePolicy {
    /// Create is safety-free by construction so a valid decoded image cannot
    /// disappear after the user has already watched denoising previews.
    static let isSafetyCheckerEnabled = false
}

enum InpaintingRuntimePolicy {
    /// Inpainting edits user-selected pixels in a source image. Keeping this
    /// false by construction avoids a late safety-filter nil after previews.
    static let isSafetyCheckerEnabled = false
}

enum CloverPipelineFactory {
    static func make(
        resourcesURL: URL,
        styleWeights: [LoRAAdapter.WeightedWeights] = [],
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
            if !styleWeights.isEmpty {
                throw CloverPipelineError.importedStyleRequiresStatefulClover
            }
            throw CloverPipelineError.incompatibleResources
        }

        var resolvedWeights = styleWeights
        let bundledAdapterURL = resourcesURL.appending(
            path: "Adapter.safetensors"
        )
        if resolvedWeights.isEmpty,
           FileManager.default.fileExists(atPath: bundledAdapterURL.path) {
            resolvedWeights = [.init(url: bundledAdapterURL)]
        }
        let adapter = resolvedWeights.isEmpty
            ? nil
            : try LoRAAdapter(
                weightedWeights: resolvedWeights,
                schemaAt: adapterSchemaURL
            )

        return try makeStatefulLoRAPipeline(
            urls: urls,
            adapter: adapter,
            configuration: configuration
        )
    }

    /// Builds the standalone nine-channel inpainting pipeline. The preferred
    /// artifact is the stateless full-precision conversion of the published
    /// Diffusers inpainting U-Net.
    static func makeInpainting(
        resourcesURL: URL,
        styleWeights: [LoRAAdapter.WeightedWeights] = [],
        configuration: MLModelConfiguration
    ) throws -> StableDiffusionPipeline {
        let urls = StableDiffusionPipeline.ResourceURLs(
            resourcesAt: resourcesURL
        )
        let adapterSchemaURL = resourcesURL.appending(
            path: "adapter-schema.json"
        )
        let pipelineUnetURL = resourcesURL.appending(
            path: "UnetPipeline.mlmodelc"
        )
        let hasPipelineUnet = FileManager.default.fileExists(
            atPath: pipelineUnetURL.path
        )
        let hasChunkedUnet = FileManager.default.fileExists(
            atPath: urls.unetChunk1URL.path
        ) && FileManager.default.fileExists(atPath: urls.unetChunk2URL.path)
        guard hasPipelineUnet || hasChunkedUnet || FileManager.default.fileExists(
                  atPath: urls.unetURL.path
              ),
              FileManager.default.fileExists(atPath: urls.encoderURL.path),
              styleWeights.isEmpty || FileManager.default.fileExists(
                  atPath: adapterSchemaURL.path
              ) else {
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
        let adapter = styleWeights.isEmpty ? nil : try LoRAAdapter(
                weightedWeights: styleWeights,
                schemaAt: adapterSchemaURL
            )
        let unet: Unet
        if hasPipelineUnet, adapter == nil {
            let unetConfiguration = configuration.copy()
                as! MLModelConfiguration
            #if targetEnvironment(simulator)
            unetConfiguration.computeUnits = .cpuOnly
            #else
            unetConfiguration.computeUnits = .all
            #endif
            unet = Unet(
                modelAt: pipelineUnetURL,
                configuration: unetConfiguration
            )
        } else if hasChunkedUnet, adapter == nil {
            let unetConfiguration = configuration.copy()
                as! MLModelConfiguration
            #if targetEnvironment(simulator)
            unetConfiguration.computeUnits = .cpuOnly
            #else
            // Discover's ANE compiler cannot build the first 9-channel HQ
            // inpainting chunk. The compressed stateless chunks fit together
            // on the GPU, avoiding the stateful model's MPSGraph assertion.
            unetConfiguration.computeUnits = .cpuAndGPU
            #endif
            unet = Unet(
                chunksAt: [urls.unetChunk1URL, urls.unetChunk2URL],
                configuration: unetConfiguration
            )
        } else {
            unet = makeStatefulUnet(
                modelURL: urls.unetURL,
                adapter: adapter,
                configuration: configuration,
                // Discover (iPhone 15, iOS 26.6) aborts inside MPSGraph while
                // building a GPU plan for this stateful 9-channel U-Net:
                // `shape.count = 0 != strides.count = 4`. That assertion is
                // outside Swift error handling and terminates the whole app.
                // Keep the U-Net on CPU; text encoding and VAE processing can
                // still use the user's preferred compute units.
                useCPUOnly: true
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
        return StableDiffusionPipeline(
            textEncoder: textEncoder,
            unet: unet,
            decoder: decoder,
            encoder: encoder,
            safetyChecker: nil,
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

        let unet = makeStatefulUnet(
            modelURL: urls.unetURL,
            adapter: adapter,
            configuration: configuration
        )
        let decoder = Decoder(
            modelAt: urls.decoderURL,
            configuration: configuration
        )
        return StableDiffusionPipeline(
            textEncoder: textEncoder,
            unet: unet,
            decoder: decoder,
            encoder: nil,
            safetyChecker: nil,
            reduceMemory: true
        )
    }

    private static func makeStatefulUnet(
        modelURL: URL,
        adapter: LoRAAdapter?,
        configuration: MLModelConfiguration,
        useCPUOnly: Bool = false
    ) -> Unet {
        let unetConfiguration = configuration.copy()
            as! MLModelConfiguration
        let fallbackComputeUnits: MLComputeUnits?
        #if targetEnvironment(simulator)
        unetConfiguration.computeUnits = .cpuOnly
        fallbackComputeUnits = nil
        #else
        if useCPUOnly {
            unetConfiguration.computeUnits = .cpuOnly
            fallbackComputeUnits = nil
        } else {
            // Clover's mutable LoRA state is not supported by the Neural Engine
            // execution planner. The GPU backend supports the stateful U-Net;
            // CPU remains a safe fallback if a device cannot build the GPU plan.
            unetConfiguration.computeUnits = .cpuAndGPU
            fallbackComputeUnits = .cpuOnly
        }
        #endif
        return Unet(
            modelAt: modelURL,
            configuration: unetConfiguration,
            loraAdapter: adapter,
            fallbackComputeUnits: fallbackComputeUnits
        )
    }
}
