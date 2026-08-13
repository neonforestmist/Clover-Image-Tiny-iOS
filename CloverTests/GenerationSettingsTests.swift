import CoreML
import StableDiffusion
import UIKit
import XCTest
@testable import Clover

final class GenerationSettingsTests: XCTestCase {
    func testCoreMLExecutionPlanErrorsUseAnActionableMessage() {
        let rawError = NSError(
            domain: "com.apple.CoreML",
            code: 0,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Failed to build the model execution plan at /private/var/mobile/model.mil",
            ]
        )

        let error = GenerationError.presenting(rawError)

        XCTAssertEqual(
            error.localizedDescription,
            GenerationError.modelExecutionPlan.localizedDescription
        )
        XCTAssertFalse(error.localizedDescription.contains("/private/var"))
    }

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

    func testInstalledResourcesMustMatchTheSharedModelRevision() throws {
        let resourcesURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: resourcesURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: resourcesURL) }
        try "new-shared-revision".write(
            to: resourcesURL.appending(path: ".common-revision"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertTrue(
            ModelStorage.usesCommonRevision(
                resourcesURL,
                revision: "new-shared-revision"
            )
        )
        XCTAssertFalse(
            ModelStorage.usesCommonRevision(
                resourcesURL,
                revision: "old-shared-revision"
            )
        )
    }

    func testSharedModelUpdateRemovesOnlyOlderRevisions() throws {
        let sharedRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let current = sharedRoot.appending(
            path: "current-revision",
            directoryHint: .isDirectory
        )
        let obsolete = sharedRoot.appending(
            path: "obsolete-revision",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: current,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: obsolete,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: sharedRoot) }

        ModelStorage.removeObsoleteSharedRevisions(
            keeping: "current-revision",
            under: sharedRoot
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: obsolete.path))
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

    func testMultipleStyleTriggersAreAddedInSelectionOrder() {
        var settings = GenerationSettings()
        settings.prompt = "a garden at sunrise"

        settings.applyStyleTriggers(
            ["Monet Style", "pointillism painting"],
            replacing: []
        )

        XCTAssertEqual(
            settings.prompt,
            "Monet Style, pointillism painting, a garden at sunrise"
        )
    }

    func testRemovingOneStyleKeepsTheOtherTrigger() {
        var settings = GenerationSettings()
        settings.prompt = "Monet Style, pointillism painting, a garden"

        settings.applyStyleTriggers(
            ["pointillism painting"],
            replacing: ["Monet Style", "pointillism painting"]
        )

        XCTAssertEqual(settings.prompt, "pointillism painting, a garden")
    }

    func testLegacySingleStyleMigratesToStyleIDs() throws {
        let settings = try JSONDecoder().decode(
            GenerationSettings.self,
            from: Data("{\"modelID\":\"monet\"}".utf8)
        )

        XCTAssertEqual(settings.modelID, "base")
        XCTAssertEqual(settings.styleIDs, ["monet"])
    }

    func testStyleStrengthIsClamped() {
        var settings = GenerationSettings()
        settings.styleIDs = ["monet"]

        settings.setStyleStrength(9, for: "monet")

        XCTAssertEqual(settings.styleStrength(for: "monet"), 1.5)
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
        XCTAssertFalse(settings.livePreviewEnabled)
        XCTAssertEqual(settings.previewInterval, 5)
    }

    func testLivePreviewSettingsDecodeAndClampInvalidInterval() throws {
        let data = Data(
            """
            {
              "livePreviewEnabled": true,
              "previewInterval": 0
            }
            """.utf8
        )

        let settings = try JSONDecoder().decode(
            GenerationSettings.self,
            from: data
        )

        XCTAssertTrue(settings.livePreviewEnabled)
        XCTAssertEqual(settings.previewInterval, 1)
    }

    func testLivePreviewIntervalClampsAtTen() throws {
        let data = Data(
            """
            {
              "livePreviewEnabled": true,
              "previewInterval": 99
            }
            """.utf8
        )

        let settings = try JSONDecoder().decode(
            GenerationSettings.self,
            from: data
        )

        XCTAssertEqual(settings.previewInterval, 10)
    }

    @MainActor
    func testArtworkLibraryStoresPreviewTimelineUnderOneArtwork() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "CloverArtworkTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 16, height: 16)
        ).image { context in
            UIColor.systemGreen.setFill()
            context.fill(
                CGRect(x: 0, y: 0, width: 16, height: 16)
            )
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let jpegData = try XCTUnwrap(
            image.jpegData(compressionQuality: 0.86)
        )
        var settings = GenerationSettings()
        settings.prompt = "a green square"
        settings.stepCount = 15

        let library = ArtworkLibrary(directoryURL: directory)
        let additions = try library.add(
            images: [GeneratedImage(cgImage: cgImage, imageIndex: 0)],
            previewFrames: [
                GeneratedPreviewFrame(
                    jpegData: jpegData,
                    step: 5,
                    stepCount: 15,
                    imageIndex: 0
                ),
                GeneratedPreviewFrame(
                    jpegData: jpegData,
                    step: 10,
                    stepCount: 15,
                    imageIndex: 0
                ),
                GeneratedPreviewFrame(
                    jpegData: jpegData,
                    step: 15,
                    stepCount: 15,
                    imageIndex: 0
                ),
            ],
            settings: settings
        )

        let artwork = try XCTUnwrap(additions.first)
        XCTAssertEqual(additions.count, 1)
        XCTAssertEqual(library.artworks.count, 1)
        XCTAssertEqual(
            library.previewFrames(for: artwork).map(\.step),
            [5, 10]
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: library.imageURL(for: artwork).path
            )
        )
        for frame in artwork.previewFrames {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: library.previewURL(
                        for: artwork,
                        frame: frame
                    ).path
                )
            )
        }
        XCTAssertEqual(
            library.frameURL(for: artwork, at: 2),
            library.imageURL(for: artwork)
        )
        XCTAssertEqual(library.frameStep(for: artwork, at: 2), 15)

        let archive = try library.stepsArchiveData(for: artwork)
        XCTAssertNotNil(archive.range(of: Data("step-0005.jpg".utf8)))
        XCTAssertNotNil(archive.range(of: Data("step-0010.jpg".utf8)))
        XCTAssertNotNil(
            archive.range(of: Data("step-0015-final.png".utf8))
        )
        XCTAssertNil(archive.range(of: Data("step-0015.jpg".utf8)))

        library.delete(artwork)
        XCTAssertTrue(library.artworks.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: library.imageURL(for: artwork).path
            )
        )
    }

    func testPreviewGenerationServiceReturnsSavedStepFrames() async throws {
        var settings = GenerationSettings()
        settings.livePreviewEnabled = true
        settings.previewInterval = 5
        settings.stepCount = 12
        settings.imageCount = 1

        let result = try await PreviewGenerationService().generate(
            settings: settings,
            cancellation: GenerationCancellationToken()
        ) { _ in }

        XCTAssertEqual(result.images.count, 1)
        XCTAssertEqual(result.previewFrames.map(\.step), [5, 10])
        XCTAssertTrue(result.previewFrames.allSatisfy { !$0.jpegData.isEmpty })
    }

    func testLatentPreviewRendererCreatesDisplaySizedImage() throws {
        let latent = MLShapedArray<Float32>(
            repeating: 0.25,
            shape: [1, 4, 8, 8]
        )

        let image = try XCTUnwrap(LatentPreviewRenderer.render(latent))

        XCTAssertEqual(image.width, 512)
        XCTAssertEqual(image.height, 512)
    }

    func testGenerationStepMapperKeepsFinalRequestedStepAtTimelineTail() {
        XCTAssertEqual(
            GenerationStepMapper.visibleStep(
                updateStep: 7,
                requestedStepCount: 8
            ),
            8
        )
        XCTAssertTrue(
            GenerationStepMapper.representsRequestedStep(
                updateStep: 7,
                requestedStepCount: 8
            )
        )
        XCTAssertFalse(
            GenerationStepMapper.representsRequestedStep(
                updateStep: 8,
                requestedStepCount: 8
            )
        )
    }

    func testStoredZIPArchiveUsesStandardHeadersAndChecksums() throws {
        let archive = try StoredZIPArchive.data(
            entries: [
                .init(
                    name: "step-0001.jpg",
                    data: Data("123456789".utf8)
                ),
                .init(
                    name: "step-0002-final.png",
                    data: Data("final".utf8)
                ),
            ]
        )

        XCTAssertEqual(
            StoredZIPArchive.crc32(Data("123456789".utf8)),
            0xCBF4_3926
        )
        XCTAssertEqual(Array(archive.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertEqual(
            Array(archive.suffix(22).prefix(4)),
            [0x50, 0x4B, 0x05, 0x06]
        )
        XCTAssertNotNil(archive.range(of: Data("step-0001.jpg".utf8)))
        XCTAssertNotNil(
            archive.range(of: Data("step-0002-final.png".utf8))
        )
    }

    func testLatentPreviewRendererRejectsUnsupportedShape() {
        let latent = MLShapedArray<Float32>(
            repeating: 0,
            shape: [1, 3, 8, 8]
        )

        XCTAssertNil(LatentPreviewRenderer.render(latent))
    }

    func testEmptyGenerationMessageDoesNotExposeSafetyChecker() {
        let message = GenerationError.noImages.localizedDescription

        XCTAssertFalse(message.localizedCaseInsensitiveContains("safety"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("try"))
    }

    func testSafetyCheckerFailureIsPresentedAsGenericGenerationError() {
        let internalError = NSError(
            domain: "com.apple.CoreML",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "The safety checker failed.",
            ]
        )

        let message = GenerationError.presenting(internalError).localizedDescription

        XCTAssertEqual(message, GenerationError.noImages.localizedDescription)
        XCTAssertFalse(message.localizedCaseInsensitiveContains("safety"))
    }

    func testCreateSafetyCheckerIsDisabledByConstruction() {
        XCTAssertFalse(CreateRuntimePolicy.isSafetyCheckerEnabled)
    }

    func testGenerationActivityExplainsPostDenoisingWork() {
        XCTAssertEqual(
            GenerationActivity.decoding(
                imageIndex: 0,
                imageCount: 1
            ).title,
            "Decoding final image…"
        )
        XCTAssertEqual(
            GenerationActivity.validating.title,
            "Checking final image…"
        )
        XCTAssertEqual(
            GenerationActivity.saving.title,
            "Saving to Library…"
        )
        XCTAssertEqual(
            GenerationActivity.retryingEdit(attempt: 2, attemptCount: 3).title,
            "Retrying edit · Attempt 2 of 3…"
        )
    }

    func testGenerationUpdatesNeverExposeOneHundredPercentWhileWorking() {
        let update = GenerationUpdate(
            progress: 1,
            preview: nil,
            activity: .saving
        )

        XCTAssertEqual(update.progress, 0.99)
    }

    func testPreviouslySavedAspectRatioFieldsAreIgnored() throws {
        let data = Data(
            """
            {
              "prompt": "a blue cat",
              "outputRatio": "custom",
              "customAspectWidth": 3,
              "customAspectHeight": 2
            }
            """.utf8
        )

        let settings = try JSONDecoder().decode(
            GenerationSettings.self,
            from: data
        )
        let encoded = try JSONEncoder().encode(settings)
        let encodedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(settings.prompt, "a blue cat")
        XCTAssertNil(encodedObject["outputRatio"])
        XCTAssertNil(encodedObject["customAspectWidth"])
        XCTAssertNil(encodedObject["customAspectHeight"])
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
            ModelCatalog.bootstrap.common.downloadSize,
            1_603_241_669
        )
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
                "shape": [1, 1],
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
                "shape": [1, 1, 1, 1],
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

    func testLoRAAdapterAcceptsMultipleWeightsWithSlotSchema() throws {
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
            "unet.block.lora.down.weight": [
                "dtype": "F32",
                "shape": [1, 1, 1, 1],
                "data_offsets": [0, 4],
            ],
        ])
        func makeWeights(_ value: Float, name: String) throws -> URL {
            var weights = Data()
            var headerLength = UInt64(header.count).littleEndian
            withUnsafeBytes(of: &headerLength) {
                weights.append(contentsOf: $0)
            }
            weights.append(header)
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) {
                weights.append(contentsOf: $0)
            }
            let url = folder.appending(path: name)
            try weights.write(to: url)
            return url
        }
        let first = try makeWeights(0.25, name: "first.safetensors")
        let second = try makeWeights(0.75, name: "second.safetensors")
        let schemaURL = folder.appending(path: "adapter-schema.json")
        try Data(
            """
            {
              "schema_version": 2,
              "max_adapter_count": 3,
              "states": [{
                "source_key": "unet.block.lora.down.weight",
                "state_name": "block_lora_down",
                "shape": [1, 1, 1, 1],
                "state_shape": [3, 1, 1, 1],
                "element_count": 1
              }]
            }
            """.utf8
        ).write(to: schemaURL)

        let adapter = try LoRAAdapter(
            weightedWeights: [
                .init(url: first, scale: 0.5),
                .init(url: second, scale: 1.25),
            ],
            schemaAt: schemaURL
        )

        XCTAssertEqual(adapter.maxAdapterCount, 3)
        XCTAssertEqual(adapter.tensorCount, 2)
    }

}
