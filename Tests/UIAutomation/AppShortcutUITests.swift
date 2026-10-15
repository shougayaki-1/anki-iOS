import XCTest

final class AppShortcutUITests: XCTestCase {
    func launch(_ arguments: [String], storeID: String = UUID().uuidString) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", storeID] + arguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        return app
    }

    func testEmptyShortcutDeckAddsIntoSelectedDeck() {
        let app = launch(["-study-test-shortcut", "deck:first"])
        let path = app.staticTexts["shortcutDeckPath"]
        XCTAssertTrue(path.waitForExistence(timeout: 10))
        let name = path.label
        let add = app.buttons["emptyDeckAdd"]
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap()
        let picker = app.buttons["noteDeckPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); XCTAssertTrue(picker.label.contains(name))
        app.buttons["closeEditor"].tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        app.buttons["ライブラリに戻る"].tap()
        XCTAssertTrue(app.buttons["emptyLibraryAdd"].waitForExistence(timeout: 5))
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

        app.terminate()
        let missing = launch(["-study-test-shortcut", "deck:\(UUID().uuidString)"])
        XCTAssertTrue(missing.tabBars.buttons["ライブラリ"].isSelected)
        XCTAssertTrue(missing.alerts["ショートカット"].waitForExistence(timeout: 10))
        XCTAssertFalse(missing.staticTexts["shortcutDeckPath"].exists)
    }
}


final class DailyWidgetUITests: XCTestCase {
    private let cardURL = URL(string: "ankistudy://widget/card/23000000-0000-0000-0000-000000000001")!
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testDailyCardDeepLinkRevealHideAndFormalReview() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-daily-widget"]
        app.launch()
        app.open(cardURL)
        let confirm = app.alerts.buttons["開く"]
        if confirm.waitForExistence(timeout: 2) { confirm.tap() }
        let reveal = app.buttons["答えを見る"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["思い出す"].exists)
        shot("daily-question")
        reveal.tap()
        XCTAssertTrue(app.staticTexts["思い出す"].waitForExistence(timeout: 5))
        shot("daily-answer")
        app.buttons["答えを隠す"].tap()
        XCTAssertFalse(app.staticTexts["思い出す"].exists)
        app.buttons["このカードを正式に復習"].tap()
        XCTAssertTrue(app.staticTexts["reviewQuestion"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["reviewQuestion"].label, "What does recall mean?")
        shot("daily-formal-review")
        app.buttons["pauseStudy"].tap()
        app.open(URL(string: cardURL.absoluteString + "/answer")!)
        XCTAssertTrue(app.staticTexts["思い出す"].waitForExistence(timeout: 10))
        app.buttons["閉じる"].tap()
        app.open(URL(string: "ankistudy://widget/card/23000000-0000-0000-0000-000000000099")!)
        XCTAssertTrue(app.staticTexts["このカードは今の学習対象ではありません。ホームで最新のカードを確認してください。"].waitForExistence(timeout: 10))
        shot("daily-unavailable")
    }
    func testWidgetGalleryAndHomeDisplay() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-daily-widget"]
        app.launch()
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if !springboard.staticTexts["今日の1枚"].exists {
            springboard.icons["暗記ノート"].press(forDuration: 1.5)
            let editHome = springboard.buttons["ホーム画面を編集"]
            XCTAssertTrue(editHome.waitForExistence(timeout: 5)); editHome.tap()
            let edit = springboard.buttons["編集"]
            XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
            springboard.buttons["ウィジェットを追加"].tap()
            let search = springboard.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("暗記ノート")
            let appCell = springboard.cells["暗記ノート"]
            XCTAssertTrue(appCell.waitForExistence(timeout: 10)); appCell.tap()
            XCTAssertTrue(springboard.staticTexts["復習と今日の進捗"].waitForExistence(timeout: 10))
            shot("progress-widget-small")
            springboard.swipeLeft()
            shot("progress-widget-medium")
            springboard.swipeLeft()
            XCTAssertTrue(springboard.staticTexts["今日の1枚"].waitForExistence(timeout: 10))
            shot("daily-widget-small")
            springboard.swipeLeft()
            shot("daily-widget-medium")
            springboard.buttons[" ウィジェットを追加"].tap()
            let done = springboard.buttons["完了"]
            if done.waitForExistence(timeout: 5) { done.tap() }
        }
        let answer = springboard.buttons["アプリで答えを見る"]
        XCTAssertTrue(answer.waitForExistence(timeout: 20))
        shot("daily-widget-home")
        answer.tap()
        XCTAssertTrue(app.staticTexts["思い出す"].waitForExistence(timeout: 10))
        shot("daily-widget-answer-link")
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-widget-empty"]
        app.launch()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(springboard.staticTexts["今の学習はひと区切り"].waitForExistence(timeout: 20))
        shot("daily-widget-empty")
    }
}
