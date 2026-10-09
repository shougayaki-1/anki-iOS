import XCTest

final class OperationsUITests: XCTestCase {
    func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["ライブラリ"].waitForExistence(timeout: 15))
        return app
    }
    func create(_ app: XCUIApplication) {
        app.tabBars.buttons["ライブラリ"].tap(); app.buttons["addNote"].tap()
        let question = app.descendants(matching: .any)["questionInput"]
        XCTAssertTrue(question.waitForExistence(timeout: 5)); question.tap(); question.typeText("Backup question")
        let answer = app.descendants(matching: .any)["answerInput"]
        answer.tap(); answer.typeText("Backup answer"); app.buttons["saveNote"].tap()
        XCTAssertTrue(app.staticTexts["Backup question"].waitForExistence(timeout: 5))
    }
    func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
    func testNotificationPermissionActualReservationsAndCancellation() {
        addUIInterruptionMonitor(withDescription: "Local notification permission") { alert in
            if alert.buttons["許可"].exists { alert.buttons["許可"].tap(); return true }
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            return false
        }
        let app = launch(); create(app)
        app.tabBars.buttons["設定"].tap()
        let toggle = app.switches["notificationToggle"]
        scrollTo(toggle, in: app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: toggle)
        waitForExpectations(timeout: 10)
        let count = app.staticTexts["notificationCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 10)); XCTAssertTrue(count.label.contains("0件"))
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 5))
        app.buttons["revealAnswer"].tap(); app.buttons["grade-1"].tap(); app.buttons["pauseStudy"].tap()
        app.tabBars.buttons["設定"].tap(); scrollTo(toggle, in: app)
        let planned = NSPredicate(format: "label CONTAINS %@", "30件")
        expectation(for: planned, evaluatedWith: count)
        waitForExpectations(timeout: 15)
        attach(app, name: "Phase4-notification-reservations")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "0件"), evaluatedWith: count)
        waitForExpectations(timeout: 10)
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["設定"].waitForExistence(timeout: 15)); app.tabBars.buttons["設定"].tap()
        scrollTo(toggle, in: app); XCTAssertEqual(toggle.value as? String, "0")
    }
    func testNativeBackupExportAndImportPicker() {
        let app = launch(); create(app)
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 5))
        app.buttons["revealAnswer"].tap(); app.buttons["grade-4"].tap(); app.buttons["pauseStudy"].tap()
        app.tabBars.buttons["設定"].tap()
        let open = app.buttons["openBackup"]; scrollTo(open, in: app); open.tap()
        app.buttons["exportBackup"].tap()
        let onPhone = app.buttons["On My iPhone"]
        if onPhone.waitForExistence(timeout: 10) { onPhone.tap() }
        else if app.buttons["このiPhone内"].exists { app.buttons["このiPhone内"].tap() }
        let folder = app.cells.containing(.staticText, identifier: "暗記アプリ").firstMatch
        if folder.waitForExistence(timeout: 3) { folder.tap() }
        let save = app.buttons["Save"]
        if save.exists { save.tap() } else if app.buttons["保存"].exists { app.buttons["保存"].tap() }
        let replace = app.buttons["置き換え"].firstMatch
        if replace.waitForExistence(timeout: 2) { replace.tap() }
        let result = app.staticTexts["backupResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(result.label.contains("書き出しました"))
        app.buttons["importBackup"].tap()
        attach(app, name: "Phase4-backup-file-picker")
        let backupFile = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "Study-")).firstMatch
        XCTAssertTrue(backupFile.waitForExistence(timeout: 10), app.debugDescription)
        backupFile.tap()
        let restore = app.buttons["restoreBackup"]; XCTAssertTrue(restore.waitForExistence(timeout: 10)); scrollTo(restore, in: app); restore.tap()
        app.buttons["confirmRestoreBackup"].firstMatch.tap()
        XCTAssertTrue(result.waitForExistence(timeout: 10)); XCTAssertTrue(result.label.contains("復元しました"))
        attach(app, name: "Phase4-backup-restored")
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["記録"].waitForExistence(timeout: 15)); app.tabBars.buttons["記録"].tap()
        XCTAssertTrue(app.staticTexts["todayAnswerCount"].label.contains("1回"))
        app.tabBars.buttons["ライブラリ"].tap(); XCTAssertTrue(app.staticTexts["Backup question"].exists)
    }
}
