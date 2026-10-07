import XCTest

/// Captures the App Store screenshots from the demo mode. Run through
/// `ios/scripts/screenshots.sh`, which boots the right Simulators, fixes the
/// status bar and exports the attachments.
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-screen", screen]
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
        XCTAssertTrue(app.staticTexts["UNLOCKED"].waitForExistence(timeout: 10))
        snap("01-home")
    }

    func testLockScreen() {
        let app = launch(screen: "lockscreen")
        XCTAssertTrue(app.staticTexts["Bike unlocked again"].waitForExistence(timeout: 10))
        snap("02-lockscreen")
    }

    func testLog() {
        let app = launch(screen: "log")
        XCTAssertTrue(app.staticTexts["Log"].waitForExistence(timeout: 10))
        sleep(1) // let the programmatic scroll settle
        snap("03-log")
    }

    func testSettings() {
        let app = launch(screen: "home")
        let gear = app.buttons["settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10))
        gear.tap()
        XCTAssertTrue(app.staticTexts["Presets"].waitForExistence(timeout: 10))
        sleep(1)
        snap("04-settings")
    }
}
