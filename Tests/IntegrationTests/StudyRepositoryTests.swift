import XCTest
import SwiftData
@testable import AnkiIOS

@MainActor
final class StudyRepositoryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    enum Failure: Error { case save }

    func fixture() throws -> StudyRepository {
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true))
        try repo.initialize(now: now)
        return repo
    }
    @discardableResult
    func create(_ repo: StudyRepository, kind: NoteKind = .basic, mode: ResponseMode = .mental) throws -> UUID {
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, kind: kind, question: "日本の首都は？",
                                      answer: "東京", explanation: "首都", responseMode: mode), now: now)
    }
    func revealAndGrade(_ repo: StudyRepository, grade: ReviewGrade, date: Date) throws {
        try repo.updateDraft(revealed: true, now: date)
        try repo.grade(grade, now: date)
    }

    func testEmptyStartNeverCreatesOrReplacesSession() throws {
        let repo = try fixture()
        for mode in StudyMode.allCases {
            XCTAssertThrowsError(try repo.start(mode: mode, now: now))
            XCTAssertNil(try repo.session())
        }
        try create(repo); try repo.start(mode: .new, now: now)
        try repo.updateDraft(mode: .typing, text: "keep", revealed: true, now: now)
        let empty = try repo.createDeck(name: "Empty", now: now)
        let before = try BackupData.capture(repo).canonical()
        for mode in StudyMode.allCases {
            XCTAssertThrowsError(try repo.start(mode: mode, scope: LearningScope(deckID: empty), now: now))
            XCTAssertEqual(try BackupData.capture(repo).canonical(), before)
        }
    }
    func testHomeModeAvailabilityWaitingQuotaGoalAndDayBoundary() throws {
        var date = now
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { date })
        let repo = store.repository
        XCTAssertFalse(store.canStart(.mixed))
        try create(repo); try store.reload()
        XCTAssertFalse(store.canStart(.review)); XCTAssertTrue(store.canStart(.new)); XCTAssertTrue(store.canStart(.mixed))
        var settings = try repo.settings(); settings.dailyNewLimit = 1; settings.dailyGoal = 1
        try repo.updateSettings(settings)
        try repo.start(mode: .new, now: date); try revealAndGrade(repo, grade: .again, date: date)
        try store.reload()
        XCTAssertFalse(store.canStart(.mixed)); XCTAssertNotNil(store.nextShortDue)
        XCTAssertEqual(store.counts.learnedToday, 1)
        XCTAssertTrue(store.newAvailabilityMessage.contains("上限"))
        date = try XCTUnwrap(store.nextShortDue)
        try store.reload()
        XCTAssertTrue(store.canStart(.review)); XCTAssertTrue(store.canStart(.mixed)); XCTAssertFalse(store.canStart(.new))
        XCTAssertEqual(store.mixedAvailabilityMessage, "今は復習カードを学習します。")
        try create(repo)
        date = StudyDay(calendar: repo.calendar, startHour: settings.dayStartHour).interval(containing: date).end
        try store.reload()
        XCTAssertEqual(store.counts.learnedToday, 0); XCTAssertTrue(store.canStart(.new))
        store.homeFailure = "failure"; XCTAssertFalse(store.canStart(.mixed))
    }

    func testCRUDMaintainsCardIdentityAndHistoryAndModes() throws {
        let repo = try fixture()
        let noteID = try create(repo)
        let cardID = try XCTUnwrap(repo.cards().first?.id)
        try repo.start(mode: .new, now: now)
        try revealAndGrade(repo, grade: .easy, date: now.addingTimeInterval(3))
        let saved = try XCTUnwrap(repo.cards().first?.fsrsPayload)
        try repo.updateNote(id: noteID, input: NoteInput(deckID: repo.decks()[0].id, kind: .written,
                                                       question: "日本の首都を記述", answer: "東京", responseMode: .typing), now: now)
        XCTAssertEqual(try repo.cards().first?.id, cardID)
        XCTAssertEqual(try repo.cards().first?.fsrsPayload, saved)
        XCTAssertEqual(try repo.logs().count, 1)
        XCTAssertEqual(try repo.noteItems().first?.responseMode, .typing)
        try repo.deleteNote(id: noteID)
        XCTAssertTrue(try repo.cards().isEmpty)
        XCTAssertTrue(try repo.notes().isEmpty)
        XCTAssertEqual(try repo.logs().count, 1)
        XCTAssertEqual(try repo.counts(now: now.addingTimeInterval(4)).learnedToday, 1)
    }

    func testEveryGradePersistsFSRSAndLogWithExactTime() throws {
        for grade in ReviewGrade.allCases {
            let repo = try fixture(); try create(repo)
            try repo.start(mode: .new, now: now)
            let card = try XCTUnwrap(repo.cards().first)
            let before = card.fsrsPayload
            let answerDate = now.addingTimeInterval(7)
            try revealAndGrade(repo, grade: grade, date: answerDate)
            let log = try XCTUnwrap(repo.logs().first)
            XCTAssertEqual(log.grade, grade.rawValue)
            XCTAssertEqual(log.reviewedAt, answerDate)
            XCTAssertEqual(log.fsrsBefore, before)
            XCTAssertEqual(log.fsrsAfter, card.fsrsPayload)
            XCTAssertEqual(log.durationMs, 7000)
            XCTAssertEqual(log.algorithmVersion, "FSRS-6")
            XCTAssertEqual(try ReviewScheduler().summary(repo.snapshot(card)).lastReview, answerDate)
            XCTAssertEqual(try ReviewScheduler().summary(repo.snapshot(card)).dueDate, card.dueDate)
        }
    }

    func testUndoRestoresAllStateAndAllowsRegrade() throws {
        let repo = try fixture(); try create(repo)
        try repo.start(mode: .new, now: now)
        let card = try XCTUnwrap(repo.cards().first)
        let before = card.fsrsPayload, oldDue = card.dueDate, oldUpdate = card.updatedAt
        try repo.updateDraft(mode: .typing, text: "とうきょう", revealed: true, now: now)
        try repo.grade(.good, now: now.addingTimeInterval(2))
        XCTAssertEqual(try repo.counts(now: now.addingTimeInterval(3)).learnedToday, 1)
        try repo.undo(now: now.addingTimeInterval(3))
        XCTAssertEqual(card.fsrsPayload, before)
        XCTAssertEqual(card.dueDate, oldDue)
        XCTAssertEqual(card.updatedAt, oldUpdate)
        XCTAssertTrue(try repo.logs().isEmpty)
        XCTAssertEqual(try repo.presentation(now: now)?.card?.cardID, card.id)
        XCTAssertEqual(try repo.presentation(now: now)?.responseMode, .typing)
        XCTAssertEqual(try repo.presentation(now: now)?.typedDraft, "")
        XCTAssertEqual(try repo.counts(now: now).learnedToday, 0)
        try revealAndGrade(repo, grade: .again, date: now.addingTimeInterval(4))
        XCTAssertEqual(try repo.logs().count, 1)
        XCTAssertThrowsError(try repo.grade(.easy, now: now)) // no revealed current card
    }

    func testFailedGradeAndUndoRollbackEverything() throws {
        let repo = try fixture(); try create(repo)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(mode: .typing, text: "draft", revealed: true, now: now)
        let card = try XCTUnwrap(repo.cards().first)
        let before = card.fsrsPayload
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.grade(.good, now: now.addingTimeInterval(1)))
        XCTAssertEqual(try repo.cards().first?.fsrsPayload, before)
        XCTAssertTrue(try repo.logs().isEmpty)
        XCTAssertEqual(try repo.session()?.cardID, card.id)
        XCTAssertEqual(try repo.session()?.typedDraft, "draft")
        XCTAssertEqual(try repo.session()?.answerRevealed, true)
        repo.save = { try $0.save() }
        try repo.grade(.good, now: now.addingTimeInterval(2))
        let after = try XCTUnwrap(repo.cards().first?.fsrsPayload)
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.undo(now: now.addingTimeInterval(3)))
        XCTAssertEqual(try repo.cards().first?.fsrsPayload, after)
        XCTAssertEqual(try repo.logs().count, 1)
        repo.save = { try $0.save() }
        try repo.undo(now: now.addingTimeInterval(4))
        XCTAssertEqual(try repo.cards().first?.fsrsPayload, before)
    }

    func testNewQuotaPersistsAcrossModesAndDecksAndCountsRepeatedCardOnce() throws {
        let repo = try fixture()
        var settings = try repo.settings(); settings.dailyNewLimit = 1
        try repo.updateSettings(settings)
        try create(repo)
        let deck2 = try repo.createDeck(name: "別デッキ", now: now)
        try repo.createNote(NoteInput(deckID: deck2, question: "Q2", answer: "A2"), now: now.addingTimeInterval(1))
        try repo.start(mode: .new, now: now)
        try revealAndGrade(repo, grade: .again, date: now.addingTimeInterval(2))
        XCTAssertEqual(try repo.counts(now: now.addingTimeInterval(2)).newRemaining, 0)
        try repo.resume(now: now.addingTimeInterval(62))
        XCTAssertNotNil(try repo.presentation(now: now.addingTimeInterval(62))?.card)
        try revealAndGrade(repo, grade: .good, date: now.addingTimeInterval(62))
        XCTAssertEqual(try repo.counts(now: now.addingTimeInterval(62)).learnedToday, 1)
        XCTAssertEqual(try repo.counts(now: now.addingTimeInterval(62)).answerCount, 2)
        for mode in StudyMode.allCases {
            XCTAssertThrowsError(try repo.start(mode: mode, now: now.addingTimeInterval(63)))
            XCTAssertNil(try repo.presentation(now: now.addingTimeInterval(63))?.card)
        }
        try repo.start(mode: .new, now: now.addingTimeInterval(86400))
        XCTAssertNotNil(try repo.presentation(now: now.addingTimeInterval(86400))?.card)
    }

    func testDiskRestartRestoresDueHistoryAndUnscoredDraft() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("study.store")
        let expected = try writeAndClose(url: url)
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: url))
        try repo.initialize(now: now.addingTimeInterval(20))
        let card = try XCTUnwrap(repo.cards().first)
        XCTAssertEqual(card.id, expected.id)
        XCTAssertEqual(card.fsrsPayload, expected.payload)
        XCTAssertEqual(card.dueDate, expected.due)
        XCTAssertEqual(try repo.logs().count, 1)
        XCTAssertEqual(try repo.presentation(now: now)?.typedDraft, "未確定")
        XCTAssertEqual(try repo.presentation(now: now)?.responseMode, .typing)
        XCTAssertEqual(try repo.session()?.activeSince, nil)
        try repo.resume(now: now.addingTimeInterval(30))
        try repo.undo(now: now.addingTimeInterval(31))
        XCTAssertTrue(try repo.logs().isEmpty)
    }

    private func writeAndClose(url: URL) throws -> (id: UUID, payload: Data, due: Date) {
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: url))
        try repo.initialize(now: now); try create(repo, kind: .written, mode: .typing)
        try repo.start(mode: .new, now: now)
        try revealAndGrade(repo, grade: .again, date: now.addingTimeInterval(2))
        try repo.resume(now: now.addingTimeInterval(62))
        try repo.updateDraft(mode: .typing, text: "未確定", now: now.addingTimeInterval(63))
        try repo.setSessionActive(false, now: now.addingTimeInterval(64))
        let card = try XCTUnwrap(repo.cards().first)
        return (card.id, card.fsrsPayload, card.dueDate)
    }

    func testInvalidContentAndFailedCreationLeaveNoPartialRecords() throws {
        let repo = try fixture()
        XCTAssertThrowsError(try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "", answer: "answer"), now: now))
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try create(repo))
        XCTAssertTrue(try repo.notes().isEmpty)
        XCTAssertTrue(try repo.cards().isEmpty)
    }
}
