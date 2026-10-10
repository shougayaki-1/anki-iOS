import XCTest
import SwiftData
@testable import AnkiIOS

@MainActor
final class LibraryRepositoryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    enum Failure: Error { case save }
    func fixture() throws -> StudyRepository {
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true))
        try repo.initialize(now: now); return repo
    }

    func testHomeFilterPersistsSeparatelyFromSessionAndGlobalProgress() async throws {
        let container = try PersistenceController.makeStudyContainer(inMemory: true)
        let repo = StudyRepository(container: container)
        try repo.initialize(now: now)
        let root = try repo.decks()[0].id
        let child = try repo.createDeck(name: "子", parentID: root, now: now)
        let other = try repo.createDeck(name: "別", now: now)
        try repo.createNote(NoteInput(deckID: child, question: "Q", answer: "A", tagNames: ["A", "B"]), now: now)
        try repo.createNote(NoteInput(deckID: other, question: "Other", answer: "A"), now: now)
        let tags = try repo.tags().map(\.id)
        let original = LearningScope(deckID: root, tagIDs: tags)
        try repo.applyHomeScope(original)
        try repo.start(mode: .new, scope: original, now: now)
        try repo.updateDraft(revealed: true, now: now); try repo.grade(.again, now: now)
        try repo.updateDraft(mode: .typing, text: "keep", revealed: true, now: now)
        let before = try XCTUnwrap(repo.session())
        let undo = before.undoLogID, touched = before.touchedCardIDs
        try repo.applyHomeScope(LearningScope(deckID: other))
        let reopened = StudyRepository(container: container)
        XCTAssertEqual(try reopened.homeScope().deckID, other)
        XCTAssertEqual(try reopened.scope(), try reopened.normalizedScope(original))
        XCTAssertEqual(try reopened.session()?.typedDraft, "keep")
        XCTAssertEqual(try reopened.session()?.undoLogID, undo)
        XCTAssertEqual(try reopened.session()?.touchedCardIDs, touched)
        XCTAssertEqual(try reopened.scopedCounts(scope: LearningScope(deckID: other), now: now).learnedToday, 1)
        var settings = try reopened.settings(); settings.dailyNewLimit = 1
        try reopened.updateSettings(settings)
        XCTAssertEqual(try reopened.scopedCounts(scope: LearningScope(deckID: other), now: now).newRemaining, 0)
        try reopened.resume(now: now.addingTimeInterval(61))
        XCTAssertEqual(try reopened.presentation(now: now.addingTimeInterval(61))?.card?.deckID, child)
        let backup = try BackupArchive.decode(await BackupService.export(repository: reopened, now: now, appVersion: "28"))
        XCTAssertEqual(try JSONDecoder().decode(StudyOptions.self, from: backup.data.options[0].payload).homeScope?.deckID, other)
    }
    func testHomeFilterSaveFailureAndInvalidReferences() throws {
        let repo = try fixture(), root = try repo.decks()[0].id
        try repo.applyHomeScope(LearningScope(deckID: root))
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.applyHomeScope(LearningScope()))
        XCTAssertEqual(try repo.homeScope().deckID, root)
        repo.save = { try $0.save() }
        try repo.applyHomeScope(LearningScope(deckID: UUID(), tagIDs: [UUID()]))
        XCTAssertEqual(try repo.homeScope(), LearningScope())
        try repo.applyHomeScope(LearningScope(deckID: root))
        try repo.deleteDeck(id: root, moveNotesTo: nil, now: now)
        XCTAssertEqual(try repo.homeScope(), LearningScope())
    }

    func testHierarchyScopeAndCyclePreventionPreserveCardIDs() throws {
        let repo = try fixture()
        let root = try repo.decks()[0].id
        let child = try repo.createDeck(name: "子", parentID: root, now: now)
        let other = try repo.createDeck(name: "別", now: now)
        let note = try repo.createNote(NoteInput(deckID: child, question: "Q", answer: "A", tagNames: ["Language", "language", " 東京 "]), now: now)
        let cardID = try XCTUnwrap(repo.cards().first?.id)
        XCTAssertEqual(try repo.tags().count, 2)
        let tagID = try XCTUnwrap(repo.tags().first?.id)
        XCTAssertEqual(try repo.scopedQueueCards(LearningScope(deckID: root, tagIDs: [tagID])).map(\.id), [cardID])
        XCTAssertTrue(try repo.scopedQueueCards(LearningScope(deckID: other)).isEmpty)
        XCTAssertThrowsError(try repo.moveDeck(id: root, name: "root", parentID: child, now: now))
        try repo.moveDeck(id: child, name: "移動", parentID: other, now: now)
        XCTAssertEqual(try repo.cards().first?.id, cardID)
        XCTAssertTrue(try repo.scopedQueueCards(LearningScope(deckID: root)).isEmpty)
        try repo.deleteDeck(id: other, moveNotesTo: root, now: now)
        XCTAssertEqual(try repo.notes().first(where: { $0.id == note })?.deckID, root)
        XCTAssertEqual(try repo.cards().first?.id, cardID)
    }

    func testImportSkipsDuplicatesWithinBatchAndKeepsHistory() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        let rows = [ImportRow(line: 1, question: "Q", answer: "A"),
                    ImportRow(line: 2, question: " Q ", answer: " A "),
                    ImportRow(line: 3, question: "bad", answer: "")]
        let result = try repo.importRows(rows, deckID: deck, kind: .basic, tagNames: ["tag"], action: .skip, source: "csv", now: now)
        XCTAssertEqual(result.imported, 1); XCTAssertEqual(result.skipped, 1); XCTAssertEqual(result.errors.count, 1)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(revealed: true, now: now)
        try repo.grade(.easy, now: now)
        let payload = try repo.cards()[0].fsrsPayload
        let again = try repo.importRows([rows[0]], deckID: deck, kind: .basic, tagNames: [], action: .skip, source: "csv", now: now)
        XCTAssertEqual(again.skipped, 1)
        XCTAssertEqual(try repo.logs().count, 1)
        XCTAssertEqual(try repo.cards()[0].fsrsPayload, payload)
        let update = try repo.importRows([rows[0]], deckID: deck, kind: .basic, tagNames: ["updated"], action: .update, source: "paste", now: now)
        XCTAssertEqual(update.imported, 1)
        XCTAssertEqual(try repo.cards()[0].fsrsPayload, payload)
        XCTAssertEqual(try repo.logs().count, 1)
    }

    func testFailedImportLeavesNoNotesCardsTagsOrBatch() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.importRows([ImportRow(line: 1, question: "Q", answer: "A")], deckID: deck,
                                                kind: .written, tagNames: ["newTag"], action: .add, source: "csv", now: now))
        XCTAssertTrue(try repo.notes().isEmpty)
        XCTAssertTrue(try repo.cards().isEmpty)
        XCTAssertTrue(try repo.tags().isEmpty)
        XCTAssertTrue(try repo.context.fetch(FetchDescriptor<ImportBatch>()).isEmpty)
    }

    func testSiblingBuryDoesNotModifyFSRSAndShortLearningIsExempt() throws {
        let noteID = UUID(), first = UUID(), sibling = UUID(), short = UUID()
        let cards = [QueueCard(id: first, state: "review", due: now, createdAt: now, suspended: false, noteID: noteID),
                     QueueCard(id: sibling, state: "new", due: now, createdAt: now, suspended: false, noteID: noteID),
                     QueueCard(id: short, state: "learning", due: now, createdAt: now, suspended: false, noteID: noteID)]
        let logs = [QueueLog(cardID: first, reviewedAt: now, wasNew: false, noteID: noteID)]
        let builder = ReviewQueueBuilder(shuffled: { $0 })
        let result = builder.queue(cards: cards, logs: logs, settings: StudySettings(), mode: .mixed,
                                   touched: [], reviewStreak: 0, now: now)
        XCTAssertFalse(result.contains(sibling)); XCTAssertTrue(result.contains(short)); XCTAssertTrue(result.contains(first))
        var disabled = StudySettings(); disabled.siblingBuryEnabled = false
        XCTAssertTrue(builder.queue(cards: cards, logs: logs, settings: disabled, mode: .mixed,
                                    touched: [], reviewStreak: 0, now: now).contains(sibling))
        XCTAssertEqual(cards[1].state, "new"); XCTAssertEqual(cards[1].due, now)
    }

    func testMigrationFromPhase1DiskStorePreservesEveryExistingRecord() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Study.store")
        let expected = try writeV1(url)
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: url))
        try repo.initialize(now: now)
        XCTAssertEqual(try repo.cards()[0].id, expected.id)
        XCTAssertEqual(try repo.cards()[0].fsrsPayload, expected.payload)
        XCTAssertEqual(try repo.logs().count, 1)
        XCTAssertEqual(try repo.session()?.typedDraft, "restorable")
        XCTAssertEqual(try repo.noteItems()[0].content.question, "Q")
        try repo.updateOptions(StudyOptions())
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "new", answer: "answer", tagNames: ["tag"]), now: now)
        XCTAssertEqual(try repo.tags().count, 1)
    }
    private func writeV1(_ url: URL) throws -> (id: UUID, payload: Data) {
        let schema = Schema(versionedSchema: StudySchema.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration("Study", schema: schema, url: url, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let deck = Deck(name: "old", now: now)
        let input = NoteInput(deckID: deck.id, question: "Q", answer: "A")
        let note = Note(input: input, content: try JSONEncoder().encode(TextContent(question: "Q", answer: "A", explanation: "")), now: now)
        let scheduler = try ReviewScheduler(), snapshot = try scheduler.newCard(now: now)
        let before = try JSONEncoder().encode(snapshot)
        let card = StudyCard(noteID: note.id, variantKey: "basic:front", payload: before, now: now)
        let transition = try scheduler.review(snapshot, grade: .good, now: now)
        let after = try JSONEncoder().encode(transition.after)
        let log = StudyReviewLog(card: card, transition: transition, before: before, after: after, mode: .mental, durationMs: 1000, wasNew: true, sequence: 1)
        card.fsrsPayload = after; card.dueDate = try scheduler.summary(transition.after).dueDate
        let draft = SessionDraft(mode: .new, now: now); draft.typedDraft = "restorable"
        context.insert(deck); context.insert(note); context.insert(card); context.insert(log)
        context.insert(draft); context.insert(StudyPreferences()); try context.save()
        return (card.id, after)
    }
}
