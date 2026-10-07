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

    func testOnboardingTrialThenLifetime() {
        let app = XCUIApplication()
        app.launchArguments = ["-paywallShown", "NO", "-onboardingDone", "NO"]
        app.launch()

        // 1. Onboarding: three pages, notifications opt-in at the end.
        let next = app.buttons["onboardingContinue"]
        XCTAssertTrue(app.staticTexts["Your bike, unlocked again"].waitForExistence(timeout: 20))
        sleep(3)
        next.tap()
        XCTAssertTrue(app.staticTexts["How it works"].waitForExistence(timeout: 5))
        sleep(3)
        next.tap()
        XCTAssertTrue(app.buttons["Enable notifications"].waitForExistence(timeout: 5))
        sleep(2)
        app.buttons["Enable notifications"].tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 6) { sleep(1); allow.tap() }

        // 2. Home screen, no paywall yet: it waits for the first paired bike.
        XCTAssertTrue(app.staticTexts["Pair your bike"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Try Lasso free for 7 days"].exists)
        sleep(3)

        // 3. Settings > Purchase opens the paywall; start the trial.
        app.buttons["settings"].tap()
        var row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'free trial'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        sleep(2)
        row.tap()
        XCTAssertTrue(app.staticTexts["Try Lasso free for 7 days"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Buy Lifetime'")).firstMatch.waitForExistence(timeout: 20))
        sleep(4)
        app.buttons["Start free trial"].tap()
        chooseSuccessfulPurchase(in: app)

        // 4. Trial running: the paywall closes and the row shows the end date.
        row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'trial until'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 25))
        sleep(3)
        row.tap()
        let buy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Buy Lifetime'")).firstMatch
        XCTAssertTrue(buy.waitForExistence(timeout: 15))
        sleep(3)
        buy.tap()
        chooseSuccessfulPurchase(in: app)

        // 5. Lifetime owned.
        XCTAssertTrue(app.staticTexts["You own Lasso. Thank you."].waitForExistence(timeout: 25))
        sleep(5)
    }
}
