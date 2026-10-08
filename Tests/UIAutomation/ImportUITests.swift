import XCTest

final class ImportUITests: XCTestCase {
    func testPastePreviewConfirmDuplicatesAndErrorsThenLearn() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString]
        app.launch()
        let library = app.tabBars.buttons["ライブラリ"]
        XCTAssertTrue(library.waitForExistence(timeout: 15)); library.tap()
        app.buttons["openImport"].tap()
        let text = app.textViews["importText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap()
        text.typeText("Q: Import first\nA: First answer\nQ: Import first\nA: First answer\nQ: Import second\nA: Second answer\nQ: Incomplete")
        app.buttons["完了"].tap()
        app.buttons["previewImport"].tap()
        let confirm = app.buttons["confirmImport"]
        for _ in 0..<8 where !confirm.isHittable { app.swipeUp() }
        XCTAssertTrue(confirm.exists); confirm.tap()
        app.buttons["確定して保存"].firstMatch.tap()
        let result = app.staticTexts["importResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.contains("成功 2件 / スキップ 1件 / エラー 1件"))
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Phase2-import-results"
        image.lifetime = .keepAlways; add(image)
        app.buttons["閉じる"].tap()
        XCTAssertTrue(app.staticTexts["Import first"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Import second"].exists)
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        XCTAssertTrue(app.staticTexts["reviewQuestion"].waitForExistence(timeout: 5))
        app.buttons["revealAnswer"].tap(); app.buttons["grade-3"].tap()
        XCTAssertTrue(app.staticTexts["reviewQuestion"].waitForExistence(timeout: 5))
        app.buttons["pauseStudy"].tap()
    }
    func testHierarchyCreationAndParentScopeStudy() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString]
        app.launch()
        let library = app.tabBars.buttons["ライブラリ"]
        XCTAssertTrue(library.waitForExistence(timeout: 15)); library.tap()
        app.buttons["デッキ管理"].tap()
        app.buttons["デッキ追加"].tap()
        let name = app.textFields["deckNameInput"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Science")
        app.buttons["保存"].tap()
        app.buttons["デッキ追加"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Biology")
        app.buttons["deckParentPicker"].tap(); app.buttons["Science"].firstMatch.tap()
        app.buttons["保存"].tap()
        XCTAssertTrue(app.buttons["Science / Biology"].waitForExistence(timeout: 5))
        app.buttons["閉じる"].tap()
        app.buttons["addNote"].tap()
        app.buttons["noteDeckPicker"].tap(); app.buttons["Science / Biology"].firstMatch.tap()
        let q = app.descendants(matching: .any)["questionInput"]
        q.tap(); q.typeText("Cell question")
        let a = app.descendants(matching: .any)["answerInput"]
        a.tap(); a.typeText("Cell answer")
        app.buttons["saveNote"].tap()
        app.tabBars.buttons["ホーム"].tap()
        app.buttons["studyDeckPicker"].tap(); app.buttons["Science"].firstMatch.tap()
        app.buttons["start-new"].tap()
        XCTAssertTrue(app.staticTexts["reviewQuestion"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reviewQuestion"].label, "Cell question")
        app.buttons["pauseStudy"].tap()
    }

}
