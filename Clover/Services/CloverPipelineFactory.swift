import CoreML
import Foundation
import StableDiffusion

enum CloverPipelineFactory {
    private struct FunctionManifest: Decodable {
        let functions: [String: String]
    }

    static func make(
        resourcesURL: URL,
        modelID: String,
        configuration: MLModelConfiguration
    ) throws -> StableDiffusionPipeline {
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
                reduceMemory: true
            )
        }

        let urls = StableDiffusionPipeline.ResourceURLs(
            resourcesAt: resourcesURL
        )
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
        let safetyChecker: SafetyChecker? = FileManager.default.fileExists(
            atPath: urls.safetyCheckerURL.path
        ) ? SafetyChecker(
            modelAt: urls.safetyCheckerURL,
            configuration: configuration
        ) : nil

        return StableDiffusionPipeline(
            textEncoder: textEncoder,
            unet: unet,
            decoder: decoder,
            encoder: nil,
            safetyChecker: safetyChecker,
            reduceMemory: true
        )
    }
}
