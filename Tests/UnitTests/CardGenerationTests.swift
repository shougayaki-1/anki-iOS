import XCTest
@testable import AnkiIOS

final class CardGenerationTests: XCTestCase {
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
