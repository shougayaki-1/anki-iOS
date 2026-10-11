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
        // Set only for an explicitly authorized device acceptance run.
        if ProcessInfo.processInfo.environment["ANKI_UI_ALLOW_ANY_PHOTO"] == "1" {
            photos.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return true
        }
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
        let preview = app.buttons["previewNote"]
        for _ in 0..<15 where !preview.exists || !preview.isHittable { scroll(app, up: true) }
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.isHittable)
        preview.tap()
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
        XCTAssertTrue(app.buttons["completeStudy"].waitForExistence(timeout: 15))
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
    func testMaskDirectPercentageValidationAndPersistence() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-numeric-mask"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["ライブラリ"].waitForExistence(timeout: 15))
        app.tabBars.buttons["ライブラリ"].tap()
        app.staticTexts["Numeric mask fixture"].tap()
        XCTAssertTrue(app.buttons["editNote"].waitForExistence(timeout: 5))
        app.buttons["editNote"].tap()
        func openCoordinates() {
            let disclosure = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "マスク1を選択")).firstMatch
            for _ in 0..<25 where !disclosure.isHittable {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.7))
                    .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)))
            }
            XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
            // Expand using the standard disclosure chevron, beside the selection button.
            let cell = app.cells.containing(.button, identifier: "マスク1を選択").firstMatch
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        func field(_ prefix: String) -> XCUIElement {
            app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        }
        func edit(_ prefix: String, text: String) {
            let input = field(prefix)
            for _ in 0..<20 {
                if input.exists && input.isHittable && input.frame.minY > app.navigationBars.firstMatch.frame.maxY { break }
                let up = prefix != "maskX-"
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: up ? 0.7 : 0.4))
                    .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: up ? 0.5 : 0.6)))
            }
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.tap()
            app.buttons[input.identifier + "Clear"].tap()
            input.typeText(text)
            app.buttons[input.identifier + "Done"].tap()
        }
        openCoordinates()
        edit("maskWidth-", text: "20")
        XCTAssertEqual(field("maskWidth-").value as? String, "20%")
        attach(app, "Issue42-mask-width-confirmed")
        edit("maskX-", text: "80")
        XCTAssertEqual(field("maskX-").value as? String, "80%")
        edit("maskX-", text: "90")
        XCTAssertTrue(app.staticTexts[field("maskX-").identifier + "Error"].exists)
        app.buttons[field("maskX-").identifier + "Cancel"].tap()
        XCTAssertEqual(field("maskX-").value as? String, "80%")
        app.buttons["saveNote"].tap()
        XCTAssertTrue(app.buttons["editNote"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["ライブラリ"].waitForExistence(timeout: 15))
        app.tabBars.buttons["ライブラリ"].tap(); app.staticTexts["Numeric mask fixture"].tap()
        app.buttons["editNote"].tap(); openCoordinates()
        XCTAssertEqual(field("maskX-").value as? String, "80%")
        for _ in 0..<15 where !field("maskWidth-").isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.7))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)))
        }
        XCTAssertEqual(field("maskWidth-").value as? String, "20%")
        attach(app, "Issue42-mask-input")
    }

    func testPhotoMaskCreatePreviewLearnAndRestart() throws {
        let app = launch()
        app.buttons["addNote"].tap()
        app.buttons["noteKindPicker"].tap(); app.buttons["画像マスク"].firstMatch.tap()
        for _ in 0..<8 where !app.buttons["pickPhoto"].isHittable { scroll(app, up: true) }
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
        // The single mask has already been graded Easy: its saved session is
        // complete, rather than resumable with another available card.
        XCTAssertTrue(app.buttons["completeStudy"].waitForExistence(timeout: 15))
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
        finishOCR(app, text: text)
    }
    func testAuthorizedCameraJapaneseOCRCorrectionAndLearn() throws {
        guard ProcessInfo.processInfo.environment["ANKI_UI_ALLOW_CAMERA"] == "1" else {
            throw XCTSkip("実機カメラ撮影の準備が指定されていません。")
        }
        addUIInterruptionMonitor(withDescription: "Camera permission") { alert in
            for title in ["許可", "Allow", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap(); return true
            }
            return false
        }
        let app = launch()
        app.buttons["openOCR"].tap(); app.buttons["撮影"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        let shutter = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@ OR label == %@", "PhotoCapture", "写真を撮影", "Take Picture")).firstMatch
        XCTAssertTrue(shutter.waitForExistence(timeout: 15))
        shutter.tap()
        let use = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "写真を使用", "Use Photo")).firstMatch
        XCTAssertTrue(use.waitForExistence(timeout: 10)); use.tap()
        let text = app.textViews["ocrText"]
        XCTAssertTrue(text.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["ocrLanguages"].waitForExistence(timeout: 30))
        let recognized = text.value as? String ?? ""
        XCTAssertNotNil(recognized.range(of: "[ぁ-ヿ一-鿿]", options: .regularExpression), "日本語の認識結果が必要です。")
        finishOCR(app, text: text)
    }
    private func finishOCR(_ app: XCUIApplication, text: XCUIElement) {
        let clear = app.buttons["clearOCRText"]
        for _ in 0..<6 where !clear.exists { scroll(app, up: true) }
        XCTAssertTrue(clear.exists)
        if clear.isEnabled { clear.tap() }
        for _ in 0..<8 where text.frame.minY < 100 { scroll(app, up: false) }
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        text.typeText("Q: OCR capital\nA: Tokyo corrected")
        app.buttons["完了"].tap()
        let preview = app.buttons["ocrPreview"]
        for _ in 0..<6 where !preview.isHittable { scroll(app, up: true) }
        preview.tap()
        app.buttons["previewImport"].tap()
        let confirm = app.buttons["confirmImport"]
        for _ in 0..<8 where !confirm.isHittable { scroll(app, up: true) }
        confirm.tap(); app.buttons["確定して保存"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["importResult"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["importResult"].label.contains("新規 1ノート"))
        app.buttons["closeImport"].tap(); app.buttons["closeOCR"].tap()
        app.tabBars.buttons["ホーム"].tap(); app.buttons["start-new"].tap()
        XCTAssertTrue(app.staticTexts["reviewQuestion"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reviewQuestion"].label, "OCR capital")
        app.buttons["revealAnswer"].tap()
        XCTAssertEqual(app.staticTexts["modelAnswer"].label, "Tokyo corrected")
        app.buttons["grade-4"].tap(); app.buttons["pauseStudy"].tap()
    }
}
