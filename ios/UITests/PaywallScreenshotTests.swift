import XCTest

/// Captures the paywall for the in-app purchase review screenshots. Needs a
/// build with a RevenueCat key (Test Store key is fine), so it is run on its
/// own:  xcodebuild test ... -xcconfig <key.xcconfig> -only-testing:LassoUITests/PaywallScreenshotTests
/// Skipped when the English screenshots run alongside (scripts/screenshots.sh).
final class PaywallScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        if TestRunObserver.englishScreenshotsInRun {
            throw XCTSkip("Paywall screenshot needs a keyed build; run on its own")
        }
    }

    func testFirstLaunchPaywall() {
        let app = XCUIApplication()
        // No -demo: the real Store runs. -paywallShown NO resets the once-only flag.
        app.launchArguments = ["-paywallShown", "NO"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 6) { allow.tap() }
        XCTAssertTrue(app.staticTexts["Try Lasso free for 7 days"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Restore Purchases"].waitForExistence(timeout: 20))
        sleep(2) // let the price load
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "paywall-trial"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
