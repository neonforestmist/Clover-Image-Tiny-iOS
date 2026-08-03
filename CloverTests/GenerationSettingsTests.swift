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
        XCTAssertEqual(snapshot.outputRatio, .square)
        XCTAssertEqual(snapshot.customAspectWidth, 3)
        XCTAssertEqual(snapshot.customAspectHeight, 2)
    }

    func testPromptTrimming() {
        var settings = GenerationSettings()
        settings.prompt = "  a glass greenhouse\n"

        XCTAssertEqual(settings.trimmedPrompt, "a glass greenhouse")
    }

    func testStyleTriggerIsInsertedBeforePrompt() {
        var settings = GenerationSettings()
        settings.prompt = "a garden at sunrise"

        settings.applyStyleTrigger(
            "Monet Style",
            replacing: nil
        )

        XCTAssertEqual(
            settings.prompt,
            "Monet Style, a garden at sunrise"
        )
    }

    func testStyleTriggerIsInsertedWithEditableSpaceForEmptyPrompt() {
        var settings = GenerationSettings()

        settings.applyStyleTrigger(
            "watercolor anime",
            replacing: nil
        )

        XCTAssertEqual(settings.prompt, "watercolor anime, ")
    }

    func testSwitchingStylesReplacesTheTriggerPrefix() {
        var settings = GenerationSettings()
        settings.prompt = "Monet Style, a garden at sunrise"

        settings.applyStyleTrigger(
            "pointillism painting",
            replacing: "Monet Style"
        )

        XCTAssertEqual(
            settings.prompt,
            "pointillism painting, a garden at sunrise"
        )
    }

    func testReturningToCloverRemovesTheStyleTriggerPrefix() {
        var settings = GenerationSettings()
        settings.prompt = "watercolor anime, a quiet city"

        settings.applyStyleTrigger(
            nil,
            replacing: "watercolor anime"
        )

        XCTAssertEqual(settings.prompt, "a quiet city")
    }

    func testExistingStyleTriggerIsNotDuplicated() {
        var settings = GenerationSettings()
        settings.prompt = "MONET STYLE, a garden at sunrise"

        settings.applyStyleTrigger(
            "Monet Style",
            replacing: nil
        )

        XCTAssertEqual(
            settings.prompt,
            "MONET STYLE, a garden at sunrise"
        )
    }

    func testPreviouslySavedSettingsDefaultToBaseModel() throws {
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
        XCTAssertEqual(settings.outputRatio, .square)
        XCTAssertEqual(settings.customAspectWidth, 3)
        XCTAssertEqual(settings.customAspectHeight, 2)
    }

    func testOutputRatiosCropA512SquareWithoutResizing() {
        let source = CGSize(width: 512, height: 512)
        var settings = GenerationSettings()

        XCTAssertEqual(
            settings.croppedSize(from: source),
            CGSize(width: 512, height: 512)
        )

        settings.outputRatio = .portrait
        XCTAssertEqual(
            settings.croppedSize(from: source),
            CGSize(width: 410, height: 512)
        )

        settings.outputRatio = .cinematic
        XCTAssertEqual(
            settings.croppedSize(from: source),
            CGSize(width: 512, height: 288)
        )

        settings.outputRatio = .custom
        settings.customAspectWidth = 3
        settings.customAspectHeight = 2
        XCTAssertEqual(settings.outputDimensions, "3:2")
        XCTAssertEqual(
            settings.croppedSize(from: source),
            CGSize(width: 512, height: 341)
        )
    }

    func testImportedStylesDetectStandaloneSafetensors() throws {
        let filename = "Codex Test \(UUID().uuidString).safetensors"
        let url = ModelStorage.importedRootURL.appending(path: filename)
        try Data(repeating: 0, count: 9).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let style = try XCTUnwrap(
            ModelStorage.importedStyles().first {
                $0.weightsURL.standardizedFileURL == url.standardizedFileURL
            }
        )

        XCTAssertEqual(style.name, url.deletingPathExtension().lastPathComponent)
        XCTAssertEqual(style.fileSize, 9)
        XCTAssertTrue(style.requiresClover)
        XCTAssertEqual(
            ModelStorage.importedWeightsURL(for: style.id)?.standardizedFileURL,
            url.standardizedFileURL
        )
    }

    func testCatalogBuildsPinnedHuggingFaceURL() {
        let file = ModelCatalog.ResourceFile(
            path: "Unet.mlmodelc/weights/weight.bin",
            remotePath: "common/Unet.mlmodelc/weights/weight.bin",
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
            path: "Adapter.safetensors",
            remotePath: "Monet.safetensors",
            size: 6_927_128,
            sha256: "abc"
        )

        let url = ModelCatalog.bootstrap.downloadURL(
            for: file,
            revision: "cafef00d",
            repository: "neonforestmist/clover-image-tiny-monet-lora-coreml"
        )

        XCTAssertEqual(
            url.path,
            "/neonforestmist/clover-image-tiny-monet-lora-coreml/resolve/cafef00d/Monet.safetensors"
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
                "repository": "neonforestmist/clover-image-tiny-watercolor-anime-lora-coreml",
                "revision": "compactcoremlcommit",
                "download_size": 6927128,
                "files": [{
                  "path": "Adapter.safetensors",
                  "remote_path": "Watercolor-Anime.safetensors",
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
        XCTAssertEqual(watercolor.downloadSize, 6_927_128)
        XCTAssertEqual(
            watercolor.repository,
            "neonforestmist/clover-image-tiny-watercolor-anime-lora-coreml"
        )
        XCTAssertEqual(watercolor.files.first?.path, "Adapter.safetensors")
        XCTAssertEqual(
            watercolor.files.first?.remotePath,
            "Watercolor-Anime.safetensors"
        )
        XCTAssertEqual(
            watercolor.publicWeightsFilename,
            "Watercolor-Anime.safetensors"
        )
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
        let weightsURL = folder.appending(path: "My Custom Style.safetensors")
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

}
