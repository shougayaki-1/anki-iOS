import XCTest
@testable import AnkiIOS

final class CardGenerationTests: XCTestCase {
    func testRubyParsingSafeHTMLFallbackAndVerticalDigits() throws {
        let document = RubyDocument.parse("｜春暁《しゅんぎょう》 12年。\n｜東京《とうきょう》<script>alert(1)</script>")
        XCTAssertNil(document.warning); XCTAssertTrue(document.hasRuby)
        XCTAssertTrue(document.spoken.contains("春暁（しゅんぎょう）"))
        let html = document.html(layout: .vertical, fontSize: 24)
        XCTAssertTrue(html.contains("writing-mode:vertical-rl"))
        XCTAssertTrue(html.contains("<ruby>春暁<rt>しゅんぎょう</rt></ruby>"))
        XCTAssertTrue(html.contains("<span class=\"tcy\">12</span>"))
        XCTAssertTrue(html.contains("&lt;script&gt;")); XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("https://")); XCTAssertTrue(html.contains("default-src 'none'"))
        for source in ["｜漢字《", "｜《から》", "｜漢字《》", "漢字《かんじ》", "｜漢字《読\nみ》"] {
            let parsed = RubyDocument.parse(source)
            XCTAssertNotNil(parsed.warning); XCTAssertEqual(parsed.plain, source)
        }
        XCTAssertEqual(RubyDocument.parse("普通の本文").plain, "普通の本文")
    }
    func testRubyClozeNeverLeaksReadingAndReverseSwapsLayouts() throws {
        var content = TextContent(question: "｜{{c1::東京}}《とうきょう》と{{c2::｜大阪《おおさか》}}", answer: "A", explanation: "", questionLayout: .vertical, answerLayout: .horizontal)
        let first = try CardGeneration.displayed(kind: .cloze, content: content, variant: "cloze:1")
        XCTAssertFalse(first.question.contains("とうきょう"))
        XCTAssertTrue(first.question.contains("｜大阪《おおさか》"))
        let second = try CardGeneration.displayed(kind: .cloze, content: content, variant: "cloze:2")
        XCTAssertFalse(second.question.contains("おおさか")); XCTAssertTrue(second.answer.contains("おおさか"))
        content.reverseEnabled = true
        let reverse = try CardGeneration.displayed(kind: .basic, content: content, variant: "basic:reverse")
        XCTAssertEqual(reverse.questionLayout, .horizontal); XCTAssertEqual(reverse.answerLayout, .vertical)
        let legacy = try JSONDecoder().decode(TextContent.self, from: Data(#"{"schemaVersion":1,"question":"Q","answer":"A","explanation":""}"#.utf8))
        XCTAssertNil(legacy.questionLayout); XCTAssertNil(legacy.answerLayout)
    }
    func testHintCompatibilityAndSharedVariants() throws {
        let old = Data(#"{"schemaVersion":1,"question":"Q","answer":"A","explanation":"E"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(TextContent.self, from: old).hint)
        let input = NoteInput(deckID: UUID(), question: "Q", answer: "A", hint: "手がかり\n二行目")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        legacy.removeValue(forKey: "hint")
        XCTAssertNil(try JSONDecoder().decode(NoteInput.self, from: JSONSerialization.data(withJSONObject: legacy)).hint)
        XCTAssertEqual(try JSONDecoder().decode(NoteInput.self, from: JSONEncoder().encode(input)), input)
        var content = TextContent(question: "Q", answer: "A", explanation: "E", hint: input.hint, reverseEnabled: true)
        for kind in [NoteKind.basic, .written] {
            XCTAssertEqual(try CardGeneration.displayed(kind: kind, content: content, variant: "basic:front").hint, input.hint)
        }
        XCTAssertNil(try CardGeneration.displayed(kind: .basic, content: content, variant: "basic:reverse").hint)
        content.question = "{{c1::東京::都市}}と{{c2::京都}}"
        XCTAssertEqual(try CardGeneration.variants(kind: .cloze, content: content), ["cloze:1", "cloze:2"])
        for key in ["cloze:1", "cloze:2"] {
            XCTAssertEqual(try CardGeneration.displayed(kind: .cloze, content: content, variant: key).hint, input.hint)
        }
        XCTAssertEqual(try CardGeneration.displayed(kind: .cloze, content: content, variant: "cloze:1").question, "[都市]と京都")
        content.imageID = UUID()
        content.masks = [ImageMask(rect: MaskRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), answer: "one"),
                         ImageMask(rect: MaskRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), answer: "two")]
        for key in try CardGeneration.variants(kind: .imageOcclusion, content: content) {
            let shown = try CardGeneration.displayed(kind: .imageOcclusion, content: content, variant: key)
            XCTAssertEqual(shown.hint, input.hint)
            XCTAssertEqual(shown.masks, content.masks)
        }
    }
    func testClozeStableIDsRepeatedIDsHintsAndUnicode() throws {
        let content = TextContent(question: "日本の首都は{{c1::東京::都市}}。{{c2::日本語}}を使い、{{c1::東京都}}に住む。", answer: "", explanation: "explain")
        XCTAssertEqual(try CardGeneration.variants(kind: .cloze, content: content), ["cloze:1", "cloze:2"])
        let first = try CardGeneration.displayed(kind: .cloze, content: content, variant: "cloze:1")
        XCTAssertEqual(first.question, "日本の首都は[都市]。日本語を使い、[…]に住む。")
        XCTAssertEqual(first.answer, "東京 / 東京都")
        XCTAssertEqual(first.explanation, "explain")
        XCTAssertThrowsError(try CardGeneration.clozes("No holes"))
        XCTAssertThrowsError(try CardGeneration.clozes("{{c1::valid}} {{c2::unfinished"))
        XCTAssertThrowsError(try CardGeneration.clozes("{{c0::invalid}}"))
        XCTAssertNoThrow(try CardGeneration.variants(kind: .cloze, content: TextContent(question: "{{c999999999999999999999999999::safe}}", answer: "", explanation: "")))
    }
    func testReverseCardHasStableVariantAndSwapsDisplay() throws {
        let content = TextContent(question: "Q", answer: "A", explanation: "E", reverseEnabled: true)
        XCTAssertEqual(try CardGeneration.variants(kind: .basic, content: content), ["basic:front", "basic:reverse"])
        let reverse = try CardGeneration.displayed(kind: .basic, content: content, variant: "basic:reverse")
        XCTAssertEqual(reverse.question, "A"); XCTAssertEqual(reverse.answer, "Q")
        XCTAssertEqual(try CardGeneration.variants(kind: .written, content: content), ["basic:front"])
    }
}

