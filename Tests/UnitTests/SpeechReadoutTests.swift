import XCTest
@testable import AnkiIOS

final class SpeechReadoutTests: XCTestCase {
    func testOldNotesAndOptionsDefaultToSilence() throws {
        let note = try JSONDecoder().decode(TextContent.self, from: Data(#"{"question":"Hello!","answer":"Hi.","explanation":""}"#.utf8))
        XCTAssertNil(note.speechAutoplayOverride)
        XCTAssertNil(note.speechQuestion)
        XCTAssertNil(note.speechAnswer)
        let options = try JSONDecoder().decode(StudyOptions.self, from: Data(#"{"schemaVersion":2,"siblingBuryEnabled":true}"#.utf8))
        XCTAssertNil(options.speech)
        XCTAssertEqual(SpeechPreferences().autoplay(deckID: UUID(), noteOverride: nil), .off)
    }

    func testDeckDefaultsAndNoteOverrides() {
        let id = UUID()
        var settings = SpeechPreferences()
        settings.deckAutoplay[id.uuidString] = .both
        XCTAssertEqual(settings.autoplay(deckID: id, noteOverride: nil), .both)
        XCTAssertEqual(settings.autoplay(deckID: id, noteOverride: .off), .off)
        XCTAssertEqual(settings.autoplay(deckID: UUID(), noteOverride: .answer), .answer)
        XCTAssertTrue(SpeechAutoplay.answer.includes(.answer))
        XCTAssertFalse(SpeechAutoplay.answer.includes(.question))
    }

    func testQuestionAndAnswerRemainSeparateAndMixedJapaneseIsNotSpoken() {
        let content = TextContent(question: "What is a cat?", answer: "A small animal.", explanation: "日本語の解説")
        XCTAssertEqual(SpeechReadout.text(kind: .basic, displayed: content, side: .question), "What is a cat?")
        XCTAssertEqual(SpeechReadout.text(kind: .basic, displayed: content, side: .answer), "A small animal.")
        var mixed = content
        mixed.question = "「cat」とは何ですか？"
        XCTAssertNil(SpeechReadout.text(kind: .basic, displayed: mixed, side: .question))
        mixed.speechQuestion = "What does cat mean?"
        XCTAssertEqual(SpeechReadout.text(kind: .basic, displayed: mixed, side: .question), "What does cat mean?")
        XCTAssertNil(SpeechReadout.text(kind: .written, displayed: TextContent(question: "Hello", answer: "{{c1::secret}}", explanation: ""), side: .answer))
    }

    func testClozeNeverSpeaksTheHiddenAnswerOrHint() throws {
        let source = TextContent(question: "The {{c1::capital::Tokyo}} is busy.", answer: "", explanation: "")
        let shown = try CardGeneration.displayed(kind: .cloze, content: source, variant: "cloze:1")
        XCTAssertFalse(shown.question.contains("capital"))
        XCTAssertEqual(SpeechReadout.text(kind: .cloze, displayed: shown, side: .question), "The   is busy.")
        XCTAssertEqual(SpeechReadout.text(kind: .cloze, displayed: shown, side: .answer), "capital")
    }

    func testReverseCardSwapsReadoutTextWithoutLeakingBackside() throws {
        let source = TextContent(question: "Japanese meaning", answer: "English answer", explanation: "",
                                 reverseEnabled: true, speechQuestion: "What is the meaning?", speechAnswer: "The English answer.")
        let reversed = try CardGeneration.displayed(kind: .basic, content: source, variant: "basic:reverse")
        XCTAssertEqual(SpeechReadout.text(kind: .basic, displayed: reversed, side: .question), "The English answer.")
        XCTAssertEqual(SpeechReadout.text(kind: .basic, displayed: reversed, side: .answer), "What is the meaning?")
    }

    func testOptionsAndNoteSpeechRoundTrip() throws {
        var options = StudyOptions()
        let deckID = UUID()
        var speech = SpeechPreferences()
        speech.accent = .british; speech.pace = .slow; speech.deckAutoplay[deckID.uuidString] = .question
        options.speech = speech
        XCTAssertEqual(try JSONDecoder().decode(StudyOptions.self, from: JSONEncoder().encode(options)).speech, speech)
        var content = TextContent(question: "Hello", answer: "World", explanation: "")
        content.speechAutoplayOverride = .both; content.speechAnswer = "Hello, world."
        XCTAssertEqual(try JSONDecoder().decode(TextContent.self, from: JSONEncoder().encode(content)), content)
    }
}