import XCTest

/// Principal class of the UI test bundle (NSPrincipalClass in project.yml).
/// Notes whether the English `ScreenshotTests` are part of this run, so the
/// Dutch class can stay out of `scripts/screenshots.sh`, which runs the whole
/// bundle and exports every attachment.
@objc(TestRunObserver)
final class TestRunObserver: NSObject, XCTestObservation {
    static var englishScreenshotsInRun = false

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testSuiteWillStart(_ testSuite: XCTestSuite) {
        if Self.contains(ScreenshotTests.self, in: testSuite) { Self.englishScreenshotsInRun = true }
    }

    private static func contains(_ type: XCTestCase.Type, in test: XCTest) -> Bool {
        if let suite = test as? XCTestSuite { return suite.tests.contains { contains(type, in: $0) } }
        return Swift.type(of: test) == type
    }
}
