import XCTest

/// Walks through the whole purchase flow against RevenueCat's Test Store:
/// first-launch paywall, start the trial, see the trial banner, open the
/// paywall from Settings, buy Lifetime. Meant to be screen-recorded, so it
/// pauses between steps. Needs a build with a Test Store key:
///   xcodebuild test ... -xcconfig <teststore.xcconfig> -only-testing:LassoUITests/PurchaseFlowTests
final class PurchaseFlowTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        if TestRunObserver.englishScreenshotsInRun { throw XCTSkip("needs a keyed build; run on its own") }
    }

    /// RevenueCat's Test Store shows a sheet asking which outcome to simulate.
    private func chooseSuccessfulPurchase(in app: XCUIApplication) {
        let success = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'valid purchase'")).firstMatch
        if !success.waitForExistence(timeout: 15) {
            let labels = app.buttons.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
            XCTFail("Test Store sheet not found. Buttons: \(labels)")
        }
        sleep(2)
        success.tap()
    }

    func testTrialThenLifetime() {
        let app = XCUIApplication()
        app.launchArguments = ["-paywallShown", "NO"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 6) { allow.tap() }

        // 1. First launch: the paywall explains the trial.
        XCTAssertTrue(app.staticTexts["Try Lasso free for 7 days"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Buy Lifetime'")).firstMatch.waitForExistence(timeout: 20))
        sleep(4)
        app.buttons["Start free trial"].tap()
        chooseSuccessfulPurchase(in: app)

        // 2. Trial running: the paywall closes and the log records it. (The
        // "days left" banner only appears once a bike is paired.)
        let logged = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Free trial started'")).firstMatch
        XCTAssertTrue(logged.waitForExistence(timeout: 25))
        sleep(4)

        // 3. Settings shows the purchase state; tapping it opens the paywall.
        app.buttons["settings"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'trial'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        sleep(2)
        row.tap()
        let buy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Buy Lifetime'")).firstMatch
        XCTAssertTrue(buy.waitForExistence(timeout: 15))
        sleep(3)
        buy.tap()
        chooseSuccessfulPurchase(in: app)

        // 4. Lifetime owned.
        XCTAssertTrue(app.staticTexts["You own Lasso. Thank you."].waitForExistence(timeout: 25))
        sleep(4)
    }
}
