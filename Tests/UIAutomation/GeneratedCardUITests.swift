import XCTest

final class GeneratedCardUITests: XCTestCase {
    func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["ライブラリ"].waitForExistence(timeout: 15))
        app.tabBars.buttons["ライブラリ"].tap()
        return app
    }
    func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name
        shot.lifetime = .keepAlways; add(shot)
    }
    func scroll(_ app: XCUIApplication, up: Bool) {
        // Scroll beside the image canvas; dragging the canvas intentionally draws a mask.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: up ? 0.75 : 0.3))
            .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: up ? 0.3 : 0.75)))
    }
    func selectTestPhoto(_ app: XCUIApplication) -> Bool {
        let photos = app.images.matching(identifier: "PXGGridLayout-Info")
        guard photos.firstMatch.waitForExistence(timeout: 15) else { return false }
        let testImage = photos.matching(NSPredicate(
            format: "label CONTAINS[cd] %@ OR label CONTAINS[cd] %@ OR label CONTAINS[cd] %@ OR label CONTAINS[cd] %@ OR label CONTAINS[cd] %@ OR label CONTAINS[cd] %@ OR label CONTAINS[cd] %@ OR label CONTAINS[cd] %@",
            "uitest", "test image", "test-image", "test_photo", "fixture", "sample image", "テスト画像", "サンプル画像"
        )).firstMatch
        guard testImage.waitForExistence(timeout: 3) else { return false }
        testImage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
    }
    func testClozePreviewDraftRestartLearnUndoAndEdit() {
        let app = launch()
        app.buttons["addNote"].tap()
        app.buttons["noteKindPicker"].tap(); app.buttons["穴埋め"].firstMatch.tap()
        let q = app.descendants(matching: .any)["questionInput"]
        for _ in 0..<4 where !q.isHittable { scroll(app, up: true) }
        q.tap(); q.typeText("Capital is {{c1::Tokyo}} and country is {{c2::Japan}}.")
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["ライブラリ"].waitForExistence(timeout: 15))
        app.tabBars.buttons["ライブラリ"].tap(); app.buttons["addNote"].tap()
        XCTAssertTrue(q.waitForExistence(timeout: 5))
        XCTAssertTrue((q.value as? String ?? "").contains("{{c1::Tokyo}}"))
        scroll(app, up: false); app.buttons["previewNote"].tap()
        XCTAssertTrue(app.staticTexts["previewQuestion"].waitForExistence(timeout: 5))
        app.buttons["previewReveal"].tap()
        XCTAssertEqual(app.staticTexts["previewAnswer"].label, "Tokyo")
        attach(app, "Phase3-cloze-preview")
        app.buttons["closePreview"].tap(); app.buttons["saveNote"].tap()
        XCTAssertTrue(app.buttons["addNote"].waitForExistence(timeout: 5))
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        XCTAssertTrue(app.staticTexts["reviewQuestion"].waitForExistence(timeout: 5))
        app.buttons["revealAnswer"].tap()
        XCTAssertTrue(["Tokyo", "Japan"].contains(app.staticTexts["modelAnswer"].label))
        app.buttons["grade-4"].tap(); app.buttons["undoReview"].tap()
        app.buttons["revealAnswer"].tap(); app.buttons["grade-4"].tap(); app.buttons["pauseStudy"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["resumeStudy"].waitForExistence(timeout: 15))
        app.tabBars.buttons["記録"].tap()
        XCTAssertTrue(app.staticTexts["todayAnswerCount"].label.contains("1回"))
        app.tabBars.buttons["ライブラリ"].tap()
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Capital is")).firstMatch.tap()
        app.buttons["editNote"].tap()
        for _ in 0..<5 where !q.isHittable { scroll(app, up: true) }
        q.tap(); q.typeText(" Updated")
        app.buttons["saveNote"].tap(); app.buttons["復習予定を維持して保存"].tap()
        XCTAssertTrue(app.buttons["editNote"].waitForExistence(timeout: 5))
    }
    func testPhotoMaskCreatePreviewLearnAndRestart() throws {
        let app = launch()
        app.buttons["addNote"].tap()
        app.buttons["noteKindPicker"].tap(); app.buttons["画像マスク"].firstMatch.tap()
        app.buttons["pickPhoto"].tap()
        guard selectTestPhoto(app) else { throw XCTSkip("写真ライブラリにテスト用画像がないため、写真を選ばず終了しました。") }
        let mask = app.buttons["addCenterMask"]
        for _ in 0..<5 where !mask.isHittable { scroll(app, up: true) }
        XCTAssertTrue(mask.waitForExistence(timeout: 15)); mask.tap()
        attach(app, "Phase3-mask-editor")
        let crop = app.buttons["トリミング"]
        for _ in 0..<5 where !crop.isHittable { scroll(app, up: true) }
        crop.tap()
        XCTAssertTrue(app.buttons["適用"].waitForExistence(timeout: 5))
        // A full-image crop has fixed x/y bounds; it must not construct an empty stepped Slider range.
        app.buttons["適用"].tap()
        let preview = app.buttons["previewNote"]
        for _ in 0..<6 where !preview.isHittable { scroll(app, up: false) }
        preview.tap()
        XCTAssertTrue(app.staticTexts["previewQuestion"].waitForExistence(timeout: 5))
        app.buttons["previewReveal"].tap(); app.buttons["closePreview"].tap()
        app.buttons["saveNote"].tap()
        XCTAssertTrue(app.buttons["addNote"].waitForExistence(timeout: 5))
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        XCTAssertTrue(app.images["対象のマスクを隠した画像"].waitForExistence(timeout: 5))
        for _ in 0..<4 where !app.buttons["revealAnswer"].isHittable { scroll(app, up: true) }
        app.buttons["revealAnswer"].tap()
        attach(app, "Phase3-mask-revealed")
        for _ in 0..<4 where !app.buttons["grade-4"].isHittable { scroll(app, up: true) }
        app.buttons["grade-4"].tap(); app.buttons["pauseStudy"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["resumeStudy"].waitForExistence(timeout: 15))
        app.tabBars.buttons["ライブラリ"].tap()
        app.staticTexts["画像の隠した部分を答えてください"].tap()
        XCTAssertTrue(app.images["対象のマスクを開いた画像"].waitForExistence(timeout: 5))
        for _ in 0..<6 where !app.descendants(matching: .any)["noteDue"].exists { scroll(app, up: true) }
        XCTAssertTrue(app.descendants(matching: .any)["noteDue"].exists)
        let due = app.descendants(matching: .any)["noteDue"].label
        app.buttons["editNote"].tap()
        for _ in 0..<6 where !mask.isHittable { scroll(app, up: true) }
        mask.tap(); app.buttons["saveNote"].tap()
        app.buttons["復習予定を維持して保存"].tap()
        XCTAssertTrue(app.buttons["editNote"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)["noteDue"].label, due)
    }
    func testPhotoOCRCorrectionPreviewImportAndLearn() throws {
        let app = launch()
        app.buttons["openOCR"].tap(); app.buttons["pickPhoto"].tap()
        guard selectTestPhoto(app) else { throw XCTSkip("写真ライブラリにテスト用画像がないため、写真を選ばず終了しました。") }
        let text = app.textViews["ocrText"]
        XCTAssertTrue(text.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["ocrLanguages"].waitForExistence(timeout: 20))
        attach(app, "Phase3-OCR-recognized")
        if app.buttons["clearOCRText"].isEnabled { app.buttons["clearOCRText"].tap() }
        text.tap()
        text.typeText("Q: OCR capital\nA: Tokyo corrected")
        app.buttons["完了"].tap()
        app.buttons["ocrPreview"].tap()
        app.buttons["previewImport"].tap()
        let confirm = app.buttons["confirmImport"]
        for _ in 0..<8 where !confirm.isHittable { scroll(app, up: true) }
        confirm.tap(); app.buttons["確定して保存"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["importResult"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["importResult"].label.contains("成功 1件"))
        app.buttons["closeImport"].tap(); app.buttons["closeOCR"].tap()
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        XCTAssertTrue(app.staticTexts["reviewQuestion"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reviewQuestion"].label, "OCR capital")
        app.buttons["revealAnswer"].tap()
        XCTAssertEqual(app.staticTexts["modelAnswer"].label, "Tokyo corrected")
        app.buttons["grade-4"].tap(); app.buttons["pauseStudy"].tap()
    }
}
