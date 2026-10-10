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
