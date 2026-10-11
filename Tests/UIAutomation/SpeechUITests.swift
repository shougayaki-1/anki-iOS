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
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        question.tap()
        question.typeText("Where are you going?")
        let answer = app.descendants(matching: .any)["answerInput"]
        if !answer.isHittable { app.swipeUp() }
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
    private func exchangeSelect(_ name: String, app: XCUIApplication) {
        app.buttons["selectDeckFile"].tap()
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
        for _ in 0..<5 { if app.buttons["exchangeDeckPicker"].isHittable { break }; app.swipeDown() }
        app.buttons["exchangeDeckPicker"].tap(); app.buttons["共有サンプル"].tap()
        app.buttons["previewDeckExport"].tap()
        exchangeScroll(app.buttons["exportDeckFile"], app: app)
        exchangeScroll(app.buttons["exportDeckFile"], app: app); app.buttons["exportDeckFile"].tap()
        XCTAssertTrue(app.buttons["保存"].waitForExistence(timeout: 10))
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["deckExchangeResult"].waitForExistence(timeout: 10))
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
