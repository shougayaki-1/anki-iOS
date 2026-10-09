import XCTest
@testable import AnkiIOS

@MainActor
final class ClozeRepositoryTests: XCTestCase {
    func testThreeClozeCardsRegenerateWithIDsAndFSRSHistoryIntact() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true))
        try repo.initialize(now: now)
        var input = NoteInput(deckID: try repo.decks()[0].id, kind: .cloze,
                              question: "{{c1::one}} {{c2::two}} {{c3::three}}", answer: "")
        let noteID = try repo.createNote(input, now: now)
        XCTAssertEqual(try repo.cards().count, 3)
        let ids = Dictionary(uniqueKeysWithValues: try repo.cards().map { ($0.variantKey, $0.id) })
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(revealed: true, now: now)
        try repo.grade(.good, now: now)
        let snapshots = Dictionary(uniqueKeysWithValues: try repo.cards().map { ($0.variantKey, $0.fsrsPayload) })
        input.question = "Updated {{c3::three}} before {{c1::one}} and {{c2::two}}"
        try repo.updateNote(id: noteID, input: input, now: now.addingTimeInterval(1))
        for card in try repo.cards() {
            XCTAssertEqual(card.id, ids[card.variantKey])
            XCTAssertEqual(card.fsrsPayload, snapshots[card.variantKey])
        }
        XCTAssertEqual(try repo.logs().count, 1)
        XCTAssertEqual(Set(try repo.noteItems().map(\.id)).count, 3)
        input.question += " plus {{c4::four}}"
        try repo.updateNote(id: noteID, input: input, now: now.addingTimeInterval(2))
        XCTAssertEqual(try repo.cards().count, 4)
        XCTAssertEqual(try repo.cards().first(where: { $0.variantKey == "cloze:1" })?.id, ids["cloze:1"])
    }

    func testPastedClozeGeneratesIndependentCardsAndBuriesSiblings() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true))
        try repo.initialize(now: now)
        let rows = try ImportParser.pasted("{{c1::one}} and {{c2::two}}")
        let result = try repo.importRows(rows, deckID: repo.decks()[0].id, kind: .cloze, tagNames: [], action: .skip, source: "paste", now: now)
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(try repo.cards().count, 2)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(revealed: true, now: now)
        try repo.grade(.easy, now: now)
        XCTAssertNil(try repo.presentation(now: now)?.card)
        XCTAssertEqual(try repo.counts(now: now).newRemaining, 0)
        try repo.start(mode: .new, now: now.addingTimeInterval(86400))
        XCTAssertNotNil(try repo.presentation(now: now.addingTimeInterval(86400))?.card)
    }
}
