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
        app.buttons["Done"].tap()

        let parameters = app.buttons["parameters-button"]
        XCTAssertTrue(parameters.waitForExistence(timeout: 5))
        parameters.tap()

        XCTAssertTrue(app.navigationBars["Parameters"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.steppers["steps-stepper"].exists)
        XCTAssertTrue(app.sliders["guidance-slider"].exists)
        XCTAssertTrue(app.steppers["image-count-stepper"].exists)
        XCTAssertTrue(app.textFields["seed-field"].exists)
        app.buttons["Done"].tap()

        let prompt = app.textFields["prompt-field"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 3))
        prompt.tap()
        prompt.typeText("a tiny greenhouse at night")

        let generate = app.buttons["generate-button"]
        XCTAssertTrue(generate.isEnabled)
        generate.tap()

        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["artwork-tile"].waitForExistence(timeout: 8))
    }
}
