import XCTest
@testable import Clover

final class GenerationSettingsTests: XCTestCase {
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
}
