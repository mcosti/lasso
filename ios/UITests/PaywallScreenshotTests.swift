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

    func testPaywallFromSettings() {
        let app = XCUIApplication()
        // No -demo: the real Store runs. The paywall opens from the Purchase row in Settings.
        app.launchArguments = ["-paywallShown", "NO", "-onboardingDone", "YES"]
        app.launch()
        app.buttons["settings"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'trial'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        XCTAssertTrue(app.staticTexts["Try Lasso free for 7 days"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Restore Purchases"].waitForExistence(timeout: 20))
        sleep(2) // let the price load
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "paywall-trial"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
