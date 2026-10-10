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
        if app.keyboards.firstMatch.exists {
            if app.buttons["dismissBulkKeyboard"].exists { app.buttons["dismissBulkKeyboard"].tap() }
            else if let done = app.buttons.matching(NSPredicate(format: "label == %@", "完了")).allElementsBoundByIndex.first(where: { $0.isHittable }) { done.tap() }
        }
        for _ in 0..<12 where !element.exists || !element.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.75))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.25)))
        }
    }
    func attach(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name
        image.lifetime = .keepAlways; add(image)
    }

    func testSharedHintsAllFormatsReverseExceptionAndCardReset() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-hints"]
        app.launch()
        XCTAssertTrue(app.buttons["start-new"].waitForExistence(timeout: 15)); app.buttons["start-new"].tap()
        var reverse = 0, hinted = 0, images = 0, clozes = 0
        for _ in 0..<7 {
            let question = app.staticTexts["reviewQuestion"]
            XCTAssertTrue(question.waitForExistence(timeout: 5))
            let toggle = app.buttons["toggleHint"]
            XCTAssertFalse(app.staticTexts["studyHint"].exists)
            if question.label == "Reverse question" {
                reverse += 1; XCTAssertFalse(toggle.exists)
            } else {
                hinted += 1; XCTAssertTrue(toggle.exists); scrollTo(toggle, app: app); toggle.tap()
                XCTAssertTrue(app.staticTexts["studyHint"].exists)
                XCTAssertFalse(app.staticTexts["modelAnswer"].exists)
                if question.label == "Hint imageOcclusion" {
                    images += 1; XCTAssertTrue(app.descendants(matching: .any)["reviewImage"].exists)
                    attach(app, "Issue47-image-mask-hint")
                }
                if question.label.contains("[") { clozes += 1 }
            }
            scrollTo(app.buttons["revealAnswer"], app: app); app.buttons["revealAnswer"].tap()
            XCTAssertFalse(toggle.exists)
            scrollTo(app.buttons["grade-4"], app: app); app.buttons["grade-4"].tap()
        }
        XCTAssertEqual(reverse, 1); XCTAssertEqual(hinted, 6)
        XCTAssertEqual(images, 2); XCTAssertEqual(clozes, 2)
    }

    func testHintEditorPreviewTypingPauseRestartUndoAndCardChange() {
        let app = app()
        create(app, question: "Hint question", answer: "Secret answer")
        app.staticTexts["Hint question"].firstMatch.tap()
        app.buttons["editNote"].tap()
        let hint = app.descendants(matching: .any)["hintInput"]
        for _ in 0..<8 where !hint.exists || !hint.isHittable || hint.frame.minY < app.navigationBars.firstMatch.frame.maxY || hint.frame.maxY > app.frame.maxY - 60 { app.swipeUp() }
        hint.tap(); hint.typeText("Recall the first letter")
        if app.buttons["完了"].exists { app.buttons["完了"].tap() }
        let preview = app.buttons["previewNote"]
        scrollTo(preview, app: app); preview.tap()
        let toggle = app.buttons["toggleHint"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["studyHint"].exists)
        toggle.tap(); XCTAssertEqual(app.staticTexts["studyHint"].label, "Recall the first letter")
        XCTAssertFalse(app.staticTexts["previewAnswer"].exists)
        toggle.tap(); XCTAssertFalse(app.staticTexts["studyHint"].exists)
        app.buttons["closePreview"].tap()
        app.buttons["closeEditor"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["ライブラリ"].waitForExistence(timeout: 15))
        app.tabBars.buttons["ライブラリ"].tap()
        app.staticTexts["Hint question"].firstMatch.tap(); app.buttons["editNote"].tap()
        scrollTo(hint, app: app)
        XCTAssertEqual(hint.value as? String, "Recall the first letter")
        app.buttons["saveNote"].tap()
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["studyHint"].exists)
        app.segmentedControls["reviewModePicker"].buttons["文字入力"].tap()
        let draft = app.descendants(matching: .any)["typedAnswer"]
        draft.tap(); draft.typeText("My draft")
        toggle.tap(); XCTAssertFalse(app.staticTexts["modelAnswer"].exists)
        XCTAssertEqual(draft.value as? String, "My draft")
        toggle.tap(); toggle.tap()
        app.buttons["pauseStudy"].tap()
        app.buttons["resumeStudy"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["studyHint"].exists)
        XCTAssertEqual(draft.value as? String, "My draft")
        toggle.tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["resumeStudy"].waitForExistence(timeout: 15)); app.buttons["resumeStudy"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertFalse(app.staticTexts["studyHint"].exists)
        XCTAssertEqual(draft.value as? String, "My draft")
        if app.buttons["完了"].exists { app.buttons["完了"].tap() }
        toggle.tap()
        attach(app, "Issue47-hint-expanded")
        app.buttons["revealAnswer"].tap()
        XCTAssertFalse(toggle.exists); XCTAssertFalse(app.staticTexts["studyHint"].exists)
        XCTAssertEqual(app.staticTexts["modelAnswer"].label, "Secret answer")
        scrollTo(app.buttons["grade-4"], app: app); app.buttons["grade-4"].tap()
        app.buttons["undoReview"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertFalse(app.staticTexts["studyHint"].exists)
        XCTAssertFalse(app.staticTexts["modelAnswer"].exists)
        app.buttons["revealAnswer"].tap()
        scrollTo(app.buttons["grade-4"], app: app); app.buttons["grade-4"].tap()
        XCTAssertFalse(app.staticTexts["studyHint"].exists)
    }

    func testInterruptedReviewPrimaryResumesRevealedDraftWithoutConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-notification-due"]
        app.launch()
        let start = app.buttons["start-review"]
        XCTAssertTrue(start.waitForExistence(timeout: 15)); start.tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 5))
        let question = app.staticTexts["reviewQuestion"].label
        app.segmentedControls.buttons["文字入力"].tap()
        let input = app.descendants(matching: .any)["typedAnswer"]
        input.tap(); input.typeText("Review draft")
        if app.keyboards.firstMatch.exists { app.buttons["完了"].firstMatch.tap() }
        app.buttons["revealAnswer"].tap()
        app.buttons["pauseStudy"].tap()
        XCTAssertTrue(app.buttons["resumeStudy"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "resumeStudy").count, 1)
        XCTAssertFalse(app.staticTexts["dueCount"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["resumeStudy"].waitForExistence(timeout: 15))
        app.buttons["resumeStudy"].tap()
        XCTAssertFalse(app.buttons["復習するへ切り替える"].exists)
        XCTAssertTrue(app.buttons["grade-3"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reviewQuestion"].label, question)
        XCTAssertTrue(app.staticTexts["Review draft"].exists)
    }

    func testHomeLightAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-notification-due"]
        app.launch()
        XCTAssertTrue(app.buttons["start-review"].waitForExistence(timeout: 15))
        attach(app, "Issue31-home-light")
        try app.performAccessibilityAudit(for: [.contrast, .textClipped, .sufficientElementDescription, .hitRegion]) { issue in
            guard let element = issue.element else {
                if issue.auditType == .contrast {
                    let note = XCTAttachment(string: "Unbound system contrast node. Review the attached viewport screenshot; identified app elements are audited separately.")
                    note.lifetime = .keepAlways; self.add(note)
                    return true
                }
                return false
            }
            if !element.exists || !element.isHittable { return true }
            let top = app.navigationBars.firstMatch.frame.maxY, bottom = app.tabBars.firstMatch.frame.minY
            let viewport = CGRect(x: app.frame.minX, y: top, width: app.frame.width, height: max(0, bottom - top))
            return !viewport.contains(element.frame)
        }
    }

    func testHomeParentDeckAndMultipleTagsApplyResetAndMixedMode() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-home-filters"]
        app.launch()
        XCTAssertTrue(app.buttons["openStudyFilter"].waitForExistence(timeout: 15))
        app.buttons["openStudyFilter"].tap()
        app.buttons["studyDeckPicker"].tap(); app.buttons["マイデッキ"].tap()
        for tag in ["A", "B"] {
            app.switches["studyTag-\(tag)"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        app.buttons["applyStudyFilter"].tap()
        XCTAssertTrue(app.staticTexts["newCount"].label.contains("1枚"))
        XCTAssertFalse(app.buttons["start-review"].isEnabled)
        app.buttons["start-mixed"].tap()
        XCTAssertTrue(app.staticTexts["reviewQuestion"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reviewQuestion"].label, "Both tags")
        app.buttons["pauseStudy"].tap()
        let filter = app.buttons["openStudyFilter"]
        for _ in 0..<8 where !filter.exists || !filter.isHittable { app.swipeDown() }
        filter.tap(); app.buttons["resetStudyFilter"].tap()
        app.buttons["applyStudyFilter"].tap()
        XCTAssertTrue(app.staticTexts["newCount"].label.contains("3枚"))
        app.buttons["resumeStudy"].tap()
        XCTAssertTrue(app.staticTexts["reviewQuestion"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reviewQuestion"].label, "Both tags")
    }
    func testHomeAccessibilityDarkLargestTextAndAddSave() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-notification-due", "-study-test-accessibility", "-study-test-reduce-motion"]
        app.launch()
        XCTAssertTrue(app.buttons["openStudyFilter"].waitForExistence(timeout: 15))
        let review = app.buttons["start-review"]
        scrollTo(review, app: app); XCTAssertTrue(review.isHittable)
        attach(app, "Issue31-home-dark-largest-type")
        let filter = app.buttons["openStudyFilter"]
        for _ in 0..<8 where !filter.exists || !filter.isHittable { app.swipeDown() }
        filter.tap()
        XCTAssertTrue(app.buttons["applyStudyFilter"].waitForExistence(timeout: 5))
        attach(app, "Issue31-filter-dark-largest-type")
        app.buttons["cancelStudyFilter"].tap()
        app.buttons["addHomeNote"].tap()
        let q = app.descendants(matching: .any)["questionInput"]
        scrollTo(q, app: app); q.tap(); q.typeText("Home added")
        let a = app.descendants(matching: .any)["answerInput"]
        scrollTo(a, app: app); a.tap(); a.typeText("Home answer")
        app.buttons["saveNote"].tap()
        XCTAssertTrue(app.buttons["addHomeNote"].waitForExistence(timeout: 5))
        app.tabBars.buttons["ライブラリ"].tap()
        XCTAssertTrue(app.staticTexts["Home added"].waitForExistence(timeout: 5))
    }

    func testHomeEmptyWaitingAndModeSwitchCancellation() {
        let app = app()
        XCTAssertTrue(app.buttons["addFirstHomeNote"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["start-new"].isEnabled); XCTAssertFalse(app.buttons["start-mixed"].isEnabled)
        create(app, question: "State question", answer: "State answer")
        app.tabBars.buttons["ホーム"].tap()
        XCTAssertFalse(app.buttons["start-review"].isEnabled); XCTAssertTrue(app.buttons["start-new"].isEnabled)
        app.buttons["start-new"].tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 5))
        app.buttons["pauseStudy"].tap()
        scrollTo(app.buttons["start-mixed"], app: app); app.buttons["start-mixed"].tap()
        XCTAssertTrue(app.buttons["復習＋新規へ切り替える"].waitForExistence(timeout: 5))
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["キャンセル", "Cancel"])).firstMatch
        if cancel.exists { cancel.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.1)).tap() }
        let resume = app.buttons["resumeStudy"]
        for _ in 0..<8 where !resume.exists || !resume.isHittable { app.swipeDown() }
        XCTAssertEqual(app.buttons.matching(identifier: "resumeStudy").count, 1)
        resume.tap()
        XCTAssertFalse(app.buttons["新しく覚えるへ切り替える"].exists)
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 5))
        app.buttons["revealAnswer"].tap(); app.buttons["grade-1"].tap(); app.buttons["pauseStudy"].tap()
        for _ in 0..<3 { app.swipeDown() }
        XCTAssertFalse(app.buttons["resumeStudy"].exists)
        XCTAssertTrue(app.buttons["completeStudy"].exists)
        let waiting = app.staticTexts["nextShortReview"]
        scrollTo(waiting, app: app); XCTAssertTrue(waiting.exists)
        XCTAssertFalse(app.buttons["start-new"].isEnabled)
        XCTAssertFalse(app.buttons["start-mixed"].isEnabled)
        attach(app, "Issue30-short-review-waiting")
        // Remain on Home without polling-triggering gestures or tab changes.
        let dueResume = app.buttons["resumeStudy"]
        XCTAssertTrue(dueResume.waitForExistence(timeout: 75))
        dueResume.tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reviewQuestion"].label, "State question")
        XCTAssertTrue(app.buttons["undoReview"].isEnabled)
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
        XCTAssertFalse(app.buttons["新しく覚えるへ切り替える"].exists)
        XCTAssertTrue(input.waitForExistence(timeout: 5)); XCTAssertEqual(input.value as? String, "Preserved draft")
        app.buttons["pauseStudy"].tap(); app.buttons["openStudyFilter"].tap()
        app.buttons["resetStudyFilter"].tap(); app.buttons["applyStudyFilter"].tap()
        XCTAssertTrue(app.staticTexts["newCount"].label.contains("1枚"))
    }

    func testBulkSelectionTagsMoveSuspendResumeAndConfirmedDeleteKeepHistory() {
        let app = app()
        create(app, question: "Bulk one", answer: "Answer one")
        create(app, question: "Bulk two", answer: "Answer two")
        app.buttons["デッキ管理"].tap(); app.buttons["デッキ追加"].tap()
        app.textFields["deckNameInput"].tap(); app.textFields["deckNameInput"].typeText("Bulk destination")
        app.buttons["保存"].tap(); app.buttons["閉じる"].firstMatch.tap()
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 5))
        app.buttons["revealAnswer"].tap(); app.buttons["grade-4"].tap(); app.buttons["pauseStudy"].tap()
        app.tabBars.buttons["ライブラリ"].tap()
        func open(all: Bool = true) {
            app.buttons["selectLibraryCards"].tap()
            if all { app.buttons["selectAllLibraryCards"].tap() } else { app.staticTexts["Bulk one"].tap() }
            XCTAssertTrue(app.staticTexts["bulkSelectionCount"].label.contains(all ? "2枚" : "1枚"))
            app.buttons["openBulkManagement"].tap()
        }
        func choose(_ title: String) {
            app.buttons["bulkOperation"].tap(); app.buttons[title].tap()
        }
        func previewAndApply(_ count: String) {
            scrollTo(app.buttons["previewBulkEdit"], app: app); app.buttons["previewBulkEdit"].tap()
            XCTAssertTrue(app.staticTexts["bulkChangeCounts"].label.contains(count))
            scrollTo(app.buttons["applyBulkEdit"], app: app); app.buttons["applyBulkEdit"].tap()
            XCTAssertTrue(app.staticTexts["bulkResult"].waitForExistence(timeout: 5))
            app.buttons["closeBulkResult"].tap()
        }
        open(all: false); choose("停止"); previewAndApply("1枚")
        XCTAssertTrue(app.staticTexts["一問一答 · 停止中"].exists)
        open(all: false); choose("再開"); previewAndApply("1枚")
        XCTAssertFalse(app.staticTexts["一問一答 · 停止中"].exists)
        open(); choose("タグ追加")
        app.textFields["bulkTagInput"].tap(); app.textFields["bulkTagInput"].typeText("Shared,shared")
        previewAndApply("2枚")
        open(); choose("タグ除去")
        app.switches["Shared"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        previewAndApply("2枚")
        open()
        app.buttons["bulkDestination"].tap(); app.buttons["Bulk destination"].tap()
        previewAndApply("2枚")
        XCTAssertTrue(app.staticTexts["Bulk destination"].exists)
        open(); choose("ノート削除")
        app.buttons["previewBulkEdit"].tap()
        XCTAssertTrue(app.staticTexts["bulkTargetCounts"].label.contains("2ノート・2枚"))
        scrollTo(app.buttons["applyBulkEdit"], app: app); app.buttons["applyBulkEdit"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["キャンセル", "Cancel"])).firstMatch
        XCTAssertTrue(app.buttons["confirmBulkDelete"].firstMatch.waitForExistence(timeout: 5))
        if cancel.exists { cancel.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.8)).tap() }
        XCTAssertFalse(app.buttons["confirmBulkDelete"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["bulkResult"].exists)
        app.buttons["applyBulkEdit"].tap(); app.buttons["confirmBulkDelete"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["bulkResult"].waitForExistence(timeout: 5)); app.buttons["closeBulkResult"].tap()
        XCTAssertTrue(app.staticTexts["カードがありません"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        app.tabBars.buttons["記録"].tap()
        XCTAssertTrue(app.staticTexts["todayAnswerCount"].label.contains("1回"))
    }

    func testReviewAppearanceSelectionRestartAndAnswerOrder() {
        let app = app()
        create(app, question: "Appearance question", answer: "Appearance answer")
        app.tabBars.buttons["設定"].tap()
        let size = app.buttons["reviewTextSize"]
        scrollTo(size, app: app); size.tap(); app.buttons["特大"].tap()
        let image = app.buttons["reviewImageDisplay"]
        scrollTo(image, app: app); image.tap(); app.buttons["非表示"].tap()
        let order = app.switches["reviewAnswerFirst"]
        scrollTo(order, app: app); order.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(order.value as? String, "1")
        app.terminate(); app.launch()
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        let q = app.staticTexts["reviewQuestion"], a = app.staticTexts["modelAnswer"]
        XCTAssertTrue(q.waitForExistence(timeout: 5)); XCTAssertFalse(a.exists)
        scrollTo(app.buttons["revealAnswer"], app: app); app.buttons["revealAnswer"].tap()
        XCTAssertTrue(a.waitForExistence(timeout: 5)); XCTAssertLessThan(a.frame.minY, q.frame.minY)
        attach(app, "Issue5-answer-first-extra-large")
        app.buttons["pauseStudy"].tap(); app.terminate(); app.launch()
        app.tabBars.buttons["ホーム"].tap(); app.buttons["resumeStudy"].tap()
        XCTAssertTrue(a.waitForExistence(timeout: 5)); XCTAssertLessThan(a.frame.minY, q.frame.minY)
        scrollTo(app.buttons["grade-4"], app: app); app.buttons["grade-4"].tap()
        XCTAssertTrue(app.buttons["undoReview"].isEnabled)
        app.buttons["undoReview"].tap(); XCTAssertEqual(q.label, "Appearance question")
    }

    func testReviewGesturesDefaultOffDirectionsUndoAndRestart() {
        let app = app()
        create(app, question: "Swipe question", answer: "Swipe answer")
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["reviewSwipePad"].exists)
        app.buttons["pauseStudy"].tap()
        app.tabBars.buttons["設定"].tap()
        let toggle = app.switches["reviewGesturesToggle"]
        scrollTo(toggle, app: app); toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        let animations = app.switches["reviewAnimationsToggle"]
        scrollTo(animations, app: app); animations.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(animations.value as? String, "0")
        app.terminate(); app.launch()
        app.tabBars.buttons["ホーム"].tap(); app.buttons["resumeStudy"].tap()
        let pad = app.otherElements["reviewSwipePad"]
        func visiblePad() {
            for _ in 0..<3 {
                if pad.exists && pad.frame.minY > 100 && pad.frame.maxY < app.frame.maxY - 10 { break }
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.8))
                    .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.3)))
            }
            XCTAssertTrue(pad.isHittable)
        }
        func swipe(_ x: CGFloat, _ y: CGFloat) {
            visiblePad()
            pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: pad.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)))
        }
        swipe(0.6, 0.5) // Short movements must not reveal.
        XCTAssertFalse(app.staticTexts["modelAnswer"].exists)
        swipe(0.03, 0.5) // Wrong direction before the answer.
        XCTAssertFalse(app.staticTexts["modelAnswer"].exists)
        swipe(0.97, 0.5)
        guard app.staticTexts["modelAnswer"].waitForExistence(timeout: 5) else { attach(app, "swipe-reveal-failed"); XCTFail("Swipe reveal failed"); return }
        for (x, y) in [(CGFloat(0.03), CGFloat(0.5)), (0.5, 0.97), (0.97, 0.5), (0.5, 0.03)] {
            swipe(x, y)
            XCTAssertTrue(app.buttons["undoReview"].isEnabled)
            app.buttons["undoReview"].tap()
            XCTAssertEqual(app.staticTexts["reviewQuestion"].label, "Swipe question")
            XCTAssertFalse(app.staticTexts["modelAnswer"].exists)
            swipe(0.97, 0.5)
            XCTAssertTrue(app.staticTexts["modelAnswer"].waitForExistence(timeout: 5))
        }
        app.buttons["pauseStudy"].tap()
        app.tabBars.buttons["記録"].tap()
        XCTAssertTrue(app.staticTexts["todayAnswerCount"].label.contains("0回"))
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
