import CoreML
import StableDiffusion
import XCTest
@testable import Clover

final class GenerationSettingsTests: XCTestCase {
    func testModelStorageIsVisibleInDocuments() {
        let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        XCTAssertEqual(
            ModelStorage.rootURL.standardizedFileURL,
            documentsURL
                .appending(path: "Models", directoryHint: .isDirectory)
                .standardizedFileURL
        )
    }

    func testModelInstallationStoresRelativePath() {
        let id = "relative-path-test"
        defer { ModelStorage.clearInstallation(id: id) }
        let resourcesURL = ModelStorage.rootURL
            .appending(path: "Installed", directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory)
            .appending(path: "Resources", directoryHint: .isDirectory)

        ModelStorage.recordInstallation(
            id: id,
            resourcesURL: resourcesURL
        )

        XCTAssertEqual(
            UserDefaults.standard.string(
                forKey: "clover-model-install-\(id)"
            ),
            "Installed/\(id)/Resources"
        )
    }

    func testSnapshotKeepsTheGenerationSeed() {
        var settings = GenerationSettings()
        settings.seed = 41

        let snapshot = GenerationSnapshot(settings: settings, imageIndex: 2)

        XCTAssertEqual(snapshot.seed, 41)
        XCTAssertEqual(snapshot.imageIndex, 2)
        XCTAssertEqual(snapshot.modelID, "base")
    }

    func testPromptTrimming() {
        var settings = GenerationSettings()
        settings.prompt = "  a glass greenhouse\n"

        XCTAssertEqual(settings.trimmedPrompt, "a glass greenhouse")
    }

    func testLegacySettingsDefaultToBaseModel() throws {
        let data = Data(
            """
            {
              "prompt": "a blue cat",
              "negativePrompt": "",
              "stepCount": 20,
              "guidanceScale": 7.5,
              "seed": 41,
              "imageCount": 1,
              "scheduler": "pndm",
              "randomGenerator": "numpy",
              "computeTarget": "neuralEngine"
            }
            """.utf8
        )

        let settings = try JSONDecoder().decode(
            GenerationSettings.self,
            from: data
        )

        XCTAssertEqual(settings.modelID, "base")
    }

