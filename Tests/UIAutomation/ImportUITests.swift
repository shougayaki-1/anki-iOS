import XCTest

final class ImportUITests: XCTestCase {
    func testCSVHintHeaderPreviewEditingAndLearning() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["ライブラリ"].waitForExistence(timeout: 15))
        app.tabBars.buttons["ライブラリ"].tap(); app.buttons["openImport"].tap()
        let text = app.textViews["importText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap()
        text.typeText("question,answer,ヒント\nCSV hint question,CSV answer,Initial clue")
        app.buttons["完了"].tap()
        app.descendants(matching: .any)["importFormat"].tap(); app.buttons["CSV（カンマ）"].tap()
        let preview = app.buttons["previewImport"]
        for _ in 0..<8 where !preview.isHittable { app.swipeUp() }
        preview.tap()
        let hint = app.descendants(matching: .any)["importHint-2"]
        for _ in 0..<8 where !hint.exists || !hint.isHittable { app.swipeUp() }
        XCTAssertEqual(hint.value as? String, "Initial clue")
        hint.tap(); hint.typeText(" edited")
        let editedHint = hint.value as? String ?? ""
        XCTAssertTrue(editedHint.contains("edited"))
        app.buttons["完了"].tap()
        app.buttons["confirmImport"].tap(); app.buttons["commitImport"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["importResult"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["importResult"].label.contains("成功 1件"))
        app.buttons["closeImport"].tap()
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        XCTAssertTrue(app.buttons["toggleHint"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["studyHint"].exists)
        app.buttons["toggleHint"].tap()
        XCTAssertEqual(app.staticTexts["studyHint"].label, editedHint)
        XCTAssertFalse(app.staticTexts["modelAnswer"].exists)
    }
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
    func testLargeCSVCanConfirmWithoutScrollingThroughRows() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString]
        app.launch()
        let library = app.tabBars.buttons["ライブラリ"]
        XCTAssertTrue(library.waitForExistence(timeout: 15)); library.tap()
        app.buttons["openImport"].tap()
        let text = app.textViews["importText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap()
        let csv = "Question,Answer\n" + (1...41).map { "Q\($0),A\($0)" }.joined(separator: "\n")
        text.typeText(csv)
        app.buttons["完了"].tap()
        let format = app.descendants(matching: .any)["importFormat"]
        for _ in 0..<4 where !format.isHittable { app.swipeUp() }
        XCTAssertTrue(format.exists); format.tap()
        app.buttons["CSV（カンマ）"].tap()
        let preview = app.buttons["previewImport"]
        for _ in 0..<4 where !preview.isHittable { app.swipeUp() }
        XCTAssertTrue(preview.isHittable); preview.tap()
        let confirm = app.buttons["confirmImport"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.isHittable, "大量の行をスクロールしなくても確定できる")
        XCTAssertGreaterThanOrEqual(confirm.frame.height, 48)
        let previewImage = XCTAttachment(screenshot: app.screenshot())
        previewImage.name = "Large-CSV-pinned-confirm"; previewImage.lifetime = .keepAlways; add(previewImage)
        let summary = app.staticTexts["importPageSummary"]
        for _ in 0..<4 where !summary.isHittable { app.swipeUp() }
        XCTAssertTrue(summary.label.contains("1〜20 / 41行"))
        app.buttons["nextImportPage"].tap()
        XCTAssertTrue(summary.label.contains("21〜40 / 41行"))
        app.buttons["nextImportPage"].tap()
        XCTAssertTrue(summary.label.contains("41〜41 / 41行"))
        app.buttons["previousImportPage"].tap()
        XCTAssertTrue(summary.label.contains("21〜40 / 41行"))
        XCTAssertTrue(confirm.isHittable); confirm.tap()
        app.buttons["確定して保存"].firstMatch.tap()
        let result = app.staticTexts["importResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        XCTAssertTrue(result.label.contains("成功 41件 / スキップ 0件 / エラー 0件"))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Large-CSV-import-result"; image.lifetime = .keepAlways; add(image)
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
        app.buttons["openStudyFilter"].tap()
        app.buttons["studyDeckPicker"].tap(); app.buttons["Science"].firstMatch.tap()
        app.buttons["applyStudyFilter"].tap()
        app.buttons["start-new"].tap()
        XCTAssertTrue(app.staticTexts["reviewQuestion"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reviewQuestion"].label, "Cell question")
        app.buttons["pauseStudy"].tap()
    }

}
