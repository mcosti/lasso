import XCTest

/// Dutch App Store screenshots: the same demo screens with `-lang nl`.
/// Run on their own with `-only-testing:LassoUITests/DutchScreenshotTests`;
/// skipped when the English screenshots run alongside (scripts/screenshots.sh),
/// so that script keeps exporting the four English captures only.
final class DutchScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        if TestRunObserver.englishScreenshotsInRun {
            throw XCTSkip("Dutch screenshots run on their own: -only-testing:LassoUITests/DutchScreenshotTests")
        }
    }

    private func launch(screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-screen", screen, "-lang", "nl"]
        app.launch()
        return app
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHome() {
        let app = launch(screen: "home")
        XCTAssertTrue(app.staticTexts["ONTGRENDELD"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Automatisch ontgrendelen"].exists)
        snap("nl-01-home")
    }

    func testLockScreen() {
        let app = launch(screen: "lockscreen")
        XCTAssertTrue(app.staticTexts["Fiets weer ontgrendeld"].firstMatch.waitForExistence(timeout: 10))
        snap("nl-02-lockscreen")
    }
}
