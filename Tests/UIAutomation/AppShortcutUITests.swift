import XCTest

final class AppShortcutUITests: XCTestCase {
    func launch(_ arguments: [String], storeID: String = UUID().uuidString) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", storeID] + arguments
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 15))
        return app
    }

    func testProgressOpensExistingStatisticsWithoutStartingStudy() {
        let app = launch(["-study-test-shortcut", "progress"])
        XCTAssertTrue(app.tabBars.buttons["記録"].isSelected)
        XCTAssertTrue(app.staticTexts["今日の記録"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["pauseStudy"].exists)
    }

    func testEmptyReviewAndNewStudyDoNotOpenSession() {
        for mode in ["review", "new"] {
            let app = launch(["-study-test-shortcut", mode])
            XCTAssertTrue(app.tabBars.buttons["ホーム"].isSelected)
            XCTAssertTrue(app.alerts["ショートカット"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["pauseStudy"].exists)
            app.terminate()
        }
    }

    func testNewStudyUsesExistingSessionEntryPoint() {
        let app = launch(["-study-test-hints", "-study-test-shortcut", "new"])
        XCTAssertTrue(app.staticTexts["reviewQuestion"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["pauseStudy"].exists)
    }

    func testInterruptedSessionIsResumedInsteadOfOverwritten() {
        let id = UUID().uuidString
        let app = launch(["-study-test-hints"], storeID: id)
        app.buttons["start-new"].tap()
        let question = app.staticTexts["reviewQuestion"]
        XCTAssertTrue(question.waitForExistence(timeout: 10))
        let original = question.label
        app.buttons["pauseStudy"].tap()
        app.terminate()
        // Even an incompatible requested mode must not replace the paused new session.
        app.launchArguments = ["-study-test-store", id, "-study-test-shortcut", "review"]
        app.launch()
        XCTAssertTrue(app.staticTexts["reviewQuestion"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["reviewQuestion"].label, original)
    }

    func testOpenDeckAndDeletedUUIDAreSafe() {
        let app = launch(["-study-test-hints", "-study-test-shortcut", "deck:first"])
        XCTAssertTrue(app.tabBars.buttons["ライブラリ"].isSelected)
        XCTAssertTrue(app.staticTexts["shortcutDeckPath"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Hint basic"].exists || app.staticTexts["Hint written"].exists)

        let missing = launch(["-study-test-shortcut", "deck:\(UUID().uuidString)"])
        XCTAssertTrue(missing.tabBars.buttons["ライブラリ"].isSelected)
        XCTAssertTrue(missing.alerts["ショートカット"].waitForExistence(timeout: 10))
        XCTAssertFalse(missing.staticTexts["shortcutDeckPath"].exists)
    }
}
