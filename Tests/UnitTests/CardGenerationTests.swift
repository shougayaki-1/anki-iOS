import XCTest
@testable import AnkiIOS

final class CardGenerationTests: XCTestCase {
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
