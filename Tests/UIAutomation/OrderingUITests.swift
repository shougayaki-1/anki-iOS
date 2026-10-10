import XCTest

final class OrderingUITests: XCTestCase {
    func launch(accessibility: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-ordering", "-study-test-reduce-motion"]
        if accessibility { app.launchArguments.append("-study-test-accessibility") }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 15))
        scrollTo(app.buttons["start-new"], app: app); app.buttons["start-new"].tap()
        XCTAssertTrue(app.staticTexts["reviewQuestion"].waitForExistence(timeout: 5))
        return app
    }
    func scrollTo(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<25 {
            let top = app.navigationBars.firstMatch.frame.maxY + 4
            if element.exists && element.isHittable && element.frame.minY >= top && element.frame.maxY < app.frame.maxY - 35 { return }
            let down = element.exists && element.frame.minY < top
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: down ? 0.4 : 0.72))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: down ? 0.72 : 0.4)))
        }
        XCTAssertTrue(element.isHittable, "Missing visible element: \(element.identifier)")
    }
    func tap(_ id: String, app: XCUIApplication) {
        let element = app.buttons[id]; scrollTo(element, app: app); element.tap()
    }
    func select(_ ids: [Int], app: XCUIApplication) {
        for id in ids { tap("ordering-token-\(id)", app: app) }
    }
    func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testIncorrectRetryCorrectExplicitGradeAndUndo() {
        let app = launch()
        XCTAssertFalse(app.buttons["checkOrdering"].isEnabled)
        tap("toggleHint", app: app)
        XCTAssertTrue(app.staticTexts["studyHint"].exists)
        XCTAssertFalse(app.staticTexts["modelAnswer"].exists)
        tap("toggleHint", app: app)
        select([1, 0, 2, 3, 4, 5], app: app)
        tap("checkOrdering", app: app)
        XCTAssertTrue(app.staticTexts["orderingResult"].label.contains("不正解"))
        XCTAssertFalse(app.staticTexts["modelAnswer"].exists)
        attach(app, "Issue49-incorrect")
        tap("ordering-selected-1", app: app)
        XCTAssertFalse(app.buttons["checkOrdering"].isEnabled)
        tap("orderingReset", app: app)
        select(Array(0..<6), app: app)
        tap("checkOrdering", app: app)
        XCTAssertTrue(app.staticTexts["modelAnswer"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["modelAnswer"].label, "I walk to school every day.")
        XCTAssertTrue(app.staticTexts["orderingResult"].label.contains("正解"))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "初回の誤答")).firstMatch.exists)
        attach(app, "Issue49-correct-after-retry")
        tap("grade-3", app: app)
        app.buttons["undoReview"].tap()
        XCTAssertTrue(app.buttons["ordering-token-0"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["modelAnswer"].exists)
        XCTAssertFalse(app.staticTexts["orderingResult"].exists)
        XCTAssertFalse(app.buttons["orderingReset"].isEnabled)
    }
    func testModeSwitchPauseProcessRestartAndReveal() {
        let app = launch()
        select([0, 1], app: app)
        let picker = app.segmentedControls["reviewModePicker"]
        scrollTo(picker, app: app); picker.buttons["文字入力"].tap()
        let field = app.descendants(matching: .any)["typedAnswer"]
        scrollTo(field, app: app); field.tap(); field.typeText("Kept typed draft")
        if app.buttons["完了"].exists { app.buttons["完了"].tap() }
        scrollTo(picker, app: app); picker.buttons["並び替え"].tap()
        XCTAssertTrue(app.buttons["ordering-selected-0"].exists)
        XCTAssertTrue(app.buttons["ordering-selected-1"].exists)
        app.buttons["pauseStudy"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["resumeStudy"].waitForExistence(timeout: 15)); app.buttons["resumeStudy"].tap()
        XCTAssertTrue(app.buttons["ordering-selected-0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ordering-selected-1"].exists)
        XCTAssertFalse(app.staticTexts["modelAnswer"].exists)
        scrollTo(picker, app: app); picker.buttons["文字入力"].tap()
        XCTAssertEqual(field.value as? String, "Kept typed draft")
        scrollTo(picker, app: app); picker.buttons["並び替え"].tap()
        tap("revealAnswer", app: app)
        XCTAssertTrue(app.staticTexts["modelAnswer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Again")).firstMatch.exists)
        attach(app, "Issue49-reveal-with-draft")
    }
    func testCSVModeEditorPreviewAndLearning() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["ライブラリ"].waitForExistence(timeout: 15))
        app.tabBars.buttons["ライブラリ"].tap(); app.buttons["openImport"].tap()
        let text = app.textViews["importText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap()
        text.typeText("question,answer,responseMode,hint\nCSV ordering,I walk to school every day.,ordering,Think of walk")
        app.buttons["完了"].tap()
        let format = app.descendants(matching: .any)["importFormat"]
        scrollTo(format, app: app); format.tap(); app.buttons["CSV（カンマ）"].tap()
        tap("previewImport", app: app)
        let mode = app.descendants(matching: .any)["importMode-2"]
        scrollTo(mode, app: app); XCTAssertTrue(mode.label.contains("並び替え") || (mode.value as? String) == "並び替え")
        attach(app, "Issue49-csv-mode-preview")
        app.buttons["confirmImport"].tap(); app.buttons["commitImport"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["importResult"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["importResult"].label.contains("成功 1件"))
        app.buttons["closeImport"].tap()
        app.staticTexts["CSV ordering"].firstMatch.tap(); app.buttons["editNote"].tap()
        tap("previewNote", app: app)
        XCTAssertTrue(app.buttons["ordering-token-0"].waitForExistence(timeout: 5))
        select(Array(0..<6), app: app); tap("checkOrdering", app: app)
        XCTAssertTrue(app.staticTexts["previewAnswer"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["previewAnswer"].label, "I walk to school every day.")
        attach(app, "Issue49-editor-ordering-preview")
        app.buttons["closePreview"].tap(); app.buttons["saveNote"].tap()
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        XCTAssertTrue(app.buttons["ordering-token-0"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["modelAnswer"].exists)
        tap("toggleHint", app: app)
        XCTAssertEqual(app.staticTexts["studyHint"].label, "Think of walk")
    }
    func testLargestDynamicTypeDarkAndReduceMotion() throws {
        let app = launch(accessibility: true)
        tap("ordering-token-0", app: app)
        tap("ordering-selected-0", app: app)
        XCTAssertFalse(app.buttons["checkOrdering"].isEnabled)
        scrollTo(app.buttons["ordering-token-1"], app: app)
        attach(app, "Issue49-largest-dark-candidates")
        scrollTo(app.buttons["ordering-token-5"], app: app)
        XCTAssertEqual(app.buttons["ordering-token-5"].label, "語句 day を選ぶ")
        attach(app, "Issue49-largest-dark-accessibility")
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion]) { issue in
            guard let element = issue.element else { return false }
            print("Ordering audit: \(issue.auditType), id=\(element.identifier), label=\(element.label)")
            if !element.exists || !element.isHittable { return true }
            let viewport = CGRect(x: 0, y: app.navigationBars.firstMatch.frame.maxY,
                                  width: app.frame.width, height: app.frame.height - app.navigationBars.firstMatch.frame.maxY - 35)
            return !viewport.contains(element.frame)
        }
        select(Array(0..<6), app: app)
        tap("checkOrdering", app: app)
        XCTAssertTrue(app.staticTexts["modelAnswer"].waitForExistence(timeout: 5))
        scrollTo(app.buttons["grade-3"], app: app)
        attach(app, "Issue49-largest-dark-grades")
        app.buttons["grade-3"].tap()
        app.buttons["undoReview"].tap()
        XCTAssertFalse(app.staticTexts["modelAnswer"].exists)
    }
}
