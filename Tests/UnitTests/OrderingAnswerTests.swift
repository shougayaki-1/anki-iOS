import XCTest
@testable import AnkiIOS

final class OrderingAnswerTests: XCTestCase {
    func testWhitespaceContractionsHyphensTitlesAndPunctuationStayInTokens() throws {
        let answer = "  I'm  meeting Mr. Smith\nfor a well-known reason, don't you?  "
        let problem = try OrderingAnswer(kind: .basic, answer: answer)
        XCTAssertEqual(problem.original, answer)
        XCTAssertEqual(problem.tokens.map(\.text), ["I'm", "meeting", "Mr.", "Smith", "for", "a", "well-known", "reason,", "don't", "you?"])
        XCTAssertEqual(problem.tokens.map(\.id), Array(0..<10))
        XCTAssertEqual(OrderingAnswer.normalized("“DON’T?”"), "don't")
        XCTAssertEqual(OrderingAnswer.normalized("Mr."), "mr")
    }
    func testDuplicateWordsAreInterchangeableButWrongOrderAndRepeatedIDsFail() throws {
        let problem = try OrderingAnswer(kind: .written, answer: "I think I can.")
        XCTAssertTrue(problem.correct([0, 1, 2, 3]))
        XCTAssertTrue(problem.correct([2, 1, 0, 3]))
        XCTAssertFalse(problem.correct([0, 2, 1, 3]))
        XCTAssertFalse(problem.correct([0, 1, 0, 3]))
        XCTAssertFalse(problem.correct([0, 1, 2]))
        XCTAssertFalse(problem.correct([99, 1, 2, 3]))
        let decorated = try OrderingAnswer(kind: .basic, answer: "I like i.")
        XCTAssertTrue(decorated.correct([2, 1, 0]))
    }
    func testShuffleNeverStartsCorrectEvenWithDuplicateWordsOrBadShuffler() throws {
        for answer in ["I walk to school every day.", "I I think I.", "a b a b"] {
            let problem = try OrderingAnswer(kind: .basic, answer: answer)
            for shuffle in [{ (ids: [Int]) in ids }, { _ in [999] }, { $0.shuffled() }] {
                for _ in 0..<30 {
                    let ids = problem.shuffled(using: shuffle)
                    XCTAssertEqual(Set(ids), Set(problem.tokens.map(\.id)))
                    XCTAssertFalse(problem.correct(ids))
                }
            }
        }
    }
    func testUnsupportedInputsHaveReasonsAndUnknownModeFallsBack() throws {
        for answer in ["word", "I I I.", "!!! ???", "こんにちは 世界", String(repeating: "word ", count: 41),
                       "I " + String(repeating: "a", count: 49), "I\nwalk\nto\nschool", String(repeating: "a", count: 601)] {
            XCTAssertNotNil(OrderingAnswer.reason(kind: .basic, answer: answer))
        }
        for kind in [NoteKind.cloze, .imageOcclusion] {
            XCTAssertNotNil(OrderingAnswer.reason(kind: kind, answer: "I walk."))
        }
        XCTAssertNil(OrderingAnswer.reason(kind: .written, answer: "I have 2 apples."))
        XCTAssertEqual(try JSONDecoder().decode(ResponseMode.self, from: Data(#""future-mode""#.utf8)), .mental)
        XCTAssertEqual(try JSONDecoder().decode(ResponseMode.self, from: JSONEncoder().encode(ResponseMode.ordering)), .ordering)
    }
    func testIncorrectRetryAndRemovalKeepFirstAttemptAndShuffleAcrossCodingRoundTrip() throws {
        let problem = try OrderingAnswer(kind: .basic, answer: "I walk to school every day.")
        var state = OrderingDraft(cardID: UUID(), problem: problem, shuffle: { $0 })
        let pool = state.pool
        XCTAssertThrowsError(try state.apply(.check, problem: problem))
        for id in pool { try state.apply(.select(id), problem: problem) }
        XCTAssertThrowsError(try state.apply(.select(pool[0]), problem: problem))
        try state.apply(.check, problem: problem)
        XCTAssertEqual(state.result, .incorrect); XCTAssertEqual(state.firstAttemptCorrect, false)
        try state.apply(.remove(pool[0]), problem: problem)
        XCTAssertNil(state.result)
        try state.apply(.reset, problem: problem)
        for id in problem.tokens.map(\.id) { try state.apply(.select(id), problem: problem) }
        try state.apply(.check, problem: problem)
        XCTAssertEqual(state.result, .correct); XCTAssertEqual(state.firstAttemptCorrect, false)
        XCTAssertTrue(state.evaluationGuidance.contains("Again"))
        let reopened = try JSONDecoder().decode(OrderingDraft.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(reopened, state); XCTAssertEqual(reopened.pool, pool)
        XCTAssertTrue(reopened.isValid(for: problem, cardID: state.cardID))
        XCTAssertFalse(reopened.isValid(for: problem, cardID: UUID()))
        state.pool = [999]; XCTAssertFalse(state.isValid(for: problem, cardID: state.cardID))
    }
    func testInsertionMovesPersistAndDoNotSwapOrChangeTokenIdentity() throws {
        let problem = try OrderingAnswer(kind: .written, answer: "I walk to school every day.")
        var draft = OrderingDraft(cardID: UUID(), problem: problem, shuffle: { $0 })
        for id in [0, 3, 1, 2, 4, 5] { try draft.apply(.select(id), problem: problem) }
        let originalPool = draft.pool
        try draft.apply(.move(1, to: 1), problem: problem)
        XCTAssertEqual(draft.selected, [0, 1, 3, 2, 4, 5])
        try draft.apply(.move(2, to: 2), problem: problem)
        XCTAssertEqual(draft.selected, [0, 1, 2, 3, 4, 5])
        XCTAssertTrue(problem.correct(draft.selected))
        try draft.apply(.move(0, to: 5), problem: problem)
        XCTAssertEqual(draft.selected, [1, 2, 3, 4, 5, 0])
        try draft.apply(.move(0, to: 0), problem: problem)
        XCTAssertTrue(problem.correct(draft.selected))
        try draft.apply(.move(3, to: 3), problem: problem) // no-op
        XCTAssertEqual(draft.pool, originalPool)
        XCTAssertThrowsError(try draft.apply(.move(99, to: 0), problem: problem))
        XCTAssertThrowsError(try draft.apply(.move(1, to: 6), problem: problem))
        XCTAssertTrue(draft.isValid(for: problem, cardID: draft.cardID))
        XCTAssertEqual(try JSONDecoder().decode(OrderingDraft.self, from: JSONEncoder().encode(draft)), draft)
    }

    func testDuplicateIdentityAndWrongOrderCorrectionAfterVerdict() throws {
        let problem = try OrderingAnswer(kind: .basic, answer: "I think I can.")
        var draft = OrderingDraft(cardID: UUID(), problem: problem, shuffle: { $0 })
        for id in [0, 2, 1, 3] { try draft.apply(.select(id), problem: problem) }
        try draft.apply(.check, problem: problem)
        XCTAssertEqual(draft.result, .incorrect)
        XCTAssertEqual(draft.firstAttemptCorrect, false)
        try draft.apply(.move(1, to: 1), problem: problem)
        XCTAssertEqual(draft.selected, [0, 1, 2, 3])
        XCTAssertEqual(Set(draft.selected), Set(draft.pool))
        XCTAssertNil(draft.result)
        try draft.apply(.check, problem: problem)
        XCTAssertEqual(draft.result, .correct)
        XCTAssertEqual(draft.firstAttemptCorrect, false)
        XCTAssertTrue(draft.isValid(for: problem, cardID: draft.cardID))
    }

    func testWrappedRowInsertionGeometryChoosesNearestRowAndAllBoundaries() {
        let ids = [10, 11, 12, 13]
        let frames: [Int: CGRect] = [
            10: CGRect(x: 0, y: 0, width: 55, height: 44),
            11: CGRect(x: 63, y: 0, width: 65, height: 44),
            12: CGRect(x: 0, y: 52, width: 100, height: 48),
            13: CGRect(x: 108, y: 52, width: 45, height: 48)
        ]
        XCTAssertEqual(OrderingInsertionLocation.resolve(CGPoint(x: 2, y: 20), ids: ids, frames: frames), 0)
        XCTAssertEqual(OrderingInsertionLocation.resolve(CGPoint(x: 62, y: 20), ids: ids, frames: frames), 1)
        XCTAssertEqual(OrderingInsertionLocation.resolve(CGPoint(x: 200, y: 20), ids: ids, frames: frames), 2)
        XCTAssertEqual(OrderingInsertionLocation.resolve(CGPoint(x: 4, y: 70), ids: ids, frames: frames), 2)
        XCTAssertEqual(OrderingInsertionLocation.resolve(CGPoint(x: 200, y: 90), ids: ids, frames: frames), 4)
        XCTAssertEqual(OrderingInsertionLocation.resolve(CGPoint(x: 20, y: 110), ids: ids, frames: frames), 2)
        XCTAssertNil(OrderingInsertionLocation.resolve(CGPoint(x: 0, y: 0), ids: [], frames: [:]))
    }

    func testCSVModeAliasesOptionalHeadersAndLegacyRows() throws {
        let table = try ImportParser.table("question,answer,responseMode\nQ,I walk to school.,ordering\nQ2,I can.,typing\nQ3,A,unknown\nQ4,A,", delimiter: ",")
        XCTAssertEqual(ImportParser.responseModeColumn(in: table), 2)
        let rows = ImportParser.map(table, header: true, questionColumn: 0, answerColumn: 1, modeColumn: 2)
        XCTAssertEqual(rows.map(\.responseMode), [.ordering, .typing, .mental, .mental])
        XCTAssertNotNil(rows[2].modeWarning)
        XCTAssertTrue(ImportParser.map(table, header: true, questionColumn: 0, answerColumn: 1).allSatisfy { $0.responseMode == nil })
        let tsv = try ImportParser.table("問題\t解答\t回答方式\nQ\tI can.\t並び替え", delimiter: "\t")
        XCTAssertEqual(ImportParser.responseModeColumn(in: tsv), 2)
        XCTAssertEqual(ImportParser.map(tsv, header: true, questionColumn: 0, answerColumn: 1, modeColumn: 2)[0].responseMode, .ordering)
    }
}
