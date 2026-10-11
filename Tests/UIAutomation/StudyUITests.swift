import XCTest
import UIKit

final class StudyUITests: XCTestCase {
    func testReviewHomeSeparatesAnswerLimitAndCardPoolAndStartsInOneTap() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-notification-due"]
        app.launch()
        let review = app.buttons["start-review"]
        XCTAssertTrue(review.waitForExistence(timeout: 15))
        XCTAssertTrue(review.isHittable)
        XCTAssertTrue(review.label.contains("最大20問"))
        XCTAssertTrue(review.label.contains("復習できるカード：1枚"))
        XCTAssertLessThan(review.frame.maxY, app.tabBars.firstMatch.frame.minY)
        attach(app, "Issue88-review-answer-limit-and-card-pool")
        review.tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 10))
    }

    func testHomeAnswerLimitChangesLabelsAndKeepsResumeIndependent() {
        let app = app()
        create(app, question: "Home limit question", answer: "Answer")
        app.tabBars.buttons["ホーム"].tap()
        let start = app.buttons["start-new"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(start.label.contains("最大20問"))
        XCTAssertTrue(start.label.contains("新しく学べるカード：1枚"))
        for limit in [10, 30, 0, 20] {
            app.buttons["openSessionAnswerLimit"].tap()
            let choice = app.buttons[limit == 0 ? "すべて（上限なし）" : "\(limit)問"]
            scrollTo(choice, app: app); choice.tap()
            app.buttons["閉じる"].tap()
            XCTAssertTrue(start.label.contains(limit == 0 ? "上限なし" : "最大\(limit)問"))
            XCTAssertTrue(start.label.contains("1枚"))
            let mixed = app.buttons["start-mixed"]
            scrollTo(mixed, app: app)
            XCTAssertTrue(mixed.label.contains(limit == 0 ? "上限なし" : "最大\(limit)問"))
            XCTAssertTrue(mixed.label.contains("1枚"))
            for _ in 0..<3 { app.swipeDown() }
        }
        scrollTo(start, app: app); start.tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 10))
        app.buttons["pauseStudy"].tap()
        app.buttons["openSessionAnswerLimit"].tap()
        app.buttons["10問"].tap(); app.buttons["閉じる"].tap()
        XCTAssertEqual(app.buttons["resumeStudy"].label, "続きから再開")
        app.buttons["resumeStudy"].tap()
        XCTAssertTrue(app.staticTexts["remainingQuestions"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["remainingQuestions"].label, "残り20問")
        attach(app, "Issue88-resume-keeps-original-limit")
    }
    #if targetEnvironment(macCatalyst)
    func testMacKeyboardEditStudyAndSharedWindows() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-numeric-mask"]
        app.launch()
        let library = app.buttons["sidebarTab-1"]
        XCTAssertTrue(library.waitForExistence(timeout: 20))
        app.typeKey("2", modifierFlags: .command)
        let note = app.staticTexts["Numeric mask fixture"]
        XCTAssertTrue(note.waitForExistence(timeout: 10)); note.tap()
        app.buttons["editNote"].tap()
        let question = app.descendants(matching: .any)["questionInput"]
        XCTAssertTrue(question.waitForExistence(timeout: 10)); question.tap(); question.typeText(" Mac edited")
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editNote"].waitForExistence(timeout: 10))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.buttons["start-new"].waitForExistence(timeout: 10)); app.buttons["start-new"].tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["reviewQuestion"].label.contains("Mac edited"))
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: .command)
        XCTAssertTrue(app.buttons["grade-4"].waitForExistence(timeout: 10))
        app.typeKey("4", modifierFlags: .command)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 10))
        app.buttons["pauseStudy"].tap()
        let windows = app.windows.count
        app.typeKey("n", modifierFlags: [.command, .shift])
        let extra = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.windows.count > windows }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [extra], timeout: 10), .completed)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Issue20-Mac-windows"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }
    #endif

    private func iPadFourFormatsInPortraitAndLandscape() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad simulator acceptance") }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-hints"]
        app.launch()
        XCTAssertTrue(app.buttons["start-new"].waitForExistence(timeout: 20)); app.buttons["start-new"].tap()
        var seen = Set<String>()
        for index in 0..<7 {
            XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 10))
            seen.insert(app.staticTexts["reviewQuestion"].label)
            XCUIDevice.shared.orientation = index.isMultiple(of: 2) ? .portrait : .landscapeLeft
            app.buttons["revealAnswer"].tap()
            XCTAssertTrue(app.buttons["grade-4"].isHittable); app.buttons["grade-4"].tap()
        }
        XCTAssertGreaterThanOrEqual(seen.count, 4)
        XCTAssertTrue(app.buttons["finishReview"].waitForExistence(timeout: 10))
        app.buttons["finishReview"].tap()
    }

    func testIPadHierarchyFilterAndAccessibleSidebar() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad simulator acceptance") }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-home-filters"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebarTab-1"].waitForExistence(timeout: 20))
        let expand = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "の子デッキを開閉")).firstMatch
        XCTAssertTrue(expand.waitForExistence(timeout: 5)); expand.tap()
        let child = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ENDSWITH %@", "sidebarDeck-", "Child")).firstMatch
        XCTAssertTrue(child.waitForExistence(timeout: 5)); child.tap()
        XCTAssertTrue(app.staticTexts["Both tags"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Other card"].exists)
        try app.performAccessibilityAudit(for: .sufficientElementDescription)
        app.buttons["sidebarTab-1"].tap()
        XCTAssertTrue(app.staticTexts["Other card"].waitForExistence(timeout: 5))
        app.terminate()
        try iPadFourFormatsInPortraitAndLandscape()
    }

    func testIPadSidebarRotationEditAndStudy() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad simulator acceptance") }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-numeric-mask"]
        app.launch()
        let library = app.buttons["sidebarTab-1"]
        XCTAssertTrue(library.waitForExistence(timeout: 20)); library.tap()
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertTrue(app.buttons["openOCR"].exists)
        XCTAssertTrue(app.buttons["openImport"].exists)
        app.staticTexts["Numeric mask fixture"].tap()
        app.buttons["editNote"].tap()
        let question = app.descendants(matching: .any)["questionInput"]
        XCTAssertTrue(question.waitForExistence(timeout: 10))
        question.tap(); question.typeText(" iPad edited")
        app.buttons["saveNote"].tap()
        XCTAssertTrue(app.buttons["editNote"].waitForExistence(timeout: 10))
        // Rotate while a pushed detail is present; the shared store must survive.
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.orientation = .landscapeLeft
        let home = app.buttons["sidebarTab-0"]
        XCTAssertTrue(home.waitForExistence(timeout: 10)); home.tap()
        app.buttons["start-new"].tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 10))
        let text = app.staticTexts["reviewQuestion"]
        XCTAssertTrue(text.label.contains("iPad edited"))
        XCTAssertLessThanOrEqual(text.frame.width, 760)
        app.buttons["revealAnswer"].tap(); app.buttons["grade-4"].tap()
        app.buttons["undoReview"].tap()
        XCTAssertTrue(app.buttons["revealAnswer"].exists)
        app.buttons["pauseStudy"].tap()
        app.buttons["sidebarTab-2"].tap()
        XCTAssertTrue(app.staticTexts["todayAnswerCount"].waitForExistence(timeout: 10))
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Issue19-iPad-sidebar"
        image.lifetime = .keepAlways; add(image)
    }

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
    func testVerticalRubyPreviewLearningUndoAndRelaunch() {
        richTextScenario(question: "｜春暁《しゅんぎょう》12年。\n｜東京《とうきょう》", prefix: "Issue51-vertical-ruby")
    }
    func testKanbunPreviewLearningUndoAndRelaunch() {
        richTextScenario(question: "不［＃（ズ）］［＃レ］知［＃（ラ）］。\n｜未《いま》［＃「未」の左に「ザル」のルビ］［＃（ダ）］［＃レ］若［＃（カ）］［＃二］知［＃（シクシテ）］［＃一レ］。", prefix: "Issue52-kanbun")
    }
    private func richTextScenario(question source: String, prefix: String) {
        let app = app()
        app.tabBars.buttons["ライブラリ"].tap(); app.buttons["addNote"].tap()
        let layout = app.buttons["questionLayout"]
        scrollTo(layout, app: app); layout.tap(); app.buttons["縦書き"].tap()
        let question = app.descendants(matching: .any)["questionInput"]
        scrollTo(question, app: app); question.tap(); question.typeText(source)
        let answer = app.descendants(matching: .any)["answerInput"]
        scrollTo(answer, app: app); answer.tap(); answer.typeText("Answer remains hidden")
        let preview = app.buttons["previewNote"]
        scrollTo(preview, app: app); preview.tap()
        XCTAssertTrue(app.descendants(matching: .any)["previewQuestion"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["previewAnswer"].exists)
        attach(app, prefix + "-preview")
        app.buttons["previewReveal"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["previewAnswer"].exists)
        app.buttons["closePreview"].tap(); app.buttons["saveNote"].tap()
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["reviewQuestion"].waitForExistence(timeout: 10))
        attach(app, prefix + "-review")
        app.buttons["revealAnswer"].tap(); app.buttons["grade-3"].tap()
        app.buttons["undoReview"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["reviewQuestion"].exists)
        app.terminate(); app.launch()
        app.buttons["resumeStudy"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["reviewQuestion"].waitForExistence(timeout: 10))
    }

    func testWeakPracticeRevealFinishLeavesNormalSessionAvailable() {
        let app = app()
        create(app, question: "Weak practice question", answer: "Weak practice answer")
        app.tabBars.buttons["ホーム"].tap()
        app.buttons["start-new"].tap()
        app.buttons["revealAnswer"].tap()
        app.buttons["grade-1"].tap()
        app.buttons["pauseStudy"].tap()
        app.tabBars.buttons["ライブラリ"].tap()
        app.buttons["openWeakCards"].tap()
        XCTAssertTrue(app.staticTexts["直近の評価がAgain"].waitForExistence(timeout: 5))
        app.buttons["startWeakPractice"].tap()
        XCTAssertTrue(app.staticTexts["weakPracticeQuestion"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["weakPracticeAnswer"].exists)
        app.buttons["revealWeakPractice"].tap()
        XCTAssertEqual(app.staticTexts["weakPracticeAnswer"].label, "Weak practice answer")
        app.buttons["nextWeakPractice"].tap()
        app.buttons["finishWeakPractice"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["ホーム"].tap()
        XCTAssertTrue(app.buttons["resumeStudy"].exists || app.staticTexts["nextShortReview"].exists)
    }

    func testDeckLearningOverrideSavesAndSurvivesRelaunch() {
        let app = app()
        create(app, question: "Deck settings", answer: "A")
        app.buttons["デッキ管理"].tap()
        app.buttons["マイデッキを編集"].tap()
        let limit = app.switches["新規上限を指定"]
        scrollTo(limit, app: app); limit.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(limit.value as? String, "1")
        let retention = app.switches["目標保持率を指定"]
        scrollTo(retention, app: app); retention.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(retention.value as? String, "1")
        app.buttons["保存"].tap()
        app.terminate(); app.launch()
        app.tabBars.buttons["ライブラリ"].tap()
        app.buttons["デッキ管理"].tap()
        app.buttons["マイデッキを編集"].tap()
        XCTAssertEqual(app.switches["新規上限を指定"].value as? String, "1")
        XCTAssertEqual(app.switches["目標保持率を指定"].value as? String, "1")
        XCTAssertTrue(app.staticTexts["新規上限：20枚／日"].exists)
    }

    func testHomeResponseSettingPersistsAndStartsTyping() {
        let app = app()
        create(app, question: "Mode snapshot", answer: "Tokyo")
        app.tabBars.buttons["ホーム"].tap()
        app.buttons["openSessionAnswerLimit"].tap()
        app.buttons["sessionResponseMode"].tap()
        app.buttons["文字入力"].tap()
        app.buttons["閉じる"].tap()
        app.terminate(); app.launch()
        app.buttons["openSessionAnswerLimit"].tap()
        XCTAssertTrue(app.buttons["sessionResponseMode"].label.contains("文字入力"))
        app.buttons["閉じる"].tap()
        app.buttons["start-new"].tap()
        XCTAssertTrue(app.textFields["typedAnswer"].waitForExistence(timeout: 10)
            || app.textViews["typedAnswer"].exists)
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
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", question)).firstMatch.waitForExistence(timeout: 5))
    }
    func scrollTo(_ element: XCUIElement, app: XCUIApplication) {
        // Form text fields scroll themselves into view when tapped, including
        // when the keyboard covers part of a large Dynamic Type form.
        if element.exists && [.textField, .textView].contains(element.elementType) { return }
        if app.keyboards.firstMatch.exists {
            if app.buttons["dismissBulkKeyboard"].exists { app.buttons["dismissBulkKeyboard"].tap() }
            else if let done = app.buttons.matching(NSPredicate(format: "label == %@", "完了")).allElementsBoundByIndex.first(where: { $0.isHittable }) { done.tap() }
        }
        var missingSearches = 0
        for _ in 0..<35 {
            var top = (app.navigationBars.allElementsBoundByIndex.map { $0.frame.maxY }.max() ?? app.frame.minY) + 8
            let progress = app.progressIndicators["sessionProgressBar"]
            if progress.exists { top = max(top, progress.frame.maxY + 8) }
            let fixedControl = element.exists && (element.identifier.hasPrefix("grade-") || element.identifier == "revealAnswer")
            if fixedControl && element.isHittable { return }
            var bottom = app.frame.maxY - 16
            if app.buttons["pauseStudy"].exists {
                let footer = app.buttons["grade-1"].exists ? app.buttons["grade-1"] : app.buttons["revealAnswer"]
                if footer.exists { bottom = min(bottom, footer.frame.minY - 8) }
            } else if app.tabBars.firstMatch.exists && app.tabBars.firstMatch.isHittable {
                bottom = min(bottom, app.tabBars.firstMatch.frame.minY - 8)
            }
            if element.exists && element.isHittable && element.frame.minY >= top && element.frame.maxY <= bottom { return }
            let down = element.exists ? element.frame.minY < top : missingSearches < 6
            if !element.exists { missingSearches += 1 }
            let low = top + 0.2 * max(40, bottom - top)
            let high = top + 0.8 * max(40, bottom - top)
            let start = (down ? low : high) / app.frame.height
            let end = (down ? high : low) / app.frame.height
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: start))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: end)))
        }
        XCTAssertTrue(element.exists && element.isHittable, "Required control must be visible")
    }
    func attach(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name
        image.lifetime = .keepAlways; add(image)
    }

    func testDetailedStatisticsPeriodsAndCommittedAnswerUpdates() {
        let app = app()
        create(app, question: "Stats first", answer: "One")
        create(app, question: "Stats second", answer: "Two")
        app.tabBars.buttons["ホーム"].tap()
        app.buttons["start-new"].tap()
        app.buttons["revealAnswer"].tap()
        scrollTo(app.buttons["grade-4"], app: app)
        app.buttons["grade-4"].tap()
        app.buttons["pauseStudy"].tap()
        app.tabBars.buttons["記録"].tap()
        let count = app.staticTexts["todayAnswerCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        XCTAssertTrue(count.label.contains("1回"))
        for period in ["週", "月", "日"] {
            let button = app.segmentedControls.buttons[period]
            scrollTo(button, app: app)
            button.tap()
            XCTAssertTrue(button.isSelected)
        }
        let numbers = app.buttons["期間ごとの数値を表示"]
        scrollTo(numbers, app: app)
        XCTAssertTrue(numbers.exists)
        numbers.tap()
        attach(app, "Issue9-accessible-period-values")
        app.tabBars.buttons["ホーム"].tap()
        app.buttons["resumeStudy"].tap()
        app.buttons["revealAnswer"].tap()
        scrollTo(app.buttons["grade-4"], app: app)
        app.buttons["grade-4"].tap()
        app.buttons["pauseStudy"].tap()
        app.tabBars.buttons["記録"].tap()
        scrollTo(count, app: app)
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        XCTAssertTrue(count.label.contains("2回"))
    }

    func testDeckContentsMoveAndCancelledThenConfirmedDeleteKeepDecks() {
        deckContentsScenario(accessibility: false)
    }

    func testDeckContentsLargestDynamicTypeMoveAndDeleteKeepsDecks() {
        deckContentsScenario(accessibility: true)
    }

    private func deckContentsScenario(accessibility: Bool) {
        let app = app()
        if accessibility {
            app.terminate()
            app.launchArguments.append("-study-test-accessibility")
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["ライブラリ"].waitForExistence(timeout: 15))
            app.tabBars.buttons["ライブラリ"].tap()
        }
        create(app, question: "Bulk deck one", answer: "One")
        create(app, question: "Bulk deck two", answer: "Two")
        app.buttons["デッキ管理"].tap()
        app.buttons["デッキ追加"].tap()
        let name = app.textFields["deckNameInput"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Destination")
        app.buttons["保存"].tap()
        let source = app.buttons["マイデッキを編集"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.tap()
        scrollTo(app.buttons["moveDeckContents"], app: app)
        app.buttons["moveDeckContents"].tap()
        scrollTo(app.buttons["deckContentsDestination"], app: app)
        app.buttons["deckContentsDestination"].tap()
        app.buttons["Destination"].tap()
        scrollTo(app.buttons["previewDeckContents"], app: app)
        app.buttons["previewDeckContents"].tap()
        scrollTo(app.staticTexts["deckContentsTargetCounts"], app: app)
        XCTAssertTrue(app.staticTexts["deckContentsTargetCounts"].label.contains("2ノート"))
        if accessibility { attach(app, "Issue41-largest-type-preview") }
        scrollTo(app.buttons["commitDeckContents"], app: app)
        app.buttons["commitDeckContents"].tap()
        app.buttons["2ノート・2枚を移動"].tap()
        scrollTo(app.staticTexts["deckContentsResult"], app: app)
        XCTAssertTrue(app.staticTexts["deckContentsResult"].waitForExistence(timeout: 5))
        scrollTo(app.buttons["戻る"], app: app)
        app.buttons["戻る"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        let destination = app.buttons["Destinationを編集"]
        XCTAssertTrue(destination.exists)
        destination.tap()
        scrollTo(app.buttons["deleteDeckContents"], app: app)
        app.buttons["deleteDeckContents"].tap()
        scrollTo(app.buttons["previewDeckContents"], app: app)
        app.buttons["previewDeckContents"].tap()
        scrollTo(app.staticTexts["deckContentsTargetCounts"], app: app)
        XCTAssertTrue(app.staticTexts["deckContentsTargetCounts"].label.contains("2ノート"))
        scrollTo(app.buttons["commitDeckContents"], app: app)
        app.buttons["commitDeckContents"].tap()
        if app.buttons["キャンセル"].exists {
            app.buttons["キャンセル"].tap()
        } else {
            // Newer system popovers omit the cancel row; tapping the title
            // outside the confirmation dismisses it without executing deletion.
            app.navigationBars.firstMatch.staticTexts.firstMatch.tap()
        }
        XCTAssertFalse(app.staticTexts["deckContentsResult"].exists)
        scrollTo(app.buttons["commitDeckContents"], app: app)
        app.buttons["commitDeckContents"].tap()
        app.buttons["2ノート・2枚を削除"].tap()
        scrollTo(app.staticTexts["deckContentsResult"], app: app)
        XCTAssertTrue(app.staticTexts["deckContentsResult"].waitForExistence(timeout: 5))
        scrollTo(app.buttons["戻る"], app: app)
        app.buttons["戻る"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(destination.exists)
        app.buttons["閉じる"].tap()
        XCTAssertFalse(app.staticTexts["Bulk deck one"].exists)
        XCTAssertFalse(app.staticTexts["Bulk deck two"].exists)
    }

    func testSessionShowsRemainingAnswersInsteadOfDailyGoal() {
        let app = app()
        create(app, question: "Progress test question", answer: "Progress test answer")
        create(app, question: "Progress test question 2", answer: "Progress test answer 2")
        app.tabBars.buttons["ホーム"].tap()
        XCTAssertTrue(app.buttons["openSessionAnswerLimit"].exists)
        XCTAssertTrue(app.buttons["start-new"].waitForExistence(timeout: 15))
        app.buttons["start-new"].tap()
        let remaining = app.staticTexts["remainingQuestions"]
        XCTAssertTrue(remaining.waitForExistence(timeout: 10))
        XCTAssertEqual(remaining.label, "残り20問")
        XCTAssertTrue(app.progressIndicators["sessionProgressBar"].exists)
        XCTAssertFalse(app.staticTexts["reviewGoalProgress"].exists)
        app.buttons["revealAnswer"].tap()
        app.buttons["grade-4"].tap()
        XCTAssertEqual(remaining.label, "残り19問")
        app.buttons["undoReview"].tap()
        XCTAssertEqual(remaining.label, "残り20問")
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

    func editNumber(_ app: XCUIApplication, id: String, text: String, done: Bool = true) {
        let field = app.textFields[id]
        for _ in 0..<25 where !field.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.7))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)))
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        app.buttons[id + "Clear"].tap()
        field.typeText(text)
        if done { app.buttons[id + "Done"].tap() }
    }

    func testNumericSettingsLargestTypeAndDarkMode() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-accessibility"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["設定"].waitForExistence(timeout: 15))
        app.tabBars.buttons["設定"].tap()
        editNumber(app, id: "dailyNewLimit", text: "200")
        XCTAssertTrue((app.textFields["dailyNewLimit"].value as? String)?.contains("200") == true)
        XCTAssertEqual(app.textFields["dailyNewLimit"].label, "1日の新規上限")
        attach(app, "Issue42-largest-type-dark")
    }

    func testNumericSettingsDirectInputValidationCancellationAndRelaunch() {
        let app = app()
        XCTAssertTrue(app.tabBars.buttons["設定"].waitForExistence(timeout: 15))
        app.tabBars.buttons["設定"].tap()
        for value in ["200", "10", "0", "500"] {
            editNumber(app, id: "dailyNewLimit", text: value)
            XCTAssertTrue((app.textFields["dailyNewLimit"].value as? String)?.contains(value) == true)
        }
        editNumber(app, id: "dailyNewLimit", text: "501")
        XCTAssertTrue(app.staticTexts["dailyNewLimitError"].exists)
        app.buttons["dailyNewLimitCancel"].tap()
        XCTAssertTrue((app.textFields["dailyNewLimit"].value as? String)?.contains("500") == true)
        editNumber(app, id: "dailyNewLimit", text: "200", done: false)
        app.buttons["dailyNewLimitCancel"].tap()
        XCTAssertTrue((app.textFields["dailyNewLimit"].value as? String)?.contains("500") == true)
        for value in ["200", "1", "500"] { editNumber(app, id: "dailyGoal", text: value) }
        let toggle = app.switches["dailyGoalToggle"]
        for _ in 0..<5 where toggle.frame.minY < 100 { app.swipeDown() }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.textFields["dailyGoal"])
        waitForExpectations(timeout: 5)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap(); XCTAssertTrue((app.textFields["dailyGoal"].value as? String)?.contains("500") == true)
        for value in ["0", "23"] { editNumber(app, id: "dayStartHour", text: value) }
        for value in ["80", "90", "97"] { editNumber(app, id: "desiredRetention", text: value) }
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["設定"].waitForExistence(timeout: 15))
        app.tabBars.buttons["設定"].tap()
        XCTAssertTrue((app.textFields["dailyNewLimit"].value as? String)?.contains("500") == true)
        XCTAssertTrue((app.textFields["dailyGoal"].value as? String)?.contains("500") == true)
        let field = app.textFields["dayStartHour"]
        for _ in 0..<25 where !field.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.7))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)))
        }
        XCTAssertTrue((field.value as? String)?.contains("23") == true)
        attach(app, "Issue42-numeric-settings")
    }

    func testNewLimitNavigationRefreshAndRelaunch() {
        let app = app()
        create(app, question: "Limit question", answer: "Limit answer")
        app.tabBars.buttons["設定"].tap()
        let limit = app.textFields["dailyNewLimit"]
        XCTAssertTrue(limit.waitForExistence(timeout: 5))
        editNumber(app, id: "dailyNewLimit", text: "0")
        app.tabBars.buttons["ホーム"].tap()
        let change = app.buttons["changeNewLimit"]
        scrollTo(change, app: app)
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["newLimitRemaining"].label.contains("1枚"))
        attach(app, "Issue36-limit-reached")
        change.tap()
        XCTAssertTrue(app.navigationBars["学習設定"].waitForExistence(timeout: 5))
        editNumber(app, id: "dailyNewLimit", text: "1")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["start-new"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["start-new"].isEnabled)
        XCTAssertFalse(app.buttons["changeNewLimit"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["start-new"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["start-new"].isEnabled)
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
        XCTAssertTrue(app.staticTexts["primaryNewCount"].label.contains("1枚"))
        XCTAssertFalse(app.buttons["start-review"].isEnabled)
        scrollTo(app.buttons["start-mixed"], app: app); app.buttons["start-mixed"].tap()
        XCTAssertTrue(app.staticTexts["reviewQuestion"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reviewQuestion"].label, "Both tags")
        app.buttons["pauseStudy"].tap()
        let filter = app.buttons["openStudyFilter"]
        for _ in 0..<8 where !filter.exists || !filter.isHittable { app.swipeDown() }
        filter.tap(); app.buttons["resetStudyFilter"].tap()
        app.buttons["applyStudyFilter"].tap()
        scrollTo(app.staticTexts["newCount"], app: app)
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
        XCTAssertFalse(app.buttons["start-new"].isEnabled)
        scrollTo(app.buttons["start-mixed"], app: app); XCTAssertFalse(app.buttons["start-mixed"].isEnabled)
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
        scrollTo(app.buttons["start-new"], app: app)
        XCTAssertFalse(app.buttons["start-new"].isEnabled)
        scrollTo(app.buttons["start-mixed"], app: app)
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
        func assertNewCount(_ count: Int) {
            let countLabel = app.staticTexts["newCount"]
            for _ in 0..<8 where !countLabel.exists || !countLabel.isHittable { app.swipeUp() }
            XCTAssertTrue(app.staticTexts["newCount"].label.contains("\(count)枚"))
        }
        func selectEmpty() {
            let filter = app.buttons["openStudyFilter"]
            for _ in 0..<8 where !filter.isHittable { app.swipeDown() }
            filter.tap()
            app.buttons["studyDeckPicker"].tap(); app.buttons["Empty deck"].tap()
        }
        selectEmpty(); app.buttons["cancelStudyFilter"].tap()
        assertNewCount(1)
        selectEmpty(); app.buttons["applyStudyFilter"].tap()
        assertNewCount(0)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["resumeStudy"].waitForExistence(timeout: 15))
        assertNewCount(0)
        let resume = app.buttons["resumeStudy"]
        for _ in 0..<8 where !resume.isHittable { app.swipeDown() }
        resume.tap()
        XCTAssertFalse(app.buttons["新しく覚えるへ切り替える"].exists)
        XCTAssertTrue(input.waitForExistence(timeout: 5)); XCTAssertEqual(input.value as? String, "Preserved draft")
        app.buttons["pauseStudy"].tap(); app.buttons["openStudyFilter"].tap()
        app.buttons["resetStudyFilter"].tap(); app.buttons["applyStudyFilter"].tap()
        assertNewCount(1)
    }

    func testOptimizationInsufficientHistoryDoesNotChangeSettings() {
        let app = app()
        app.tabBars.buttons["設定"].tap()
        let open = app.buttons["openFSRSOptimization"]
        scrollTo(open, app: app); open.tap()
        XCTAssertTrue(app.staticTexts["optimizationStatus"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["optimizationStatus"].label.contains("標準"))
        app.buttons["computeFSRSParameters"].tap()
        XCTAssertTrue(app.staticTexts["optimizationFailure"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["optimizationFailure"].label.contains("400件"))
        XCTAssertFalse(app.buttons["resetFSRSParameters"].isEnabled)
        app.terminate(); app.launch()
        app.tabBars.buttons["設定"].tap(); scrollTo(open, app: app); open.tap()
        XCTAssertTrue(app.staticTexts["optimizationStatus"].label.contains("標準"))
    }

    func testForecastPeriodDeckAndAccessibleCountsLeaveLearningUnchanged() {
        let app = app()
        create(app, question: "Forecast new", answer: "A")
        app.tabBars.buttons["記録"].tap()
        app.buttons["openReviewForecast"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["forecastScheduled"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["forecastAnswers"].exists)
        app.segmentedControls["forecastPeriod"].buttons["30日"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["forecastScheduled"].waitForExistence(timeout: 15))
        app.buttons["forecastDeck"].tap(); app.buttons["マイデッキ"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["forecastAnswers"].waitForExistence(timeout: 15))
        attach(app, "forecast-normal-30-days")
        app.tabBars.buttons["ホーム"].tap()
        XCTAssertTrue(app.staticTexts["newCount"].label.contains("1枚"))
        app.buttons["start-new"].tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 5))
    }

    func testLibrarySelectionExitSearchAndCancelKeepTargets() {
        let app = app()
        create(app, question: "Selection one", answer: "One")
        create(app, question: "Selection two", answer: "Two")
        XCTAssertFalse(app.buttons["openBulkManagement"].exists)
        app.buttons["libraryActions"].tap(); app.buttons["selectLibraryCards"].tap()
        XCTAssertFalse(app.buttons["openBulkManagement"].isEnabled)
        app.buttons["finishLibrarySelection"].tap()
        XCTAssertFalse(app.buttons["openBulkManagement"].exists)
        app.buttons["libraryActions"].tap(); app.buttons["selectLibraryCards"].tap()
        app.staticTexts["Selection one"].tap()
        app.buttons["openBulkManagement"].tap()
        app.buttons["closeBulkManagement"].tap()
        XCTAssertTrue(app.staticTexts["bulkSelectionCount"].label.contains("1枚"))
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("two")
        // iOS 26 hides navigation items while searching; the selection-only action remains visible.
        XCTAssertFalse(app.buttons["openBulkManagement"].isEnabled)
        app.staticTexts["Selection two"].tap()
        XCTAssertTrue(app.buttons["openBulkManagement"].isEnabled)
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
            app.buttons["libraryActions"].tap()
            app.buttons["selectLibraryCards"].tap()
            if all { app.buttons["選択"].tap(); app.buttons["selectAllLibraryCards"].tap() } else { app.staticTexts["Bulk one"].tap() }
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
            for _ in 0..<8 {
                // safeAreaInset changes visible content, but XCTest still reports
                // the ScrollView's frame as the whole screen. Use fixed controls
                // to determine the actual viewport rather than that frame.
                let progress = app.progressIndicators["sessionProgressBar"]
                let top = max(app.navigationBars.firstMatch.frame.maxY,
                              progress.exists ? progress.frame.maxY + 12 : 0)
                let footer = app.buttons["grade-1"].exists ? app.buttons["grade-1"] : app.buttons["revealAnswer"]
                let bottom = footer.frame.minY - 12
                if pad.exists && pad.frame.minY >= top && pad.frame.maxY <= bottom { break }
                // Scroll on ordinary text, outside the dedicated swipe pad.
                // The pad intentionally reserves vertical drags for grading.
                let towardTop = !pad.exists || pad.frame.minY >= top
                let start = towardTop ? min(bottom - 20, pad.exists ? pad.frame.minY - 20 : bottom - 20)
                    : max(top + 20, pad.frame.maxY + 20)
                let end = towardTop ? top + 20 : bottom - 20
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: start / app.frame.height))
                    .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: end / app.frame.height)))
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

    func testNewLongTermDueShowsModeGuidanceAndKeepsUndo() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-new-review-due"]
        app.launch()
        XCTAssertTrue(app.staticTexts["reviewEmptyTitle"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["reviewEmptyTitle"].label, "今回の新規学習は完了しました")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "復習期限に達したカードは「復習する」")).firstMatch.exists)
        XCTAssertTrue(app.buttons["undoReview"].isEnabled)
        let finish = app.buttons["finishReview"]
        XCTAssertTrue(finish.isHittable)
        XCTAssertGreaterThanOrEqual(finish.frame.width, app.frame.width * 0.8)
        XCTAssertGreaterThan(finish.frame.minY, app.frame.height * 0.7)
        attach(app, "PR46-new-long-term-due")
        app.buttons["undoReview"].tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reviewQuestion"].label, "Long-term review")
    }

    func testWaitingEmptyStateInDarkLargestTypeCanFinish() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-accessibility"]
        app.launch()
        create(app, question: "Waiting question", answer: "Answer")
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        scrollTo(app.buttons["revealAnswer"], app: app); app.buttons["revealAnswer"].tap()
        scrollTo(app.buttons["grade-1"], app: app); app.buttons["grade-1"].tap()
        XCTAssertTrue(app.staticTexts["reviewEmptyTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reviewEmptyTitle"].label, "今出題できるカードはありません")
        scrollTo(app.staticTexts["reviewNextShortDue"], app: app)
        XCTAssertTrue(app.staticTexts["reviewNextShortDue"].exists)
        XCTAssertTrue(app.buttons["finishReview"].isHittable)
        let fixedFrame = app.buttons["finishReview"].frame
        app.swipeDown()
        XCTAssertEqual(app.buttons["finishReview"].frame.minY, fixedFrame.minY, accuracy: 2)
        XCTAssertGreaterThanOrEqual(fixedFrame.width, app.frame.width * 0.8)
        attach(app, "Issue37-waiting-dark-largest-type")
        app.buttons["finishReview"].tap()
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["resumeStudy"].exists)
    }

    func testFinishEmptySessionKeepsUndoUntilCompletion() {
        let app = app()
        create(app, question: "Finish question", answer: "Answer")
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 5))
        app.buttons["revealAnswer"].tap(); app.buttons["grade-4"].tap()
        XCTAssertTrue(app.staticTexts["reviewEmptyTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reviewEmptyTitle"].label, "今回はここまで")
        XCTAssertEqual(app.buttons["pauseStudy"].label, "閉じる")
        XCTAssertGreaterThan(app.staticTexts["reviewEmptyTitle"].frame.minY, app.frame.height * 0.25)
        XCTAssertGreaterThanOrEqual(app.buttons["finishReview"].frame.height, 56)
        XCTAssertGreaterThanOrEqual(app.buttons["finishReview"].frame.width, app.frame.width * 0.8)
        XCTAssertGreaterThan(app.buttons["finishReview"].frame.minY, app.frame.height * 0.7)
        attach(app, "Issue37-complete")
        let another = app.buttons["startAnotherSession"]
        scrollTo(another, app: app)
        another.tap()
        XCTAssertTrue(app.alerts["処理を完了できませんでした"].waitForExistence(timeout: 5))
        app.alerts.buttons["閉じる"].tap()
        XCTAssertTrue(app.buttons["undoReview"].isEnabled)
        app.buttons["undoReview"].tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 5))
        app.buttons["revealAnswer"].tap(); app.buttons["grade-4"].tap()
        app.buttons["finishReview"].tap()
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["resumeStudy"].exists)
        XCTAssertFalse(app.buttons["completeStudy"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["resumeStudy"].exists)
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
        XCTAssertTrue(app.buttons["completeStudy"].waitForExistence(timeout: 15))
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

    func testReviewActionsStayVisibleAfterScrollingLongContentAndUndo() {
        let app = app()
        let question = Array(repeating: "Explain why the correct answer follows from the evidence.", count: 4).joined(separator: " ")
        let answer = Array(repeating: "The explanation includes several distinct steps and supporting examples.", count: 6).joined(separator: " ")
        create(app, question: question, answer: answer)
        app.tabBars.buttons["ホーム"].tap()
        app.buttons["start-new"].tap()
        let reveal = app.buttons["revealAnswer"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 5))
        XCTAssertTrue(reveal.isHittable)
        for _ in 0..<3 { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(reveal.isHittable, "Revealing must never require a scroll to the bottom")
        reveal.tap()
        let again = app.buttons["grade-1"]
        let easy = app.buttons["grade-4"]
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        XCTAssertTrue(easy.isHittable)
        XCTAssertGreaterThanOrEqual(easy.frame.height, 44)
        for _ in 0..<3 { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(again.isHittable)
        XCTAssertTrue(easy.isHittable, "FSRS ratings must stay accessible during content scrolling")
        XCTAssertTrue(app.staticTexts["modelAnswer"].exists)
        attach(app, "Issue54-fixed-review-buttons")
        easy.tap()
        app.buttons["undoReview"].tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["revealAnswer"].isHittable)
    }

    func testReviewGradesUseTwoRowsForAccessibilityType() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-accessibility"]
        app.launch()
        create(app, question: "Accessibility question", answer: "Accessibility answer")
        app.tabBars.buttons["ホーム"].tap()
        app.buttons["start-new"].tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 5))
        app.buttons["revealAnswer"].tap()

        let again = app.buttons["grade-1"]
        let hard = app.buttons["grade-2"]
        let good = app.buttons["grade-3"]
        let easy = app.buttons["grade-4"]
        XCTAssertTrue(easy.waitForExistence(timeout: 5))
        for button in [again, hard, good, easy] {
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        XCTAssertLessThan(abs(again.frame.height - hard.frame.height), 8, "Grade names should fit without breaking a word across lines")
        XCTAssertLessThan(abs(again.frame.midY - hard.frame.midY), 8)
        XCTAssertLessThan(abs(good.frame.midY - easy.frame.midY), 8)
        XCTAssertGreaterThan(good.frame.midY, again.frame.midY + 20)
        XCTAssertTrue(again.label.contains("もう一度"))
        XCTAssertTrue(easy.label.contains("簡単だった"))
        attach(app, "Issue54-accessibility-two-column-ratings")
    }

    func testReviewRevealIsAccessibleWhileTypingKeyboardIsVisible() {
        let app = app()
        create(app, question: "Keyboard review question", answer: "Keyboard review answer")
        app.tabBars.buttons["ホーム"].tap()
        app.buttons["start-new"].tap()
        app.segmentedControls.buttons["文字入力"].tap()
        let draft = app.descendants(matching: .any)["typedAnswer"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.tap()
        draft.typeText("My typed response")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let reveal = app.buttons["revealAnswer"]
        XCTAssertTrue(reveal.isHittable, "Reveal must remain accessible above the keyboard")
        reveal.tap()
        XCTAssertTrue(app.buttons["grade-3"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["grade-3"].isHittable)
        let keyboardGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardGone], timeout: 5), .completed, "Keyboard should dismiss when the answer is revealed")
        app.buttons["grade-3"].tap()
    }
}

