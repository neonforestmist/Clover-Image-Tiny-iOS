import CoreGraphics
import XCTest

final class CloverUITests: XCTestCase {
    @MainActor
    func testInpaintingTabIsBetweenCreateAndLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset", "-ui-testing-preview"]
        app.launch()

        let tabs = app.tabBars.buttons
        XCTAssertTrue(tabs["Create"].waitForExistence(timeout: 5))
        XCTAssertTrue(tabs["Inpainting"].exists)
        XCTAssertTrue(tabs["Library"].exists)

        tabs["Inpainting"].tap()
        XCTAssertTrue(
            app.navigationBars["Inpainting"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["inpainting-source-picker"].exists)
        XCTAssertTrue(app.otherElements["inpainting-model-status"].exists)
        XCTAssertTrue(app.buttons["inpainting-generate-button"].exists)

        let settings = app.buttons["inpainting-settings-button"]
        XCTAssertTrue(settings.exists)
        settings.tap()
        XCTAssertTrue(
            app.navigationBars["Inpainting Settings"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.steppers["inpainting-steps-stepper"].exists)
        XCTAssertTrue(app.otherElements["inpainting-steps-slider"].exists)
        XCTAssertTrue(app.sliders["inpainting-guidance-slider"].exists)
        let livePreview = app.switches["inpainting-live-preview-toggle"]
        for _ in 0..<3 where !livePreview.exists {
            app.swipeUp()
        }
        XCTAssertTrue(livePreview.waitForExistence(timeout: 3))
        let previewInterval = app.otherElements[
            "inpainting-preview-interval-slider"
        ]
        for _ in 0..<3 where !previewInterval.exists {
            app.swipeUp()
        }
        XCTAssertTrue(previewInterval.waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
    }

    @MainActor
    func testParametersGenerationAndLibraryFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset", "-ui-testing-preview"]
        app.launch()

        let models = app.buttons["model-picker-button"]
        XCTAssertTrue(models.waitForExistence(timeout: 5))
        models.tap()
        XCTAssertTrue(
            app.navigationBars["Models & Styles"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.otherElements["model-base"].exists)

        let useMonet = app.buttons["Use Monet"]
        XCTAssertTrue(useMonet.waitForExistence(timeout: 3))
        useMonet.tap()
        XCTAssertFalse(app.buttons["Remove Download"].exists)

        let manageMonet = app.buttons["manage-download-monet"]
        XCTAssertTrue(manageMonet.waitForExistence(timeout: 3))

        app.buttons["Done"].tap()

        let parameters = app.buttons["parameters-button"]
        XCTAssertTrue(parameters.waitForExistence(timeout: 5))
        parameters.tap()

        XCTAssertTrue(app.navigationBars["Parameters"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.steppers["steps-stepper"].exists)
        XCTAssertTrue(app.otherElements["steps-slider"].exists)
        XCTAssertTrue(app.sliders["guidance-slider"].exists)
        XCTAssertTrue(app.steppers["image-count-stepper"].exists)
        let seed = app.textFields["seed-field"]
        if !seed.exists {
            app.swipeUp()
        }
        XCTAssertTrue(seed.waitForExistence(timeout: 3))

        let livePreview = app.switches["live-preview-toggle"]
        for _ in 0..<3 where !livePreview.exists {
            app.swipeUp()
        }
        XCTAssertTrue(livePreview.waitForExistence(timeout: 3))
        livePreview.coordinate(
            withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
        ).tap()
        app.buttons["Done"].tap()

        let prompt = app.textViews["prompt-field"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 3))
        prompt.tap()
        prompt.typeText("a tiny greenhouse at night")
        app.buttons["dismiss-keyboard-button"].tap()

        let generate = app.buttons["generate-button"]
        XCTAssertTrue(generate.waitForExistence(timeout: 3))
        XCTAssertTrue(generate.isEnabled)
        generate.tap()

        XCTAssertTrue(
            app.otherElements["artwork-timeline-slider"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.staticTexts["Step 30 of 30"].exists)

        app.tabBars.buttons["Library"].tap()
        let artwork = app.buttons["artwork-tile"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 8))
        artwork.tap()
        XCTAssertTrue(app.navigationBars["Image"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.otherElements["artwork-timeline-slider"].exists)
        XCTAssertTrue(app.staticTexts["Step 30 of 30"].exists)
        XCTAssertTrue(app.buttons["download-steps-zip"].exists)
    }

    @MainActor
    func testInpaintingMaskEditorUndoRedoAndBrushControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset", "-ui-testing-preview"]
        app.launch()

        app.tabBars.buttons["Inpainting"].tap()
        let sample = app.buttons["inpainting-sample-button"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        sample.tap()

        let editor = app.otherElements["inpainting-mask-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["inpainting-mask-tool-picker"].exists)
        XCTAssertTrue(app.sliders["inpainting-brush-size"].exists)

        let undo = app.buttons["inpainting-mask-undo"]
        let redo = app.buttons["inpainting-mask-redo"]
        XCTAssertFalse(undo.isEnabled)
        XCTAssertFalse(redo.isEnabled)

        editor.coordinate(
            withNormalizedOffset: CGVector(dx: 0.38, dy: 0.38)
        ).press(
            forDuration: 0.1,
            thenDragTo: editor.coordinate(
                withNormalizedOffset: CGVector(dx: 0.62, dy: 0.62)
            )
        )
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        XCTAssertTrue(redo.isEnabled)
        redo.tap()
        XCTAssertTrue(undo.isEnabled)
        XCTAssertTrue(app.buttons["inpainting-mask-clear"].isEnabled)
    }

    @MainActor
    func testInstalledModelGeneration() throws {
        guard ProcessInfo.processInfo.environment[
            "CLOVER_RUN_REAL_MODEL_TEST"
        ] == "1" else {
            throw XCTSkip("Requires an installed Clover model on an iPhone")
        }

        let app = XCUIApplication()
        app.launchArguments = [
            "-DisableSafetyChecker",
            "YES",
            "-ui-testing-real-model",
        ]
        app.launch()

        let modelPicker = app.buttons["model-picker-button"]
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 10))
        modelPicker.tap()

        let manageMonet = app.buttons["manage-download-monet"]
        XCTAssertTrue(
            manageMonet.waitForExistence(timeout: 10),
            "The real-model smoke test requires the Monet download"
        )
        let useMonet = app.buttons["Use Monet"]
        if useMonet.exists {
            useMonet.tap()
        }
        app.buttons["Done"].tap()

        let parameters = app.buttons["parameters-button"]
        XCTAssertTrue(parameters.waitForExistence(timeout: 5))
        parameters.tap()

        let steps = app.otherElements["steps-slider"]
        XCTAssertTrue(steps.waitForExistence(timeout: 5))
        steps.coordinate(
            withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)
        ).tap()

        let livePreview = app.switches["live-preview-toggle"]
        for _ in 0..<4 where !livePreview.exists {
            app.swipeUp()
        }
        XCTAssertTrue(livePreview.waitForExistence(timeout: 5))
        if livePreview.value as? String == "0" {
            livePreview.coordinate(
                withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
            ).tap()
        }

        let previewInterval = app.otherElements["preview-interval-slider"]
        for _ in 0..<3 where !previewInterval.exists {
            app.swipeUp()
        }
        XCTAssertTrue(previewInterval.waitForExistence(timeout: 5))
        previewInterval.coordinate(
            withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)
        ).tap()
        app.buttons["Done"].tap()

        let generate = app.buttons["generate-button"]
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        XCTAssertTrue(generate.isEnabled)
        generate.tap()

        let cancel = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Cancel'")
        ).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 30))
        XCTAssertTrue(generate.waitForExistence(timeout: 600))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testInstalledInpaintingModelGeneration() throws {
        guard ProcessInfo.processInfo.environment[
            "CLOVER_RUN_REAL_INPAINT_TEST"
        ] == "1" else {
            throw XCTSkip("Requires the optional inpainting model on an iPhone")
        }

        let app = XCUIApplication()
        app.launchArguments = ["-DisableSafetyChecker", "YES"]
        app.launch()

        app.tabBars.buttons["Inpainting"].tap()

        let sample = app.buttons["inpainting-sample-button"]
        XCTAssertTrue(sample.waitForExistence(timeout: 10))
        sample.tap()

        let editor = app.otherElements["inpainting-mask-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        // Fill a coherent doorway-sized region so the generated object has
        // enough latent area to form, instead of testing a thin diagonal line.
        for y in [0.58, 0.64, 0.70, 0.76] {
            editor.coordinate(
                withNormalizedOffset: CGVector(dx: 0.44, dy: y)
            ).press(
                forDuration: 0.05,
                thenDragTo: editor.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.56, dy: y)
                )
            )
        }
        app.buttons["inpainting-example-prompt-button"].tap()

        let ready = app.staticTexts["Ready on device"]
        let download = app.buttons["inpainting-download-button"]
        for _ in 0..<5 where !ready.exists && !download.exists {
            app.swipeUp()
        }
        if !ready.exists {
            XCTAssertTrue(download.waitForExistence(timeout: 20))
            XCTAssertTrue(
                (download.label).contains("1,672 MB"),
                "The stale model should require the pinned v2 package"
            )
            download.tap()
            XCTAssertTrue(
                ready.waitForExistence(timeout: 1_800),
                "The pinned inpainting package did not finish downloading"
            )
        }
        XCTAssertTrue(app.staticTexts["9-channel SD 1.4-class pipeline"].exists)

        // Keep the production default of 20 steps. Four steps is useful for a
        // wiring smoke test, but cannot establish object-level edit quality.
        let settings = app.buttons["inpainting-settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let stepper = app.steppers["inpainting-steps-stepper"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["20 steps"].exists)
        app.buttons["Done"].tap()

        let generate = app.buttons["inpainting-generate-button"]
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        XCTAssertTrue(generate.isEnabled)
        generate.tap()

        let cancel = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Cancel'")
        ).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 60))
        let finished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: cancel
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [finished], timeout: 1_200),
            .completed,
            "Inpainting did not finish on the physical device"
        )
        XCTAssertEqual(app.state, .runningForeground)

        app.tabBars.buttons["Library"].tap()
        let newestArtwork = app.buttons["artwork-tile"].firstMatch
        XCTAssertTrue(newestArtwork.waitForExistence(timeout: 15))
        newestArtwork.tap()
        XCTAssertTrue(
            app.staticTexts[
                "a small orange tabby cat sitting naturally in the doorway, detailed photography"
            ].waitForExistence(timeout: 5),
            "The newest Library item should be the completed object inpainting"
        )
    }
}
