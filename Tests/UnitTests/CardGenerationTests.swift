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
