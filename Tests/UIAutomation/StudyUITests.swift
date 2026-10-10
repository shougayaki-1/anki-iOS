import XCTest

final class StudyUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        addUIInterruptionMonitor(withDescription: "Dismiss incidental dictation setup") { alert in
            for label in ["今はしない", "Not Now"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); return true
            }
            return false
        }
    }
    func app() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString]
        app.launch()
        return app
    }
    func create(_ app: XCUIApplication, question: String, answer: String) {
        app.tabBars.buttons["ライブラリ"].tap()
        let add = app.buttons["addNote"]
        XCTAssertTrue(add.waitForExistence(timeout: 15)); add.tap()
        let q = app.descendants(matching: .any)["questionInput"]
        scrollTo(q, app: app)
        XCTAssertTrue(q.waitForExistence(timeout: 5)); q.tap(); q.typeText(question)
        let a = app.descendants(matching: .any)["answerInput"]
        scrollTo(a, app: app)
        a.tap(); a.typeText(answer)
        app.buttons["saveNote"].tap()
        XCTAssertTrue(app.staticTexts[question].waitForExistence(timeout: 5))
    }
    func scrollTo(_ element: XCUIElement, app: XCUIApplication) {
        if element.exists && [.textField, .textView].contains(element.elementType) { return }
        if app.keyboards.firstMatch.exists && app.buttons["完了"].exists { app.buttons["完了"].tap() }
        for _ in 0..<12 where !element.exists || !element.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.75))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.25)))
        }
    }
    func attach(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name
        image.lifetime = .keepAlways; add(image)
    }

    func testReviewHeroVisibleWithoutScrollingAndHomeAddCancel() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-notification-due"]
        app.launch()
        let review = app.buttons["start-review"]
        XCTAssertTrue(review.waitForExistence(timeout: 15)); XCTAssertTrue(review.isHittable)
        XCTAssertLessThan(review.frame.maxY, app.tabBars.firstMatch.frame.minY)
        XCTAssertTrue(app.staticTexts["dueCount"].label.contains("1枚"))
        attach(app, "Issue29-review-first-home")
        app.buttons["addHomeNote"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["questionInput"].waitForExistence(timeout: 5))
        app.buttons["closeEditor"].tap()
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()
        if app.buttons["復習するへ切り替える"].exists { app.buttons["復習するへ切り替える"].tap() }
        XCTAssertTrue(app.staticTexts["reviewQuestion"].waitForExistence(timeout: 5))
    }

    func testHomeFilterCancelApplyRestartResetPreservesInterruptedDraft() {
        let app = app()
        create(app, question: "Filter question", answer: "Filter answer")
        app.buttons["デッキ管理"].tap(); app.buttons["デッキ追加"].tap()
        app.textFields["deckNameInput"].tap(); app.textFields["deckNameInput"].typeText("Empty deck")
        app.buttons["保存"].tap(); app.buttons["閉じる"].firstMatch.tap()
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        XCTAssertTrue(app.staticTexts["reviewQuestion"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["文字入力"].tap()
        let input = app.descendants(matching: .any)["typedAnswer"]
        input.tap(); input.typeText("Preserved draft")
        if app.keyboards.firstMatch.exists { app.buttons["完了"].firstMatch.tap() }
        app.buttons["pauseStudy"].tap()
        func selectEmpty() {
            app.buttons["openStudyFilter"].tap()
            app.buttons["studyDeckPicker"].tap(); app.buttons["Empty deck"].tap()
        }
        selectEmpty(); app.buttons["cancelStudyFilter"].tap()
        XCTAssertTrue(app.staticTexts["newCount"].label.contains("1枚"))
        selectEmpty(); app.buttons["applyStudyFilter"].tap()
        XCTAssertTrue(app.staticTexts["newCount"].label.contains("0枚"))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["resumeStudy"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["newCount"].label.contains("0枚"))
        app.buttons["resumeStudy"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5)); XCTAssertEqual(input.value as? String, "Preserved draft")
        app.buttons["pauseStudy"].tap(); app.buttons["openStudyFilter"].tap()
        app.buttons["resetStudyFilter"].tap(); app.buttons["applyStudyFilter"].tap()
        XCTAssertTrue(app.staticTexts["newCount"].label.contains("1枚"))
    }

    func testCreateLearnUndoRestartEditAndDelete() {
        let app = app()
        create(app, question: "Capital of Japan?", answer: "Tokyo")
        attach(app, "Phase1-library")
        app.tabBars.buttons["ホーム"].tap()
        app.buttons["start-new"].tap()
        XCTAssertTrue(app.staticTexts["reviewQuestion"].waitForExistence(timeout: 5))
        app.buttons["revealAnswer"].tap()
        XCTAssertEqual(app.staticTexts["modelAnswer"].label, "Tokyo")
        attach(app, "Phase1-answer")
        app.buttons["grade-4"].tap()
        XCTAssertTrue(app.buttons["undoReview"].isEnabled)
        app.buttons["undoReview"].tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 5))
        app.buttons["revealAnswer"].tap()
        app.buttons["grade-4"].tap()
        app.buttons["pauseStudy"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["resumeStudy"].waitForExistence(timeout: 15))
        app.tabBars.buttons["ライブラリ"].tap()
        app.staticTexts["Capital of Japan?"].tap()
        let due = app.descendants(matching: .any)["noteDue"]
        XCTAssertTrue(due.waitForExistence(timeout: 5))
        let savedDue = due.label
        app.buttons["editNote"].tap()
        let question = app.descendants(matching: .any)["questionInput"]
        scrollTo(question, app: app)
        question.tap(); question.typeText(" Updated")
        let editedQuestion = question.value as! String
        XCTAssertTrue(editedQuestion.contains("Updated"))
        app.buttons["saveNote"].tap()
        app.buttons["復習予定を維持して保存"].tap()
        XCTAssertTrue(app.staticTexts[editedQuestion].waitForExistence(timeout: 5))
        XCTAssertEqual(due.label, savedDue)
        app.swipeUp()
        app.buttons["カードを削除"].tap(); app.buttons["削除"].tap()
        XCTAssertTrue(app.buttons["addNote"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[editedQuestion].exists)
    }

    func testTypingDraftSurvivesProcessRestartAndModeChange() {
        let app = app()
        create(app, question: "Write the capital", answer: "Tokyo")
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-mixed"].tap()
        XCTAssertTrue(app.staticTexts["reviewQuestion"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["文字入力"].tap()
        let input = app.descendants(matching: .any)["typedAnswer"]
        scrollTo(input, app: app)
        input.tap(); input.typeText("My draft")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["resumeStudy"].waitForExistence(timeout: 15))
        app.buttons["resumeStudy"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "My draft")
        app.segmentedControls.buttons["頭の中で回答"].tap()
        app.segmentedControls.buttons["文字入力"].tap()
        XCTAssertEqual(input.value as? String, "My draft")
        app.buttons["revealAnswer"].tap()
        attach(app, "Phase1-typing-restored")
        XCTAssertGreaterThanOrEqual(app.buttons["grade-3"].frame.height, 56)
        app.buttons["grade-3"].tap(); app.buttons["pauseStudy"].tap()
        app.tabBars.buttons["記録"].tap()
        let count = app.staticTexts["todayAnswerCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertTrue(count.label.contains("1回"))
    }
}