    func testCatalogBuildsPinnedHuggingFaceURL() {
        let file = ModelCatalog.ResourceFile(
            path: "UnetChunk1.mlmodelc/weights/weight.bin",
            remotePath: "variants/base/UnetChunk1.mlmodelc/weights/weight.bin",
            size: 10,
            sha256: "abc"
        )

        let url = ModelCatalog.bootstrap.downloadURL(
            for: file,
            revision: "deadbeef"
        )

        XCTAssertEqual(
            url.host,
            "huggingface.co"
        )
        XCTAssertTrue(url.path.contains("deadbeef"))
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first?
                .value,
            "true"
        )
    }

    func testCatalogRoutesStyleFilesToTheirOwnRepository() {
        let file = ModelCatalog.ResourceFile(
            path: "UnetChunk1.mlmodelc/weights/weight.bin",
            remotePath: "Resources/UnetChunk1.mlmodelc/weights/weight.bin",
            size: 10,
            sha256: "abc"
        )

        let url = ModelCatalog.bootstrap.downloadURL(
            for: file,
            revision: "cafef00d",
            repository: "neonforestmist/clover-image-tiny-monet-lora-coreml"
        )

        XCTAssertEqual(
            url.path,
            "/neonforestmist/clover-image-tiny-monet-lora-coreml/resolve/cafef00d/Resources/UnetChunk1.mlmodelc/weights/weight.bin"
        )
    }

    func testCatalogDecodesWatercolorAnimeRepository() throws {
        let data = Data(
            """
            {
              "schema_version": 1,
              "catalog_version": "1.0.3",
              "repository": "neonforestmist/Clover-Image-Tiny-CoreML",
              "minimum_ios": "17.0",
              "resolution": [512, 512],
              "common": {
                "repository": "neonforestmist/Clover-Image-Tiny-CoreML",
                "revision": "basecommit",
                "download_size": 10,
                "files": []
              },
              "variants": [{
                "id": "watercolor-anime",
                "name": "Watercolor Anime",
                "summary": "Transparent watercolor washes",
                "trigger": "watercolor anime",
                "source_lora": "neonforestmist/clover-image-tiny-watercolor-anime-lora",
                "dataset": "neonforestmist/GPT_Watercolor_Anime_Style_Images",
                "repository": "neonforestmist/clover-image-tiny-watercolor-anime-lora-coreml",
                "revision": "stylecommit",
                "download_size": 20,
                "files": []
              }]
            }
            """.utf8
        )

        let catalog = try JSONDecoder().decode(ModelCatalog.self, from: data)
        let watercolor = try XCTUnwrap(
            catalog.variant(id: "watercolor-anime")
        )

        XCTAssertEqual(watercolor.trigger, "watercolor anime")
        XCTAssertEqual(
            watercolor.repository,
            "neonforestmist/clover-image-tiny-watercolor-anime-lora-coreml"
        )
    }

    func testCatalogDecodesStatefulLoRAStyle() throws {
        let data = Data(
            """
            {
              "schema_version": 3,
              "catalog_version": "3.0.0",
              "architecture": "stateful-lora",
              "repository": "neonforestmist/Clover-Image-Tiny-CoreML",
              "minimum_ios": "18.0",
              "resolution": [512, 512],
              "common": {
                "repository": "neonforestmist/Clover-Image-Tiny-CoreML",
                "revision": "sharedcommit",
                "download_size": 1600000000,
                "files": []
              },
              "variants": [{
                "id": "watercolor-anime",
                "name": "Watercolor Anime",
                "summary": "Transparent watercolor washes",
                "trigger": "watercolor anime",
                "source_lora": "neonforestmist/clover-image-tiny-watercolor-anime-lora",
                "dataset": "neonforestmist/GPT_Watercolor_Anime_Style_Images",
                "repository": "neonforestmist/clover-image-tiny-watercolor-anime-lora",
                "revision": "loracommit",
                "download_size": 6927128,
                "files": [{
                  "path": "Adapter.safetensors",
                  "remote_path": "pytorch_lora_weights.safetensors",
                  "size": 6927128,
                  "sha256": "37153c3084bf50c0355813c167da61612ed24695493c1d9479ecdb0e9cd958f2"
                }]
              }]
            }
            """.utf8
        )

        let catalog = try JSONDecoder().decode(ModelCatalog.self, from: data)
        let watercolor = try XCTUnwrap(
            catalog.variant(id: "watercolor-anime")
        )

        XCTAssertEqual(catalog.schemaVersion, 3)
        XCTAssertEqual(catalog.architecture, "stateful-lora")
        XCTAssertEqual(watercolor.coreMLFunctionName, "watercolor_anime")
        XCTAssertEqual(watercolor.downloadSize, 6_927_128)
        XCTAssertEqual(watercolor.files.first?.path, "Adapter.safetensors")
    }

    func testBootstrapStylesExposeExactLoRASize() {
        XCTAssertEqual(
            ModelCatalog.bootstrap.styleVariants.map(\.downloadSize),
            [6_927_128, 6_927_128, 6_927_128]
        )
    }

    func testLoRAAdapterParsesSafetensorsHeader() throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let header = try JSONSerialization.data(withJSONObject: [
            "lora.down.weight": [
                "dtype": "F32",
                "shape": [1],
                "data_offsets": [0, 4],
            ],
        ])
        var weights = Data()
        var headerLength = UInt64(header.count).littleEndian
        withUnsafeBytes(of: &headerLength) {
            weights.append(contentsOf: $0)
        }
        weights.append(header)
        var value = Float(0.5).bitPattern.littleEndian
        withUnsafeBytes(of: &value) {
            weights.append(contentsOf: $0)
        }
        let weightsURL = folder.appending(path: "Adapter.safetensors")
        try weights.write(to: weightsURL)

        let schema = Data(
            """
            {
              "schema_version": 1,
              "states": [{
                "source_key": "lora.down.weight",
                "state_name": "lora_down",
                "shape": [1],
                "element_count": 1
              }]
            }
            """.utf8
        )
        let schemaURL = folder.appending(path: "adapter-schema.json")
        try schema.write(to: schemaURL)

        let adapter = try LoRAAdapter(
            weightsAt: weightsURL,
            schemaAt: schemaURL
        )
        XCTAssertEqual(adapter.fileSize, weights.count)
        XCTAssertEqual(adapter.tensorCount, 1)
    }

    func testLocalMultifunctionModelFunctionsLoad() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip(
            "The current iOS Simulator runtime rejects Core ML multifunction selection; validate this test on an iPhone."
        )
#else
        let modelURL = ModelStorage.rootURL
            .appending(
                path: "LocalMultifunction/Resources",
                directoryHint: .isDirectory
            )
            .appending(
                path: "UnetChunk1.mlmodelc",
                directoryHint: .isDirectory
            )
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw XCTSkip("Local multifunction validation model is absent")
        }

        for functionName in [
            "base",
            "monet",
            "pointillism",
            "watercolor_anime",
        ] {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            configuration.functionName = functionName
            let asset = try MLModelAsset(url: modelURL)
            let model = try await MLModel.load(
                asset: asset,
                configuration: configuration
            )
            XCTAssertNotNil(
                model.modelDescription
                    .inputDescriptionsByName["sample"]
            )
        }
#endif
    }
}
