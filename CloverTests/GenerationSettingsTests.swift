import CoreML
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

    func testCatalogDecodesMultifunctionStyle() throws {
        let data = Data(
            """
            {
              "schema_version": 2,
              "catalog_version": "2.0.0",
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
                "function_name": "watercolor_anime",
                "repository": "neonforestmist/Clover-Image-Tiny-CoreML",
                "revision": "sharedcommit",
                "download_size": 0,
                "style_model_size": 647757010,
                "files": []
              }]
            }
            """.utf8
        )

        let catalog = try JSONDecoder().decode(ModelCatalog.self, from: data)
        let watercolor = try XCTUnwrap(
            catalog.variant(id: "watercolor-anime")
        )

        XCTAssertEqual(catalog.schemaVersion, 2)
        XCTAssertEqual(watercolor.coreMLFunctionName, "watercolor_anime")
        XCTAssertEqual(watercolor.downloadSize, 0)
        XCTAssertEqual(watercolor.styleModelSize, 647_757_010)
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
