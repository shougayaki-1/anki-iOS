import XCTest
import AVFoundation
@testable import AnkiIOS

final class SpeechReadoutTests: XCTestCase {
    func testLongEnglishReadoutRetainsFullTextAndClozeStillHidesTheAnswer() {
        let longText = String(repeating: "This is a longer English passage. ", count: 150)
        XCTAssertGreaterThan(longText.count, 3000)
        let content = TextContent(question: longText, answer: "Unrevealed answer.", explanation: "")
        XCTAssertEqual(SpeechReadout.text(kind: .basic, displayed: content, side: .question),
                       longText.trimmingCharacters(in: .whitespacesAndNewlines))
        let cloze = TextContent(question: longText + " [hidden answer]", answer: "hidden answer", explanation: "")
        let readout = SpeechReadout.text(kind: .cloze, displayed: cloze, side: .question)
        XCTAssertEqual(readout, longText.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertFalse(readout?.contains("hidden answer") ?? true)
    }

    @MainActor
    func testInterruptionAndDisconnectedOutputDiscardSpeech() async throws {
        let player = StudySpeechPlayer()
        for notification in [
            Notification(name: AVAudioSession.interruptionNotification,
                         userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]),
            Notification(name: AVAudioSession.routeChangeNotification,
                         userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        ] {
            player.play(text: "A long sentence that must stop when audio is interrupted.", settings: SpeechPreferences())
            NotificationCenter.default.post(notification)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(player.playing)
            XCTAssertNil(player.notice)
        }
    }

    func testOldNotesAndOptionsDefaultToSilence() throws {
        let note = try JSONDecoder().decode(TextContent.self, from: Data(#"{"schemaVersion":2,"question":"Hello!","answer":"Hi.","explanation":""}"#.utf8))
        XCTAssertNil(note.speechOverrides)
        XCTAssertNil(note.speechQuestion)
        XCTAssertNil(note.speechAnswer)
        let options = try JSONDecoder().decode(StudyOptions.self, from: Data(#"{"schemaVersion":2,"siblingBuryEnabled":true}"#.utf8))
        XCTAssertNil(options.speech)
        XCTAssertEqual(SpeechPreferences().autoplay(deckID: UUID(), noteOverride: nil), .off)
        // Old NoteInput drafts must remain decodable without the new optional fields.
        let legacy = try JSONDecoder().decode(NoteInput.self, from: JSONEncoder().encode(NoteInput(deckID: UUID(), question: "Q", answer: "A")))
        XCTAssertNil(legacy.speechOverrides)
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

    func testClozeUnsafeBracketsFailClosed() {
        let text = TextContent(question: "The [secret] ] remains.", answer: "secret", explanation: "")
        XCTAssertNil(SpeechReadout.text(kind: .cloze, displayed: text, side: .question))
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
        content.speechOverrides = ["basic:front": .both]; content.speechAnswer = "Hello, world."
        XCTAssertEqual(try JSONDecoder().decode(TextContent.self, from: JSONEncoder().encode(content)), content)
    }
}
