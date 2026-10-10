import XCTest
import SwiftData
@testable import AnkiIOS

@MainActor
final class OrderingRepositoryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    enum Failure: Error { case save }
    func fixture() throws -> StudyRepository {
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true))
        try repo.initialize(now: now)
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "毎日学校へ歩く", answer: "I walk to school every day.", hint: "Think of the verb", responseMode: .ordering), now: now)
        try repo.start(mode: .new, now: now)
        return repo
    }
    func state(_ repo: StudyRepository) throws -> OrderingDraft { try XCTUnwrap(repo.presentation(now: now)?.ordering) }
    func testIncorrectRetryCorrectRequiresOneExplicitGradeAndUndoResetsAnswer() throws {
        let repo = try fixture()
        let card = try XCTUnwrap(repo.cards().first), original = card.fsrsPayload, due = card.dueDate
        let initial = try state(repo)
        for id in initial.pool { try repo.updateOrdering(.select(id), now: now) }
        try repo.updateOrdering(.check, now: now)
        XCTAssertEqual(try state(repo).result, .incorrect)
        XCTAssertFalse(try XCTUnwrap(repo.presentation(now: now)).answerRevealed)
        XCTAssertTrue(try repo.logs().isEmpty); XCTAssertEqual(card.fsrsPayload, original); XCTAssertEqual(card.dueDate, due)
        try repo.updateOrdering(.reset, now: now)
        for id in 0..<6 { try repo.updateOrdering(.select(id), now: now) }
        try repo.updateOrdering(.check, now: now)
        XCTAssertTrue(try XCTUnwrap(repo.presentation(now: now)).answerRevealed)
        XCTAssertEqual(try state(repo).firstAttemptCorrect, false)
        XCTAssertTrue(try repo.logs().isEmpty); XCTAssertEqual(card.fsrsPayload, original)
        try repo.grade(.hard, now: now.addingTimeInterval(4))
        XCTAssertEqual(try repo.logs().count, 1); XCTAssertEqual(try repo.logs().first?.responseMode, "ordering")
        XCTAssertEqual(try repo.logs().first?.grade, ReviewGrade.hard.rawValue)
        try repo.undo(now: now.addingTimeInterval(5))
        XCTAssertEqual(try repo.cards().first?.id, card.id); XCTAssertEqual(card.fsrsPayload, original)
        XCTAssertTrue(try repo.logs().isEmpty); XCTAssertTrue(try state(repo).selected.isEmpty)
        XCTAssertNil(try state(repo).firstAttemptCorrect)
        XCTAssertFalse(try XCTUnwrap(repo.presentation(now: now)).answerRevealed)
    }
    func testModeSwitchTypingPauseReopenAndHintEditKeepOrderingAndHistory() throws {
        let repo = try fixture(), initial = try state(repo), card = try XCTUnwrap(repo.cards().first)
        try repo.updateOrdering(.select(initial.pool[0]), now: now)
        try repo.updateDraft(mode: .typing, text: "My typing draft", now: now)
        try repo.updateDraft(mode: .mental, now: now)
        try repo.updateDraft(mode: .ordering, now: now)
        try repo.setSessionActive(false, now: now.addingTimeInterval(2))
        let reopened = StudyRepository(container: repo.context.container)
        try reopened.initialize(now: now.addingTimeInterval(10)); try reopened.resume(now: now.addingTimeInterval(10))
        XCTAssertEqual(try state(reopened).pool, initial.pool)
        XCTAssertEqual(try state(reopened).selected, [initial.pool[0]])
        XCTAssertEqual(try reopened.session()?.typedDraft, "My typing draft")
        let item = try XCTUnwrap(reopened.noteItems().first)
        let changed = NoteInput(deckID: item.deckID, question: item.sourceContent.question, answer: item.sourceContent.answer,
                                hint: "Changed hint", responseMode: .ordering)
        try reopened.updateNote(id: item.noteID, input: changed, now: now)
        XCTAssertEqual(try state(reopened).selected, [initial.pool[0]])
        XCTAssertEqual(try reopened.session()?.typedDraft, "My typing draft")
        XCTAssertEqual(try reopened.cards().first?.id, card.id); XCTAssertTrue(try reopened.logs().isEmpty)
        XCTAssertEqual(try reopened.notes().first?.defaultResponseMode, "ordering")
    }
    func testReorderPersistsThroughPauseReopenAndDoesNotWriteReviewHistory() throws {
        let repo = try fixture()
        let card = try XCTUnwrap(repo.cards().first)
        let originalFSRS = card.fsrsPayload
        let originalDue = card.dueDate
        for id in [0, 3, 1, 2, 4, 5] { try repo.updateOrdering(.select(id), now: now) }
        try repo.updateOrdering(.move(1, to: 1), now: now)
        try repo.updateOrdering(.move(2, to: 2), now: now)
        XCTAssertEqual(try state(repo).selected, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(try repo.logs().count, 0)
        XCTAssertEqual(card.fsrsPayload, originalFSRS)
        XCTAssertEqual(card.dueDate, originalDue)
        try repo.setSessionActive(false, now: now)
        let reopened = StudyRepository(container: repo.context.container)
        try reopened.initialize(now: now.addingTimeInterval(2))
        try reopened.resume(now: now.addingTimeInterval(2))
        XCTAssertEqual(try state(reopened).selected, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(try reopened.logs().count, 0)
        try reopened.updateOrdering(.check, now: now.addingTimeInterval(3))
        XCTAssertEqual(try state(reopened).result, .correct)
        XCTAssertEqual(try reopened.logs().count, 0)
    }

    func testSaveFailureRollsBackSelectionAndCorrectRevealWithoutFSRSWrites() throws {
        let repo = try fixture()
        let initial = try state(repo)
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.updateOrdering(.select(0), now: now))
        XCTAssertEqual(try state(repo), initial)
        repo.save = { try $0.save() }
        for id in 0..<6 { try repo.updateOrdering(.select(id), now: now) }
        let before = try state(repo)
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.updateOrdering(.check, now: now))
        XCTAssertEqual(try state(repo), before)
        XCTAssertFalse(try XCTUnwrap(repo.presentation(now: now)).answerRevealed)
        XCTAssertTrue(try repo.logs().isEmpty)
    }
    func testOrderingImportBackupRestoreAndMissingLegacyField() async throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        let rows = (1...100).map { index -> ImportRow in
            var row = ImportRow(line: index, question: "Q\(index)", answer: "I have \(index) books.")
            row.responseMode = .ordering; return row
        }
        XCTAssertEqual(try repo.importRows(rows, deckID: deck, kind: .written, tagNames: [], action: .add, source: "csv", now: now).imported, 100)
        for id in try state(repo).pool { try repo.updateOrdering(.select(id), now: now) }
        try repo.updateOrdering(.check, now: now)
        try repo.updateOrdering(.reset, now: now)
        let first = try state(repo).pool[0]
        let second = try state(repo).pool[1]
        try repo.updateOrdering(.select(first), now: now)
        try repo.updateOrdering(.select(second), now: now)
        try repo.updateOrdering(.move(second, to: 0), now: now)
        XCTAssertEqual(try state(repo).selected, [second, first])
        let bytes = try await BackupService.export(repository: repo, now: now, appVersion: "56")
        let backup = try BackupArchive.decode(bytes)
        XCTAssertEqual(backup.data.orderingDrafts?.count, 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("Study.store"))
        let container = try BackupService.restore(backup, location: location, mediaStore: MediaStore(root: root.appendingPathComponent("Media")), now: now)
        let restored = StudyRepository(container: container)
        try restored.resume(now: now)
        XCTAssertEqual(try state(restored), try state(repo))
        XCTAssertEqual(try state(restored).firstAttemptCorrect, false)
        var invalid = backup.data
        var corrupt = try state(repo); corrupt.selected = [999]
        invalid.orderingDrafts = [BackupOrderingDraft(key: "active", payload: try JSONEncoder().encode(corrupt))]
        XCTAssertThrowsError(try BackupValidation.validate(invalid, media: [:]))
        invalid = backup.data; invalid.sessions[0].cardID = nil
        XCTAssertThrowsError(try BackupValidation.validate(invalid, media: [:]))
        XCTAssertEqual(try restored.notes().count, 101); XCTAssertEqual(try restored.logs().count, 0)
        let before = Set(try restored.cards().map(\.id))
        try restored.updateOrdering(.reset, now: now)
        for id in 0..<6 { try restored.updateOrdering(.select(id), now: now) }
        try restored.updateOrdering(.check, now: now); try restored.grade(.good, now: now)
        XCTAssertEqual(try restored.logs().count, 1); XCTAssertEqual(Set(try restored.cards().map(\.id)), before)
        var legacy = backup.data; legacy.orderingDrafts = nil
        let oldBytes = try BackupArchive.create(data: legacy, media: [:], now: now, appVersion: "legacy")
        XCTAssertNil(try BackupArchive.decode(oldBytes).data.orderingDrafts)
    }
    func testImportsKeepExistingModeWithoutColumnAndFallbackForInvalidOrdering() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        let original = try XCTUnwrap(repo.noteItems().first)
        let row = ImportRow(line: 1, question: original.content.question, answer: original.content.answer)
        _ = try repo.importRows([row], deckID: deck, kind: .basic, tagNames: [], action: .update, source: "csv", now: now)
        XCTAssertEqual(try repo.notes().first?.defaultResponseMode, "ordering")
        var invalid = ImportRow(line: 2, question: "single", answer: "one"); invalid.responseMode = .ordering
        _ = try repo.importRows([invalid], deckID: deck, kind: .basic, tagNames: [], action: .add, source: "csv", now: now)
        XCTAssertEqual(try repo.noteItems().first { $0.content.question == "single" }?.responseMode, .mental)
        try repo.transaction { try repo.notes().first { $0.id == original.noteID }?.defaultResponseMode = "future-mode" }
        XCTAssertEqual(try repo.noteItems().first { $0.noteID == original.noteID }?.responseMode, .mental)
    }
    func testIneligibleSavedDefaultFallsBackAndDeleteClearsOrderingRecord() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        try repo.deleteNote(id: XCTUnwrap(repo.notes().first?.id))
        XCTAssertTrue(try repo.context.fetch(FetchDescriptor<OrderingDraftRecord>()).isEmpty)
        try repo.createNote(NoteInput(deckID: deck, question: "Unsupported", answer: "one", responseMode: .ordering), now: now)
        try repo.start(mode: .new, now: now)
        let presentation = try XCTUnwrap(repo.presentation(now: now))
        XCTAssertEqual(presentation.responseMode, .mental); XCTAssertNotNil(presentation.orderingUnavailable)
        try repo.updateDraft(revealed: true, now: now); try repo.grade(.good, now: now)
        XCTAssertEqual(try repo.logs().first?.responseMode, "mental")
    }
    func testV3DiskStoreMigrationPreservesCardsHistoryAndTypedDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Study.store"), expected = try makeV3(url)
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: url))
        XCTAssertEqual(try repo.cards().first?.id, expected.0)
        XCTAssertEqual(try repo.cards().first?.fsrsPayload, expected.1)
        XCTAssertEqual(try repo.session()?.typedDraft, "Legacy typing")
        XCTAssertEqual(try repo.logs().first?.id, expected.2)
        XCTAssertEqual(try repo.logs().first?.responseMode, "typing")
        try repo.updateDraft(mode: .ordering, now: now)
        XCTAssertNotNil(try repo.presentation(now: now)?.ordering)
        XCTAssertEqual(try repo.cards().first?.id, expected.0)
    }
    private func makeV3(_ url: URL) throws -> (UUID, Data, UUID) {
        let schema = Schema(versionedSchema: StudySchemaV3.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration("Study", schema: schema, url: url, cloudKitDatabase: .none)])
        let repo = StudyRepository(container: container); try repo.initialize(now: now)
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "Legacy", answer: "I walk to school."), now: now)
        let card = try XCTUnwrap(repo.cards().first)
        let before = card.fsrsPayload
        let transition = try ReviewScheduler().review(repo.snapshot(card), grade: .good, now: now)
        let after = try JSONEncoder().encode(transition.after)
        let log = StudyReviewLog(card: card, transition: transition, before: before, after: after,
                                 mode: .typing, durationMs: 2000, wasNew: true, sequence: 1)
        try repo.transaction {
            repo.context.insert(log); card.fsrsPayload = after
            card.dueDate = try ReviewScheduler().summary(transition.after).dueDate
            let draft = SessionDraft(mode: .new, now: now)
            draft.cardID = card.id; draft.answerMode = "typing"; draft.typedDraft = "Legacy typing"
            repo.context.insert(draft)
        }
        return (card.id, card.fsrsPayload, log.id)
    }
}
