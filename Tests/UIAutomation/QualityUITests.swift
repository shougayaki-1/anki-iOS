import XCTest

final class QualityUITests: XCTestCase {
    func testScaleHomeReviewUndoAndRestart() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-scale"]
        app.launch()
        XCTAssertTrue(app.staticTexts["dueCount"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["dueCount"].label.contains("3000枚"))
        app.buttons["start-review"].tap()
        let question = app.staticTexts["reviewQuestion"]
        XCTAssertTrue(question.waitForExistence(timeout: 10)); let first = question.label
        app.buttons["revealAnswer"].tap(); app.buttons["grade-3"].tap(); app.buttons["undoReview"].tap()
        XCTAssertEqual(question.label, first)
        app.buttons["pauseStudy"].tap(); XCTAssertTrue(app.staticTexts["dueCount"].label.contains("3000枚"))
        attach(app, name: "Phase5-scale-home")
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["dueCount"].waitForExistence(timeout: 15)); XCTAssertTrue(app.staticTexts["dueCount"].label.contains("3000枚"))
        app.buttons["resumeStudy"].tap(); XCTAssertTrue(question.waitForExistence(timeout: 10)); XCTAssertEqual(question.label, first)
    }
    func scrollTo(_ element: XCUIElement, app: XCUIApplication) {
        // Form text fields scroll themselves into view when tapped, including
        // when the keyboard covers part of a large Dynamic Type form.
        if element.exists && [.textField, .textView].contains(element.elementType) { return }
        for _ in 0..<10 where !element.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.75))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.25)))
        }
        XCTAssertTrue(element.exists)
    }
    func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
    func selectFile(_ name: String, app: XCUIApplication) {
        let file = app.cells.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        if !file.waitForExistence(timeout: 3) {
            if app.buttons["ブラウズ"].firstMatch.exists { app.buttons["ブラウズ"].firstMatch.tap() }
            if app.buttons["このiPhone内"].exists { app.buttons["このiPhone内"].tap() }
            else if app.buttons["On My iPhone"].exists { app.buttons["On My iPhone"].tap() }
            let folder = app.cells.containing(.staticText, identifier: "暗記アプリ").firstMatch
            if folder.exists { folder.tap() }
        }
        XCTAssertTrue(file.waitForExistence(timeout: 10), app.debugDescription)
        file.tap()
    }
    func testNativeCSVFileImportAndCorruptBackupPreservesData() {
        let app = XCUIApplication(), id = UUID().uuidString
        app.launchArguments = ["-study-test-store", id, "-study-test-file-fixtures"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["ライブラリ"].waitForExistence(timeout: 15)); app.tabBars.buttons["ライブラリ"].tap()
        app.buttons["openImport"].tap(); app.buttons["selectImportFile"].tap()
        selectFile("UITest-\(id)", app: app)
        XCTAssertTrue(app.buttons["previewImport"].waitForExistence(timeout: 10)); app.buttons["previewImport"].tap()
        let confirm = app.buttons["confirmImport"]; scrollTo(confirm, app: app); confirm.tap()
        app.buttons["commitImport"].firstMatch.tap()
        let result = app.staticTexts["importResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 10)); XCTAssertTrue(result.label.contains("成功 1件"))
        attach(app, name: "Phase5-native-CSV-import")
        app.buttons["closeImport"].tap(); XCTAssertTrue(app.staticTexts["CSV file question"].waitForExistence(timeout: 5))
        app.tabBars.buttons["設定"].tap()
        let backup = app.buttons["openBackup"]; scrollTo(backup, app: app); backup.tap(); app.buttons["importBackup"].tap()
        selectFile("Invalid-\(id)", app: app)
        let alert = app.alerts["バックアップ処理に失敗しました"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10)); attach(app, name: "Phase5-invalid-backup-rejected")
        alert.buttons["閉じる"].tap()
        XCTAssertFalse(app.buttons["restoreBackup"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["ライブラリ"].waitForExistence(timeout: 15)); app.tabBars.buttons["ライブラリ"].tap()
        XCTAssertTrue(app.staticTexts["CSV file question"].exists)
    }
    func testDarkLargestDynamicTypeWrittenCardAndAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-accessibility"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 15))
        attach(app, name: "Phase5-dark-largest-type-home")
        try app.performAccessibilityAudit(for: [.elementDetection, .sufficientElementDescription])
        app.tabBars.buttons["ライブラリ"].tap(); app.buttons["addNote"].tap()
        app.buttons["noteKindPicker"].tap(); app.buttons["記述式"].firstMatch.tap()
        let question = app.descendants(matching: .any)["questionInput"]
        scrollTo(question, app: app); question.tap(); question.typeText("Write the capital")
        let answer = app.descendants(matching: .any)["answerInput"]
        scrollTo(answer, app: app); answer.tap(); answer.typeText("Tokyo")
        app.buttons["saveNote"].tap()
        XCTAssertTrue(app.staticTexts["Write the capital"].waitForExistence(timeout: 5))
        app.tabBars.buttons["ホーム"].tap()
        let start = app.buttons["start-new"]; scrollTo(start, app: app); start.tap()
        let mode = app.descendants(matching: .any)["reviewModePicker"]
        scrollTo(mode, app: app); mode.tap()
        let typingMode = app.buttons["response-mode-typing"]
        XCTAssertTrue(typingMode.waitForExistence(timeout: 5)); typingMode.tap()
        expectation(for: NSPredicate(format: "value == %@", "文字入力"), evaluatedWith: mode)
        waitForExpectations(timeout: 5)
        let input = app.descendants(matching: .any)["typedAnswer"]
        scrollTo(input, app: app); input.tap(); input.typeText("Tokyo")
        if app.buttons["完了"].exists { app.buttons["完了"].tap() }
        let reveal = app.buttons["revealAnswer"]; scrollTo(reveal, app: app); reveal.tap()
        XCTAssertEqual(app.staticTexts["modelAnswer"].label, "Tokyo")
        attach(app, name: "Phase5-dark-largest-type-answer")
        let grade = app.buttons["grade-3"]; scrollTo(grade, app: app); grade.tap()
        app.buttons["pauseStudy"].tap(); app.tabBars.buttons["記録"].tap()
        XCTAssertTrue(app.staticTexts["todayAnswerCount"].label.contains("1回"))
    }
}
