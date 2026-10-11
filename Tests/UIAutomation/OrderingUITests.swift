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
        var missingSearches = 0
        for _ in 0..<35 {
            let navigationBottom = app.navigationBars.allElementsBoundByIndex.map { $0.frame.maxY }.max() ?? 0
            let pause = app.buttons["pauseStudy"]
            var top = max(navigationBottom, pause.exists ? pause.frame.maxY : 0) + 12
            let progress = app.progressIndicators["sessionProgressBar"]
            if progress.exists { top = max(top, progress.frame.maxY + 8) }
            var bottom = app.frame.maxY - 35
            let fixedControl = element.exists && (element.identifier.hasPrefix("grade-") || element.identifier == "revealAnswer")
            if fixedControl && element.isHittable {
                // A fixed footer is already accessible; scrolling the body cannot move it.
                return
            }
            if !fixedControl {
                let footer = app.buttons["grade-1"].exists ? app.buttons["grade-1"] : app.buttons["revealAnswer"]
                if footer.exists && footer.isHittable { bottom = min(bottom, footer.frame.minY - 8) }
            }
            if element.exists && element.isHittable && element.frame.minY >= top && element.frame.maxY < bottom { return }
            // At accessibility sizes XCTest omits distant off-screen chips.
            // Search toward the top first, then downward, rather than assuming
            // a missing chip is always below the current scroll position.
            let down = element.exists ? element.frame.minY < top : missingSearches < 6
            if !element.exists { missingSearches += 1 }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: down ? 0.4 : 0.72))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: down ? 0.72 : 0.4)))
        }
        XCTAssertTrue(element.exists && element.isHittable, "Required element could not be made visible")
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
        XCTAssertTrue(app.staticTexts["importResult"].label.contains("新規 1ノート"))
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
    func testDragReordersWithoutRemovingOtherChipsThenChecksFinalSentence() {
        let app = launch()
        select([0, 3, 1, 2, 4, 5], app: app)
        let sentence = app.staticTexts["orderingSentence"]
        XCTAssertEqual(sentence.value as? String, "I school walk to every day.")

        func move(_ sourceID: Int, before targetID: Int) {
            let source = app.buttons["ordering-selected-\(sourceID)"]
            let target = app.buttons["ordering-selected-\(targetID)"]
            scrollTo(source, app: app); scrollTo(target, app: app)
            source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.8,
                       thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
        }
        move(1, before: 3)
        XCTAssertEqual(sentence.value as? String, "I walk school to every day.")
        XCTAssertEqual(app.staticTexts["orderingProgress"].label, "選択 6 / 6語句")
        move(2, before: 3)
        XCTAssertEqual(sentence.value as? String, "I walk to school every day.")
        XCTAssertTrue(app.buttons["checkOrdering"].isEnabled)
        tap("checkOrdering", app: app)
        XCTAssertTrue(app.staticTexts["modelAnswer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["orderingResult"].label.contains("正解"))
    }

    func testDragOrderSurvivesPauseAndResume() {
        let app = launch()
        select([0, 3, 1, 2], app: app)
        let source = app.buttons["ordering-selected-1"]
        let target = app.buttons["ordering-selected-3"]
        scrollTo(source, app: app); scrollTo(target, app: app)
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.8,
                   thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
        XCTAssertEqual(app.staticTexts["orderingSentence"].value as? String, "I walk school to")
        app.buttons["pauseStudy"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["resumeStudy"].waitForExistence(timeout: 15))
        app.buttons["resumeStudy"].tap()
        XCTAssertEqual(app.staticTexts["orderingSentence"].value as? String, "I walk school to")
        XCTAssertEqual(app.staticTexts["orderingProgress"].label, "選択 4 / 6語句")
    }

    func testCrossRowInsertionAndCancelledDragPreserveTokenIdentity() {
        let app = launch()
        select(Array(0..<6), app: app)
        let sentence = app.staticTexts["orderingSentence"]
        let original = sentence.value as? String
        let first = app.buttons["ordering-selected-0"]
        scrollTo(first, app: app)
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.8, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.025)))
        XCTAssertEqual(sentence.value as? String, original)
        XCTAssertEqual(app.staticTexts["orderingProgress"].label, "選択 6 / 6語句")

        let last = app.buttons["ordering-selected-5"]
        scrollTo(last, app: app); scrollTo(first, app: app)
        last.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.8, thenDragTo: first.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
        XCTAssertEqual(sentence.value as? String, "day. I walk to school every")
        let end = app.buttons["ordering-selected-4"]
        scrollTo(first, app: app); scrollTo(end, app: app)
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.8, thenDragTo: end.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertEqual(sentence.value as? String, "day. walk to school every I")
        XCTAssertEqual(app.staticTexts["orderingProgress"].label, "選択 6 / 6語句")
        XCTAssertFalse(app.staticTexts["modelAnswer"].exists)
    }

    func testSingleSelectedChipCanBeCancelledAtLargestType() {
        let app = launch(accessibility: true)
        tap("ordering-token-0", app: app)
        let selected = app.buttons["ordering-selected-0"]
        scrollTo(selected, app: app)
        print("Single selected chip: \(selected.debugDescription)")
        attach(app, "Issue56-single-selected-before-cancel")
        selected.tap()
        attach(app, "Issue56-single-selected-after-cancel")
        XCTAssertFalse(selected.exists)
        scrollTo(app.buttons["ordering-token-0"], app: app)
        XCTAssertTrue(app.buttons["ordering-token-0"].exists)
        XCTAssertEqual(app.staticTexts["orderingProgress"].label, "選択 0 / 6語句")
    }

    func testLargestDynamicTypeDarkAndReduceMotion() throws {
        let app = launch(accessibility: true)
        tap("ordering-token-0", app: app)
        tap("ordering-selected-0", app: app)
        XCTAssertFalse(app.buttons["ordering-selected-0"].exists, "Tapping a selected chip must return it to the bank")
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
        scrollTo(app.staticTexts["modelAnswer"], app: app)
        XCTAssertTrue(app.staticTexts["modelAnswer"].waitForExistence(timeout: 5))
        scrollTo(app.buttons["grade-3"], app: app)
        attach(app, "Issue49-largest-dark-grades")
        app.buttons["grade-3"].tap()
        app.buttons["undoReview"].tap()
        XCTAssertFalse(app.staticTexts["modelAnswer"].exists)
    }
}
