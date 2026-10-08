import XCTest

final class Phase0UITests: XCTestCase {
    func testSaveTerminateAndRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-phase0-test-store", UUID().uuidString]
        app.launch()
        let button = app.buttons["saveVerification"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.tap()
        let id = app.staticTexts["probeID"]
        XCTAssertTrue(id.waitForExistence(timeout: 10))
        let savedID = id.label
        let state = app.staticTexts["probeState"].label
        XCTAssertTrue(state.contains("learning → review → relearning → review"))
        XCTAssertEqual(app.staticTexts["probeCount"].label, "保存済み: 1件")
        app.terminate()
        app.launch()
        XCTAssertTrue(id.waitForExistence(timeout: 15))
        XCTAssertEqual(id.label, savedID)
        XCTAssertEqual(app.staticTexts["probeState"].label, state)
        XCTAssertEqual(app.staticTexts["probeCount"].label, "保存済み: 1件")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Phase0-after-relaunch"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
