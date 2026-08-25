import SwiftUI
import UIKit

@main
struct CloverApp: App {
    @State private var library = ArtworkLibrary()
    @State private var modelManager = ModelManager()
    @State private var inpaintingModelManager = InpaintingModelManager()
    private let generator = GenerationServiceFactory.make()

    var body: some Scene {
        WindowGroup {
            AppShell(
                library: library,
                generator: generator,
                modelManager: modelManager,
                inpaintingModelManager: inpaintingModelManager
            )
            .task {
                #if DEBUG
                if await DeviceInpaintingSmokeTest.runIfRequested() {
                    return
                }
                #endif
                await modelManager.refreshCatalog()
            }
        }
    }
}

#if DEBUG
private enum DeviceInpaintingSmokeTest {
    static func runIfRequested() async -> Bool {
        guard ProcessInfo.processInfo.environment["CLOVER_INPAINT_SMOKE_TEST"]
                == "1" else {
            return false
        }
        guard ModelStorage.hasInpaintingResources else {
            print("CLOVER_INPAINT_SMOKE_FAIL missing inpainting resources")
            return true
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let canvas = UIGraphicsImageRenderer(
            size: CGSize(width: 512, height: 512),
            format: format
        )
        guard let source = UIImage(named: "SampleOutput") else {
            print("CLOVER_INPAINT_SMOKE_FAIL missing sample image")
            return true
        }
        let mask = canvas.image { renderer in
            UIColor.black.setFill()
            renderer.cgContext.fill(
                CGRect(x: 0, y: 0, width: 512, height: 512)
            )
            UIColor.white.setFill()
            renderer.cgContext.fill(
                CGRect(x: 176, y: 300, width: 160, height: 120)
            )
        }
        guard let sourceImage = source.cgImage, let maskImage = mask.cgImage else {
            print("CLOVER_INPAINT_SMOKE_FAIL could not create fixtures")
            return true
        }

        let documentsURL = ModelStorage.rootURL.deletingLastPathComponent()
        do {
            try source.pngData()?.write(
                to: documentsURL.appending(path: "inpaint-smoke-source.png"),
                options: .atomic
            )
            try mask.pngData()?.write(
                to: documentsURL.appending(path: "inpaint-smoke-mask.png"),
                options: .atomic
            )
        } catch {
            print("CLOVER_INPAINT_SMOKE_FAIL could not save fixtures: \(error.localizedDescription)")
            return true
        }

        var settings = GenerationSettings.inpaintingDefaults
        settings.prompt = "an orange cat"
        settings.negativePrompt = "blurry, distorted"
        settings.stepCount = 20
        settings.computeTarget = .neuralEngine
        settings.livePreviewEnabled = false

        do {
            let result = try await CoreMLInpaintingService().generate(
                resourcesURL: ModelStorage.inpaintingResourcesURL,
                request: InpaintingRequest(image: sourceImage, mask: maskImage),
                settings: settings,
                cancellation: GenerationCancellationToken()
            ) { update in
                let percent = Int((update.progress * 100).rounded())
                print("CLOVER_INPAINT_SMOKE_PROGRESS \(percent)")
            }
            guard let image = result.images.first?.cgImage else {
                print("CLOVER_INPAINT_SMOKE_FAIL no output image")
                return true
            }
            let outputURL = documentsURL.appending(path: "inpaint-smoke-result.png")
            guard let data = UIImage(cgImage: image).pngData() else {
                print("CLOVER_INPAINT_SMOKE_FAIL could not encode output")
                return true
            }
            try data.write(to: outputURL, options: .atomic)
            print("CLOVER_INPAINT_SMOKE_PASS \(outputURL.path)")
        } catch {
            print("CLOVER_INPAINT_SMOKE_FAIL \(error.localizedDescription)")
        }
        return true
    }
}
#endif
