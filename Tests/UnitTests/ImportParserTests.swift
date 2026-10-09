import XCTest
@testable import AnkiIOS

final class ImportParserTests: XCTestCase {
    func testCSVQuotedCommasNewlinesQuotesAndHeaderMapping() throws {
        let text = "id,answer,question\r\n1,\"A, with \"\"quotes\"\"\",\"Q\nsecond line\"\r\n2,A2,Q2\r\n"
        let table = try ImportParser.table(text, delimiter: ",")
        XCTAssertEqual(table.rows.count, 3)
        let rows = ImportParser.map(table, header: true, questionColumn: 2, answerColumn: 1)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].question, "Q\nsecond line")
        XCTAssertEqual(rows[0].answer, "A, with \"quotes\"")
        XCTAssertEqual(rows.map(\.line), [2, 4])
    }
    func testTSVBlankFieldsAndInvalidCSV() throws {
        let rows = ImportParser.map(try ImportParser.table("Q\tA\nmissing\t\n\n", delimiter: "\t"), header: false, questionColumn: 0, answerColumn: 1)
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotNil(rows[1].error)
        XCTAssertThrowsError(try ImportParser.table("\"unterminated", delimiter: ","))
        XCTAssertThrowsError(try ImportParser.table("unquoted\"quote,A", delimiter: ","))
        XCTAssertThrowsError(try ImportParser.table("\"Q\"extra,A", delimiter: ","))
    }
    func testPasteQAAndPlainTextRemainEditable() throws {
        let rows = try ImportParser.pasted("Q: Question\ncontinued\nA: Answer\nmore\nQ: Q2\nA: A2")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].question, "Question\ncontinued")
        XCTAssertEqual(rows[0].answer, "Answer\nmore")
        let prose = try ImportParser.pasted("A plain paragraph without questions")
        XCTAssertEqual(prose.count, 1)
        XCTAssertEqual(prose[0].answer, "")
        XCTAssertNotNil(prose[0].error)
        XCTAssertEqual(try ImportParser.pasted("Q1\tA1\nQ2\tA2").count, 2)
    }
}
