import XCTest

final class FramebaseUITests: XCTestCase {
    @MainActor
    func testMainWindowLaunches() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.windows["Framebase"].waitForExistence(timeout: 5))
    }
}
