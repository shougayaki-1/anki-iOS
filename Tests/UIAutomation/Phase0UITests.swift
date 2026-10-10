import XCTest

final class Phase0UITests: XCTestCase {
    func testSaveTerminateAndRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-phase0-test-store", UUID().uuidString]
        app.launch()
        let button = app.buttons["saveVerification"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.tap()
        func savedLabel(_ identifier: String) -> String {
            let element = app.descendants(matching: .any)[identifier]
            if element.exists { return element.label }
            for _ in 0..<6 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.3))
                    .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.75)))
                if element.exists { return element.label }
            }
            for _ in 0..<15 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.7))
                    .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.4)))
                if element.exists { return element.label }
            }
            XCTFail("Saved diagnostic row was not found: " + identifier)
            return ""
        }
        let id = app.descendants(matching: .any)["probeID"]
        XCTAssertTrue(id.waitForExistence(timeout: 10))
        let savedID = id.label
        let state = savedLabel("probeState")
        XCTAssertTrue(state.contains("learning → review → relearning → review"))
        XCTAssertEqual(savedLabel("probeCount"), "保存済み: 1件")
        app.terminate()
        app.launch()
        XCTAssertTrue(id.waitForExistence(timeout: 15))
        XCTAssertEqual(id.label, savedID)
        XCTAssertEqual(savedLabel("probeState"), state)
        XCTAssertEqual(savedLabel("probeCount"), "保存済み: 1件")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Phase0-after-relaunch"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
