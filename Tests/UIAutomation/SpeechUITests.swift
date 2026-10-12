import XCTest

final class SpeechUITests: XCTestCase {
    func testEnglishManualPlaybackButtonsAreLimitedToVisibleFace() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString]
        app.launch()
        app.tabBars.buttons["ライブラリ"].tap()
        let add = app.buttons["addNote"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()

        let question = app.descendants(matching: .any)["questionInput"]
        for _ in 0..<10 { if question.exists && question.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        question.tap()
        question.typeText("Where are you going?")
        let answer = app.descendants(matching: .any)["answerInput"]
        for _ in 0..<5 { if answer.exists && answer.isHittable { break }; app.swipeUp() }
        answer.tap()
        answer.typeText("I am going home.")
        app.buttons["saveNote"].tap()

        app.tabBars.buttons["ホーム"].tap()
        let start = app.buttons["start-new"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()

        let playQuestion = app.buttons["speakQuestion"]
        XCTAssertTrue(playQuestion.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["speakAnswer"].exists)
        XCTAssertFalse(app.staticTexts["modelAnswer"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["speechOutputHelp"].exists)
        playQuestion.tap()
        if app.buttons["stopSpeech"].exists { app.buttons["stopSpeech"].tap() }

        let toggleAuto = app.buttons["toggleAutoSpeech"]
        XCTAssertTrue(toggleAuto.exists)
        toggleAuto.tap()
        XCTAssertTrue(app.buttons["revealAnswer"].exists)
        app.buttons["revealAnswer"].tap()
        XCTAssertTrue(app.staticTexts["modelAnswer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["speakAnswer"].exists)
        app.buttons["speakAnswer"].tap()
        if app.buttons["stopSpeech"].exists { app.buttons["stopSpeech"].tap() }
        app.buttons["pauseStudy"].tap()
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 5))
    }
}

extension SpeechUITests {
    func testLocalAudioSelectionPlaybackVisibleFacesAndRestart() {
        let app = XCUIApplication(), id = UUID().uuidString
        app.launchArguments = ["-study-test-store", id, "-study-test-file-fixtures"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["ライブラリ"].waitForExistence(timeout: 15))
        app.tabBars.buttons["ライブラリ"].tap(); app.buttons["addNote"].tap()
        let question = app.descendants(matching: .any)["questionInput"]
        XCTAssertTrue(question.waitForExistence(timeout: 5)); question.tap(); question.typeText("Audio question")
        let answer = app.descendants(matching: .any)["answerInput"]
        if !answer.isHittable { app.swipeUp() }
        answer.tap(); answer.typeText("Audio answer")
        if app.buttons["完了"].exists { app.buttons["完了"].tap() }
        for side in ["Question", "Answer"] {
            let select = app.buttons["select\(side)Audio"]
            for _ in 0..<10 {
                if select.exists && select.isHittable { break }
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.75)).press(forDuration: 0.01,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.3)))
            }
            XCTAssertTrue(select.isHittable); select.tap()
            let file = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "Audio-\(id)")).firstMatch
            if !file.waitForExistence(timeout: 3) {
                if app.buttons["ブラウズ"].firstMatch.exists { app.buttons["ブラウズ"].firstMatch.tap() }
                if app.buttons["このiPhone内"].exists { app.buttons["このiPhone内"].tap() }
                else if app.buttons["On My iPhone"].exists { app.buttons["On My iPhone"].tap() }
                let local = app.cells.matching(NSPredicate(format: "label IN %@", ["このiPhone内", "On My iPhone"])).firstMatch
                if local.exists { local.tap() }
                let folder = app.cells.containing(.staticText, identifier: "暗記ノート").firstMatch
                if folder.exists { folder.tap() }
            }
            // Reused simulator Documents can contain many earlier fixture files.
        // Search the unique fixture instead of depending on the first visible page.
        if !file.exists, app.searchFields["検索"].exists {
            let search = app.searchFields["検索"]
            search.tap()
            let value = search.value as? String ?? ""
            let existing = value == search.placeholderValue ? "" : value
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + name)
        }
        XCTAssertTrue(file.waitForExistence(timeout: 10), app.debugDescription); file.tap()
            XCTAssertTrue(app.buttons["preview\(side)Audio"].waitForExistence(timeout: 10))
        }
        app.buttons["saveNote"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 15))
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        XCTAssertTrue(app.buttons["speakQuestion"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["speakAnswer"].exists)
        app.buttons["speakQuestion"].tap()
        XCTAssertTrue(app.buttons["stopSpeech"].waitForExistence(timeout: 5))
        app.buttons["stopSpeech"].tap()
        app.buttons["chooseTTS"].tap()
        XCTAssertFalse(app.buttons["ttsAnswer"].exists)
        app.buttons["ttsQuestion"].tap()
        if app.buttons["stopSpeech"].exists { app.buttons["stopSpeech"].tap() }
        app.buttons["revealAnswer"].tap()
        XCTAssertTrue(app.buttons["speakAnswer"].waitForExistence(timeout: 5))
        app.buttons["speakAnswer"].tap()
        XCTAssertTrue(app.buttons["stopSpeech"].waitForExistence(timeout: 5))
        app.buttons["pauseStudy"].tap()
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 5))
    }
}