final class NumericSettingsInputTests: XCTestCase {
    func testIntegerBoundariesAndMalformedDrafts() {
        for (range, values) in [(StudySettings.newLimitRange, [0, 10, 200, 500]),
                                (StudySettings.goalRange, [1, 20, 200, 500]),
                                (StudySettings.dayStartRange, [0, 4, 23]),
                                (StudySettings.retentionPercentRange, [80, 90, 97])] {
            for value in values { XCTAssertEqual(NumericSettingsInput.integer(String(value), in: range), value) }
            for text in ["", "-1", "1.5", "abc", " 10", "10 ", "1e2", String(repeating: "9", count: 100),
                         String(range.lowerBound - 1), String(range.upperBound + 1)] {
                XCTAssertNil(NumericSettingsInput.integer(text, in: range), text)
            }
        }
        XCTAssertNil(NumericSettingsInput.integer("0", in: StudySettings.goalRange))
        for percent in [80, 90, 97] { XCTAssertEqual(Double(percent) / 100, Double("0.\(percent)")!) }
    }
    func testMaskPercentageGeometryAndFractionalPrecision() throws {
        let rect = MaskRect(x: 0.25, y: 0.25, width: 0.2, height: 0.25)
        let edge = try XCTUnwrap(rect.replacingPercentage("80", at: \.x))
        XCTAssertEqual(edge.x, 0.8)
        XCTAssertEqual(edge.width, 0.2)
        XCTAssertNil(rect.replacingPercentage("90", at: \.x))
        XCTAssertNil(rect.replacingPercentage("76", at: \.height))
        XCTAssertEqual(rect.replacingPercentage("1", at: \.width)?.width, 0.01)
        XCTAssertNil(rect.replacingPercentage("0.99", at: \.width))
        let precise = try XCTUnwrap(rect.replacingPercentage("12.345", at: \.x))
        XCTAssertEqual(precise.x, 0.12345, accuracy: 1e-12)
        XCTAssertEqual(try JSONDecoder().decode(MaskRect.self, from: JSONEncoder().encode(precise)), precise)
        for text in ["", "-1", "101", "NaN", "inf", "1e2", "1..2", ".5", "1.", String(repeating: "9", count: 400)] {
            XCTAssertNil(rect.replacingPercentage(text, at: \.x), text)
        }
        XCTAssertEqual(rect.replacingPercentage("0", at: \.x)?.x, 0)
        XCTAssertEqual(MaskRect(x: 0, y: 0, width: 1, height: 1).replacingPercentage("100", at: \.height)?.height, 1)
    }
}
