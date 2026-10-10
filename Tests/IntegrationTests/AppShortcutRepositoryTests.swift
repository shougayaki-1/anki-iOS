import XCTest
import SwiftData
@testable import AnkiIOS

@MainActor
final class AppShortcutRepositoryTests: XCTestCase {
    func testDeckQueryOnlyReadsUUIDAndPathEvenAfterDeletion() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true))
        try repo.initialize(now: now)
        let root = try XCTUnwrap(repo.decks().first?.id)
        try repo.moveDeck(id: root, name: "共通", parentID: nil, now: now)
        let parent = try repo.createDeck(name: "学習", now: now)
        let nested = try repo.createDeck(name: "共通", parentID: parent, now: now)
        try repo.createNote(NoteInput(deckID: nested, question: "Q", answer: "A"), now: now)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(mode: .typing, text: "途中", now: now)
        let oldCard = try XCTUnwrap(repo.cards().first)
        let beforePayload = oldCard.fsrsPayload
        let beforeDue = oldCard.dueDate
        let beforeLogs = try repo.logs().map(\.id)
        let beforeCardID = try repo.session()?.cardID
        let beforeDraft = try repo.session()?.typedDraft

        let all = try ShortcutDeckDirectory.read(from: repo)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.first(where: { $0.id == root.uuidString })?.path, "共通")
        XCTAssertEqual(all.first(where: { $0.id == nested.uuidString })?.path, "学習 / 共通")
        XCTAssertEqual(ShortcutDeckDirectory.matching([nested.uuidString], in: all).count, 1)

        try repo.deleteDeck(id: parent, moveNotesTo: root, now: now)
        let after = try ShortcutDeckDirectory.read(from: repo)
        XCTAssertTrue(ShortcutDeckDirectory.matching([nested.uuidString], in: after).isEmpty)
        XCTAssertEqual(try repo.logs().map(\.id), beforeLogs)
        XCTAssertEqual(try repo.cards().first?.fsrsPayload, beforePayload)
        XCTAssertEqual(try repo.cards().first?.dueDate, beforeDue)
        XCTAssertEqual(try repo.session()?.cardID, beforeCardID)
        XCTAssertEqual(try repo.session()?.typedDraft, beforeDraft)
    }
}