extension SpeechUITests {
    private func exchangeScroll(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.8)).press(forDuration: 0.01,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.25)))
        }
        XCTAssertTrue(element.exists && element.isHittable, app.debugDescription)
    }
    private func exchangeSelect(_ name: String, app: XCUIApplication, identifier: String = "selectDeckFile") {
        exchangeScroll(app.buttons[identifier], app: app); app.buttons[identifier].tap()
        let file = app.cells.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        if !file.waitForExistence(timeout: 3) {
            if app.buttons["ブラウズ"].firstMatch.exists { app.buttons["ブラウズ"].firstMatch.tap() }
            if app.buttons["このiPhone内"].exists { app.buttons["このiPhone内"].tap() }
            else if app.buttons["On My iPhone"].exists { app.buttons["On My iPhone"].tap() }
            let local = app.cells.matching(NSPredicate(format: "label IN %@", ["このiPhone内", "On My iPhone"])).firstMatch
            if local.exists { local.tap() }
            let folder = app.cells.containing(.staticText, identifier: "暗記ノート").firstMatch
            if folder.exists { folder.tap() }
        }
        // Reused simulator Documents can contain many earlier fixture files.
        // Search the unique fixture instead of depending on the first visible page.
        if !file.exists, app.searchFields["検索"].exists {
            let search = app.searchFields["検索"]
            search.tap()
            let value = search.value as? String ?? ""
            let existing = value == search.placeholderValue ? "" : value
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + name)
        }
        XCTAssertTrue(file.waitForExistence(timeout: 10), app.debugDescription); file.tap()
    }
    func testDeckFilePreviewCancellationImportExportAndOfflineStudy() {
        let app = XCUIApplication(), id = UUID().uuidString
        app.launchArguments = ["-study-test-store", id, "-study-test-file-fixtures"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["ライブラリ"].waitForExistence(timeout: 15))
        app.tabBars.buttons["ライブラリ"].tap(); app.buttons["デッキ管理"].tap()
        app.buttons["openDeckExchange"].tap()
        exchangeSelect("Deck-\(id)", app: app)
        exchangeScroll(app.buttons["confirmDeckImport"], app: app)
        exchangeScroll(app.buttons["cancelDeckPreview"], app: app); app.buttons["cancelDeckPreview"].tap()
        XCTAssertFalse(app.buttons["confirmDeckImport"].exists)
        for _ in 0..<5 { if app.buttons["selectDeckFile"].isHittable { break }; app.swipeDown() }
        exchangeSelect("Deck-\(id)", app: app)
        exchangeScroll(app.buttons["confirmDeckImport"], app: app)
        exchangeScroll(app.buttons["confirmDeckImport"], app: app); app.buttons["confirmDeckImport"].tap()
        app.buttons["commitDeckImport"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["deckExchangeResult"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["deckExchangeResult"].label.contains("1ノート"))
        XCTAssertTrue(app.staticTexts["deckExchangeResult"].label.contains("新規カード 2枚"))
        app.buttons["viewImportedDeck"].tap()
        XCTAssertTrue(app.staticTexts["shortcutDeckPath"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["continueDeckImport"].tap()
        exchangeSelect("Deck-\(id)", app: app)
        exchangeScroll(app.buttons["confirmDeckImport"], app: app); app.buttons["confirmDeckImport"].tap()
        app.buttons["commitDeckImport"].firstMatch.tap()
        XCTAssertTrue(app.buttons["retryDeckImport"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["deckExchangeResult"].label.contains("追加 0ノート"))
        app.buttons["retryDeckImport"].tap()
        XCTAssertTrue(app.buttons["confirmDeckImport"].waitForExistence(timeout: 10))
        exchangeScroll(app.buttons["cancelDeckPreview"], app: app); app.buttons["cancelDeckPreview"].tap()
        for _ in 0..<5 { if app.buttons["exchangeDeckPicker"].isHittable { break }; app.swipeDown() }
        app.buttons["exchangeDeckPicker"].tap(); app.buttons["共有サンプル"].tap()
        app.buttons["previewDeckExport"].tap()
        exchangeScroll(app.buttons["exportDeckFile"], app: app)
        exchangeScroll(app.buttons["exportDeckFile"], app: app); app.buttons["exportDeckFile"].tap()
        XCTAssertTrue(app.buttons["保存"].waitForExistence(timeout: 10))
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["deckExchangeResult"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["shareExportedDeck"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Filesへの保存が完了しました。相手への共有はまだ行っていません。"].exists)
        app.buttons["closeDeckCompletion"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 15))
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        XCTAssertTrue(app.buttons["speakQuestion"].waitForExistence(timeout: 10))
        app.buttons["speakQuestion"].tap(); XCTAssertTrue(app.buttons["stopSpeech"].waitForExistence(timeout: 5))
        app.buttons["stopSpeech"].tap(); app.buttons["revealAnswer"].tap()
        XCTAssertTrue(app.buttons["speakAnswer"].waitForExistence(timeout: 5))
        app.buttons["pauseStudy"].tap()
    }
}

extension SpeechUITests {
    func testAnkiFileReportsUnsupportedNotesAndImportsAsNewLearning() {
        let app = XCUIApplication(), id = UUID().uuidString
        app.launchArguments = ["-study-test-store", id, "-study-test-file-fixtures"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["ライブラリ"].waitForExistence(timeout: 15))
        app.tabBars.buttons["ライブラリ"].tap(); app.buttons["デッキ管理"].tap(); app.buttons["openDeckExchange"].tap()
        exchangeSelect("Anki-\(id)", app: app, identifier: "selectAnkiPackage")
        exchangeScroll(app.staticTexts["ankiHistoryPolicy"], app: app)
        XCTAssertTrue(app.staticTexts["ankiHistoryPolicy"].label.contains("新規学習"))
        XCTAssertTrue(app.staticTexts["ankiHistoryPolicy"].label.contains("回答履歴1件"))
        let unsupported = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "スクリプト")).firstMatch
        XCTAssertTrue(unsupported.exists)
        exchangeScroll(app.buttons["cancelDeckPreview"], app: app); app.buttons["cancelDeckPreview"].tap()
        XCTAssertFalse(app.buttons["confirmDeckImport"].exists)
        for _ in 0..<6 { if app.buttons["selectAnkiPackage"].isHittable { break }; app.swipeDown() }
        exchangeSelect("Anki-\(id)", app: app, identifier: "selectAnkiPackage")
        exchangeScroll(app.buttons["confirmDeckImport"], app: app); app.buttons["confirmDeckImport"].tap()
        app.buttons["commitDeckImport"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["deckExchangeResult"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["deckExchangeResult"].label.contains("4ノート"))
        XCTAssertEqual(app.staticTexts["importCompletionTitle"].label, "一部のノートを取り込みました")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "未対応ノートの理由")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "スクリプト")).firstMatch.exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 15))
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 10))
        app.buttons["revealAnswer"].tap()
        XCTAssertTrue(app.buttons["grade-3"].waitForExistence(timeout: 5))
        app.buttons["grade-3"].tap()
        XCTAssertTrue(app.buttons["undoReview"].waitForExistence(timeout: 5))
        app.buttons["undoReview"].tap(); app.buttons["pauseStudy"].tap()
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 5))
    }
}
