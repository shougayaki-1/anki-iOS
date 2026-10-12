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

extension SpeechReadoutTests {
    static func silence(seconds: Int = 1) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        let size = UInt32(seconds * 8000 * 2)
        text("RIFF"); number(size + 36); text("WAVEfmt "); number(UInt32(16))
        number(UInt16(1)); number(UInt16(1)); number(UInt32(8000)); number(UInt32(16000))
        number(UInt16(2)); number(UInt16(16)); text("data"); number(size)
        data.append(Data(count: Int(size)))
        return data
    }
    func testAudioSelectionFullyDecodesAndRejectsTruncatedOversizedAndLongFiles() throws {
        let bytes = Self.silence()
        let audio = try AudioEncodingPolicy.prepare(bytes)
        XCTAssertEqual(audio.data, bytes); XCTAssertEqual(audio.mediaType, "audio/wav")
        XCTAssertEqual(audio.duration, 1, accuracy: 0.001)
        XCTAssertThrowsError(try AudioEncodingPolicy.prepare(Data("not audio".utf8)))
        XCTAssertThrowsError(try AudioEncodingPolicy.prepare(Data(count: 20_000_001)))
        XCTAssertThrowsError(try AudioEncodingPolicy.prepare(Self.silence(seconds: 601)))
        XCTAssertThrowsError(try AudioEncodingPolicy.prepare(bytes.dropLast()))
        var truncated = Data(bytes.dropLast(2))
        let declared = UInt32(truncated.count - 8)
        for index in 0..<4 { truncated[4 + index] = UInt8(truncatingIfNeeded: declared >> (index * 8)) }
        XCTAssertThrowsError(try AudioEncodingPolicy.prepare(truncated))
    }
    func testM4AAudioDecodesWithoutConvertingOriginalBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1])
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8000))
            buffer.frameLength = 8000
            memset(buffer.floatChannelData![0], 0, 8000 * MemoryLayout<Float>.size)
            try file.write(from: buffer)
        }
        let bytes = try Data(contentsOf: url)
        let prepared = try AudioEncodingPolicy.prepare(bytes)
        XCTAssertEqual(prepared.mediaType, "audio/mp4"); XCTAssertEqual(prepared.data, bytes)
    }
    func testReverseSwapsAudioAndLegacyPayloadDefaultsToNoAudio() throws {
        let q = UUID(), a = UUID()
        let content = TextContent(question: "Q", answer: "A", explanation: "", reverseEnabled: true, questionAudioID: q, answerAudioID: a)
        let reverse = try CardGeneration.displayed(kind: .basic, content: content, variant: "basic:reverse")
        XCTAssertEqual(reverse.questionAudioID, a); XCTAssertEqual(reverse.answerAudioID, q)
        let old = try JSONDecoder().decode(TextContent.self, from: Data(#"{"schemaVersion":2,"question":"Q","answer":"A","explanation":""}"#.utf8))
        XCTAssertTrue(old.audioIDs.isEmpty)
    }
    @MainActor
    func testAttachedPlaybackStopsOnPauseInterruptionAndMissingFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.silence(seconds: 10).write(to: url)
        let player = StudySpeechPlayer()
        player.playAttached(url: url)
        XCTAssertTrue(player.playing)
        player.stop(); XCTAssertFalse(player.playing)
        player.playAttached(url: url)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(player.playing)
        try FileManager.default.removeItem(at: url)
        player.playAttached(url: url)
        XCTAssertFalse(player.playing); XCTAssertNotNil(player.notice)
    }
}


extension SpeechReadoutTests {
    func testEnglishVoiceFallbackNeverSelectsAnotherLanguage() {
        XCTAssertEqual(SpeechVoiceSelection.index(languages: ["ja-JP", "en-GB", "en-US"], accent: .american), 2)
        XCTAssertEqual(SpeechVoiceSelection.index(languages: ["en-US", "en-GB"], accent: .british), 1)
        XCTAssertEqual(SpeechVoiceSelection.index(languages: ["ja-JP", "en-AU"], accent: .british), 1)
        XCTAssertNil(SpeechVoiceSelection.index(languages: ["ja-JP", "fr-FR"], accent: .american))
        XCTAssertNil(SpeechVoiceSelection.index(languages: [], accent: .british))
    }
    func testUnavailableReadoutHasReasonWithoutSpeakingHiddenContent() {
        for (text, reason) in [("", SpeechReadoutFailure.emptyText), ("{{c1::secret}}", .hiddenContent), ("catとは何ですか", .mixedLanguage), ("12345", .noEnglish)] {
            let result = SpeechReadout.assessment(kind: .basic, displayed: TextContent(question: text, answer: "Unrevealed secret", explanation: ""), side: .question)
            XCTAssertNil(result.text); XCTAssertEqual(result.failure, reason)
        }
    }
    @MainActor func testEmptyRequestsAndStoppedQueuesRemainIdle() async throws {
        let player = StudySpeechPlayer()
        player.play(text: " ", settings: SpeechPreferences())
        XCTAssertEqual(player.phase, .idle); XCTAssertNotNil(player.notice)
        for _ in 0..<3 { player.play(text: "A fictional English sentence for queue cancellation.", settings: SpeechPreferences()) }
        player.stop()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(player.phase, .idle); XCTAssertFalse(player.playing); XCTAssertNil(player.notice)
        player.unavailableReadout(.mixedLanguage)
        XCTAssertEqual(player.phase, .idle); XCTAssertTrue(player.notice?.contains("混在") == true)
    }
    @MainActor func testPhysicalEnglishVoicesBeginAndStopWithoutChangingData() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device AVSpeechSynthesizer smoke test")
        #else
        let player = StudySpeechPlayer()
        defer { player.stop() }
        for accent in SpeechAccent.allCases {
            var settings = SpeechPreferences(); settings.accent = accent
            player.play(text: String(repeating: "This fictional sentence checks speech playback. ", count: 5), settings: settings)
            let deadline = Date().addingTimeInterval(8)
            while player.phase == .requested, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertEqual(player.phase, .speaking, player.notice ?? "Speech did not start")
            player.stop()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(player.phase, .idle)
        }
        #endif
    }
}


extension SpeechReadoutTests {
    @MainActor func testSpeechRequestStartsOrProvidesRecoveryInsteadOfStayingPending() async throws {
        let player = StudySpeechPlayer()
        defer { player.stop() }
        player.play(text: String(repeating: "This is fictional speech for a start check. ", count: 5), settings: SpeechPreferences())
        let deadline = Date().addingTimeInterval(8)
        while player.phase == .requested, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotEqual(player.phase, .requested)
        if player.phase == .idle { XCTAssertNotNil(player.notice) }
        else { XCTAssertEqual(player.phase, .speaking) }
    }
}
