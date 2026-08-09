import CoreGraphics
import XCTest

final class CloverUITests: XCTestCase {
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
        XCTAssertTrue(app.sliders["steps-slider"].exists)
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
            app.sliders["artwork-timeline-slider"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.staticTexts["Step 30 of 30"].exists)

        app.tabBars.buttons["Library"].tap()
        let artwork = app.buttons["artwork-tile"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 8))
        artwork.tap()
        XCTAssertTrue(app.navigationBars["Image"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.sliders["artwork-timeline-slider"].exists)
        XCTAssertTrue(app.staticTexts["Step 30 of 30"].exists)
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

        let steps = app.sliders["steps-slider"]
        XCTAssertTrue(steps.waitForExistence(timeout: 5))
        steps.adjust(toNormalizedSliderPosition: 0)

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

        let previewInterval = app.sliders["preview-interval-slider"]
        for _ in 0..<3 where !previewInterval.exists {
            app.swipeUp()
        }
        XCTAssertTrue(previewInterval.waitForExistence(timeout: 5))
        previewInterval.adjust(toNormalizedSliderPosition: 0)
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
}
