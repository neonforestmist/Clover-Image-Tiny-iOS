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
        manageMonet.tap()
        XCTAssertTrue(
            app.buttons["Remove Download"].waitForExistence(timeout: 3)
        )
        app.tap()

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

        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["artwork-tile"].waitForExistence(timeout: 8))
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
