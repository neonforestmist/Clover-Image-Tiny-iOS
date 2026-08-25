import CoreGraphics
import XCTest

final class CloverUITests: XCTestCase {
    @MainActor
    func testInpaintingTabIsBetweenCreateAndLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset", "-ui-testing-preview"]
        app.launch()

        // Compact iPhone layouts use the system tab bar; larger layouts may
        // promote the same destinations to a native sidebar.
        XCTAssertTrue(app.otherElements["output-canvas"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Inpaint"].exists)
        XCTAssertTrue(app.buttons["Models"].exists)
        XCTAssertTrue(app.buttons["Library"].exists)

        app.goToCloverDestination("Inpaint")
        XCTAssertTrue(
            app.navigationBars["Inpaint"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["inpainting-source-picker"].exists)
        XCTAssertTrue(app.otherElements["inpainting-model-status"].exists)
        XCTAssertTrue(
            app.scrollViews.otherElements["inpainting-model-status"].exists,
            "The model prerequisite should scroll with the Inpaint content"
        )
        XCTAssertTrue(app.buttons["inpainting-generate-button"].exists)
        XCTAssertTrue(app.buttons["inpainting-open-models"].exists)
    }

    @MainActor
    func testParametersGenerationAndLibraryFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset", "-ui-testing-preview"]
        app.launch()

        app.goToCloverDestination("Models")
        XCTAssertTrue(
            app.navigationBars["Models"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.otherElements["model-base"].exists)

        XCTAssertTrue(app.staticTexts["Installed"].exists)
        XCTAssertFalse(app.buttons["Load Monet"].exists)
        XCTAssertFalse(app.buttons["Remove Download"].exists)

        let manageMonet = app.buttons["manage-download-monet"]
        XCTAssertTrue(manageMonet.waitForExistence(timeout: 3))

        app.goToCloverDestination("Create")
        let parameters = app.buttons["parameters-button"]
        XCTAssertTrue(parameters.waitForExistence(timeout: 5))
        parameters.tap()

        XCTAssertTrue(app.navigationBars["Parameters"].waitForExistence(timeout: 3))
        let monetToggle = app.switches["style-mix-enabled-monet"]
        XCTAssertTrue(monetToggle.waitForExistence(timeout: 3))
        monetToggle.tap()
        XCTAssertTrue(app.sliders["style-weight-monet"].waitForExistence(timeout: 3))
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

        XCTAssertTrue(
            app.buttons["Monet Style trigger"].waitForExistence(timeout: 3)
        )

        let prompt = app.textViews["prompt-field"]
        app.reveal(prompt)
        XCTAssertTrue(prompt.waitForExistence(timeout: 3))
        prompt.tap()
        prompt.typeText("a tiny greenhouse at night")
        XCTAssertEqual(
            prompt.value as? String,
            "a tiny greenhouse at night"
        )
        assertEditorIsAboveKeyboard(prompt, in: app)
        dismissNativeKeyboard(in: app)

        let negativeToggle = app.switches["negative-prompt-toggle"]
        app.reveal(negativeToggle)
        XCTAssertTrue(negativeToggle.waitForExistence(timeout: 3))
        negativeToggle.tap()

        let negativePrompt = app.textViews["negative-prompt-field"]
        app.reveal(negativePrompt)
        XCTAssertTrue(negativePrompt.waitForExistence(timeout: 3))
        negativePrompt.tap()
        assertEditorIsAboveKeyboard(negativePrompt, in: app)
        dismissNativeKeyboard(in: app)

        let generate = app.buttons["generate-button"]
        XCTAssertTrue(generate.waitForExistence(timeout: 3))
        XCTAssertTrue(generate.isEnabled)
        generate.tap()

        XCTAssertTrue(
            app.otherElements["artwork-timeline-slider"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.staticTexts["Step 30 of 30"].exists)

        app.goToCloverDestination("Library")
        let artwork = app.buttons["artwork-tile"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 8))
        artwork.tap()
        XCTAssertTrue(app.navigationBars["Image"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.otherElements["artwork-timeline-slider"].exists)
        XCTAssertTrue(app.staticTexts["Step 30 of 30"].exists)
        XCTAssertTrue(app.buttons["download-steps-zip"].exists)
    }

    @MainActor
    func testPromptTriggerTokenCanBeRemovedWithBackspace() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset", "-ui-testing-preview"]
        app.launch()

        app.goToCloverDestination("Models")
        let addMonet = app.buttons["Add Monet"]
        XCTAssertTrue(addMonet.waitForExistence(timeout: 3))
        addMonet.tap()

        app.goToCloverDestination("Create")
        let token = app.buttons["Monet Style trigger"]
        XCTAssertTrue(token.waitForExistence(timeout: 3))

        let prompt = app.textViews["prompt-field"]
        app.reveal(prompt)
        XCTAssertTrue(prompt.waitForExistence(timeout: 3))
        prompt.tap()
        prompt.typeText(XCUIKeyboardKey.delete.rawValue)

        XCTAssertFalse(token.waitForExistence(timeout: 1))
    }

    @MainActor
    func testInpaintingMaskEditorUndoRedoAndBrushControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset", "-ui-testing-preview"]
        app.launch()

        app.goToCloverDestination("Inpaint")
        let sample = app.buttons["inpainting-sample-button"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        sample.tap()

        let editor = app.otherElements["inpainting-mask-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["inpainting-mask-tool-picker"].exists)
        XCTAssertTrue(app.sliders["inpainting-brush-size"].exists)
        XCTAssertFalse(app.buttons["inpainting-mask-edit-mode"].exists)

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

        app.segmentedControls["inpainting-mask-tool-picker"]
            .buttons["Erase"]
            .tap()
        editor.coordinate(
            withNormalizedOffset: CGVector(dx: 0.48, dy: 0.48)
        ).press(
            forDuration: 0.1,
            thenDragTo: editor.coordinate(
                withNormalizedOffset: CGVector(dx: 0.54, dy: 0.54)
            )
        )
        XCTAssertTrue(undo.isEnabled)
        XCTAssertTrue(app.buttons["inpainting-mask-clear"].isEnabled)
    }

    @MainActor
    func testInpaintingPromptStaysAboveKeyboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset", "-ui-testing-preview"]
        app.launch()

        app.goToCloverDestination("Inpaint")
        let prompt = app.textViews["inpainting-prompt-field"]
        app.reveal(prompt)
        XCTAssertTrue(prompt.waitForExistence(timeout: 3))
        prompt.tap()
        prompt.typeText("replace the flowers with a small pond")

        assertEditorIsAboveKeyboard(prompt, in: app)
        dismissNativeKeyboard(in: app)
    }

    @MainActor
    private func assertEditorIsAboveKeyboard(
        _ editor: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(
            keyboard.waitForExistence(timeout: 3),
            "The keyboard should be visible while editing",
            file: file,
            line: line
        )
        waitForKeyboardLayout()
        XCTAssertLessThanOrEqual(
            editor.frame.maxY,
            keyboard.frame.minY + 1,
            "The focused editor should remain fully above the keyboard",
            file: file,
            line: line
        )
    }

    @MainActor
    private func dismissNativeKeyboard(in app: XCUIApplication) {
        let keyboardDone = app.keyboards.buttons["Done"]
        if keyboardDone.waitForExistence(timeout: 1) {
            keyboardDone.tap()
        } else {
            app.keyboards.buttons["Return"].tap()
        }
        XCTAssertFalse(
            app.keyboards.firstMatch.waitForExistence(timeout: 3),
            "The native keyboard should finish dismissing"
        )
        XCTAssertFalse(app.buttons["dismiss-keyboard-button"].exists)
        waitForKeyboardLayout()
    }

    @MainActor
    private func waitForKeyboardLayout() {
        let transition = expectation(description: "Keyboard layout settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            transition.fulfill()
        }
        wait(for: [transition], timeout: 1)
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
            "NO",
            "-ui-testing-real-model",
        ]
        app.launch()

        app.goToCloverDestination("Models")

        let manageMonet = app.buttons["manage-download-monet"]
        XCTAssertTrue(
            manageMonet.waitForExistence(timeout: 10),
            "The real-model smoke test requires the Monet download"
        )
        let addMonet = app.buttons["Add Monet"]
        if addMonet.exists {
            addMonet.tap()
        }
        app.goToCloverDestination("Create")

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
        // Explicitly keep the regular Create override off. Inpainting must
        // still finish because its pipeline is safety-free by construction.
        app.launchArguments = ["-DisableSafetyChecker", "NO"]
        app.launch()

        app.goToCloverDestination("Inpaint")

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
        app.textViews["inpainting-prompt-field"].tap()
        app.textViews["inpainting-prompt-field"].typeText(
            "a small orange tabby cat sitting naturally in the doorway, detailed photography"
        )

        let ready = app.staticTexts["Inpainting model ready"]
        let openModels = app.buttons["inpainting-open-models"]
        if !ready.exists {
            XCTAssertTrue(openModels.waitForExistence(timeout: 20))
            openModels.tap()
            XCTAssertTrue(
                app.navigationBars["Models"].waitForExistence(timeout: 3)
            )
            // The device test downloads the pinned inpainting package from the
            // Models page before returning here.
            XCTAssertTrue(
                ready.waitForExistence(timeout: 1_800),
                "The pinned inpainting package did not finish downloading"
            )
        }

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

        app.goToCloverDestination("Library")
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

private extension XCUIApplication {
    func goToCloverDestination(_ name: String) {
        let destination = buttons[name]
        XCTAssertTrue(
            destination.waitForExistence(timeout: 5),
            "Missing app destination \(name)"
        )
        destination.tap()
    }

    func reveal(_ element: XCUIElement) {
        for _ in 0..<4 where !element.isHittable {
            scrollViews.firstMatch.swipeUp()
        }
    }
}