extension StudyUITests {
    func testOptionalTypedAnswerHistorySettingsSnapshotRestartAndUndo() {
        let app = app()
        create(app, question: "History question", answer: "Stored model answer")
        create(app, question: "Next history question", answer: "Next model answer")
        app.tabBars.buttons["設定"].tap()
        let setting = app.buttons["typedAnswerSettings"]
        scrollTo(setting, app: app); setting.tap()
        let toggle = app.switches["typedAnswerSaveToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        app.segmentedControls.buttons["文字入力"].tap()
        let input = app.descendants(matching: .any)["typedAnswer"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("Private answer")
        if app.buttons["完了"].exists { app.buttons["完了"].tap() }
        app.buttons["revealAnswer"].tap(); app.buttons["grade-3"].tap(); app.buttons["pauseStudy"].tap()
        app.tabBars.buttons["記録"].tap(); app.buttons["typedAnswerHistory"].tap()
        XCTAssertTrue(app.staticTexts["Private answer"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Stored model answer"].exists)
        attach(app, "Issue10-saved-typed-answer")
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["記録"].waitForExistence(timeout: 15)); app.tabBars.buttons["記録"].tap()
        app.buttons["typedAnswerHistory"].tap()
        XCTAssertTrue(app.staticTexts["Private answer"].waitForExistence(timeout: 10))
        app.tabBars.buttons["ホーム"].tap(); app.buttons["resumeStudy"].tap(); app.buttons["undoReview"].tap(); app.buttons["pauseStudy"].tap()
        app.tabBars.buttons["記録"].tap()
        if app.buttons["typedAnswerHistory"].exists { app.buttons["typedAnswerHistory"].tap() }
        XCTAssertTrue(app.descendants(matching: .any)["typedAnswerHistoryEmpty"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Private answer"].exists)
    }

    func testNoteCardCountsReversePreviewJapaneseStateSearchAndDelete() {
        let app = app()
        create(app, question: "Counts question", answer: "Counts answer")
        let total = app.staticTexts["libraryTotalCounts"]
        XCTAssertTrue(total.waitForExistence(timeout: 5))
        XCTAssertTrue(total.label.contains("1ノート / 1枚"))
        app.staticTexts["Counts question"].firstMatch.tap()
        app.buttons["editNote"].tap()
        let reverse = app.switches["裏表反転カードも作る"]
        scrollTo(reverse, app: app)
        reverse.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let preview = app.buttons["previewNote"]
        for _ in 0..<8 {
            if preview.exists && preview.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(preview.exists && preview.isHittable)
        XCTAssertEqual(app.staticTexts["generatedCardCount"].label, "このノートから2枚の学習カードを作成")
        preview.tap()
        XCTAssertEqual(app.staticTexts["previewCardCount"].label, "このノートから2枚の学習カードを作成")
        attach(app, "Issue38-generated-count-preview")
        app.buttons["closePreview"].tap()
        app.buttons["saveNote"].tap()
        let state = app.descendants(matching: .any)["noteState"]
        scrollTo(state, app: app)
        XCTAssertTrue(app.staticTexts["未学習"].exists || state.label.contains("未学習") || (state.value as? String ?? "").contains("未学習"))
        let suspension = app.switches["学習を一時停止"]
        scrollTo(suspension, app: app)
        suspension.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["noteAvailability"].label.contains("停止中"))
        attach(app, "Issue38-Japanese-state-and-suspension")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        scrollTo(total, app: app)
        XCTAssertTrue(total.label.contains("1ノート / 2枚"))
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("Counts question")
        XCTAssertTrue(app.staticTexts["libraryFilteredCounts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["libraryFilteredCounts"].label.contains("1ノート / 2枚"))
        if app.buttons["キャンセル"].exists { app.buttons["キャンセル"].tap() }
        app.staticTexts["Counts question"].firstMatch.tap()
        let delete = app.buttons["カードを削除"]
        scrollTo(delete, app: app)
        delete.tap()
        app.buttons["削除"].firstMatch.tap()
        scrollTo(total, app: app)
        XCTAssertTrue(total.label.contains("0ノート / 0枚"))
    }
}
