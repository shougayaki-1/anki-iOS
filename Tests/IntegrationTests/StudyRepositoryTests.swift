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

    func testReviewEmptyCompletionUndoAndAtomicFailure() throws {
        for mode in StudyMode.allCases {
            var date = now
            let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { date })
            let repo = store.repository
            try create(repo)
            if mode == .review {
                try repo.start(mode: .new, now: date)
                try revealAndGrade(repo, grade: .easy, date: date)
                date = try XCTUnwrap(repo.cards().first?.dueDate)
            }
            store.start(mode)
            store.draft(revealed: true); store.grade(.easy)
            XCTAssertEqual(store.review?.emptyState?.reason, .complete)
            XCTAssertTrue(store.review?.canUndo == true)
            store.undo()
            XCTAssertNotNil(store.review?.card)
            store.draft(revealed: true); store.grade(.easy)
            let before = try BackupData.capture(repo).canonical()
            repo.save = { _ in throw Failure.save }
            store.completeSession()
            XCTAssertTrue(store.showingReview)
            XCTAssertEqual(try BackupData.capture(repo).canonical(), before)
            repo.save = { try $0.save() }
            let payload = try repo.cards().first?.fsrsPayload, logs = try repo.logs().map(\.id)
            store.completeSession()
            XCTAssertFalse(store.showingReview)
            XCTAssertNil(try repo.session())
            XCTAssertTrue(try repo.context.fetch(FetchDescriptor<SessionScope>()).isEmpty)
            XCTAssertEqual(try repo.cards().first?.fsrsPayload, payload)
            XCTAssertEqual(try repo.logs().map(\.id), logs)
            XCTAssertThrowsError(try repo.undo(now: date))
        }
    }

    func testEmptySessionSettingsFailureAndRefreshFailureStayRecoverable() throws {
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
        let repo = store.repository
        try create(repo); store.start(.new)
        store.draft(revealed: true); store.grade(.easy)
        let before = try BackupData.capture(repo).canonical()
        repo.save = { _ in throw Failure.save }
        var settings = store.settings; settings.dailyNewLimit = 20
        XCTAssertFalse(store.perform { try repo.updateSettings(settings) })
        XCTAssertEqual(try BackupData.capture(repo).canonical(), before)
        store.refreshQueue()
        XCTAssertTrue(store.reviewRefreshFailed)
        XCTAssertNotNil(try repo.session())
        repo.save = { try $0.save() }
        store.refreshQueue()
        XCTAssertFalse(store.reviewRefreshFailed)
        XCTAssertEqual(store.review?.emptyState?.reason, .complete)
    }

    func testWaitingCanFinishAndStartReviewAtDeadline() throws {
        let repo = try fixture(); try create(repo)
        try repo.start(mode: .new, now: now)
        try revealAndGrade(repo, grade: .again, date: now)
        let presentation = try XCTUnwrap(repo.presentation(now: now))
        XCTAssertEqual(presentation.emptyState?.reason, .waiting)
        let due = try XCTUnwrap(presentation.nextShortDue)
        try repo.completeSession(now: now)
        XCTAssertNil(try repo.session())
        try repo.start(mode: .review, now: due)
        XCTAssertNotNil(try repo.presentation(now: due)?.card)
    }

    func testSessionEmptyReasonsUseOriginalScopeAndStudyDay() throws {
        let repo = try fixture()
        for _ in 0..<11 { try create(repo) }
        try repo.start(mode: .new, now: now)
        for _ in 0..<10 { try revealAndGrade(repo, grade: .easy, date: now) }
        XCTAssertEqual(try repo.presentation(now: now)?.emptyState?.reason, .newLimit)
        XCTAssertTrue(try repo.presentation(now: now)?.emptyState?.message.contains("あと1枚") == true)
        let empty = try repo.createDeck(name: "Empty", now: now)
        try repo.applyHomeScope(LearningScope(deckID: empty))
        XCTAssertEqual(try repo.presentation(now: now)?.emptyState?.reason, .newLimit)
        let boundary = StudyDay(calendar: repo.calendar, startHour: 4).interval(containing: now).end
        XCTAssertEqual(try repo.presentation(now: boundary.addingTimeInterval(-1))?.emptyState?.reason, .newLimit)
        XCTAssertEqual(try repo.presentation(now: boundary)?.emptyState?.reason, .retry)
        try repo.resume(now: boundary)
        XCTAssertNotNil(try repo.presentation(now: boundary)?.card)
    }

    func testEmptyScopeSuspensionAndSiblingReasons() throws {
        let repo = try fixture(); try create(repo)
        try repo.start(mode: .new, now: now)
        let card = try XCTUnwrap(repo.cards().first)
        try repo.setSuspended(cardID: card.id, value: true, now: now)
        XCTAssertEqual(try repo.presentation(now: now)?.emptyState?.reason, .suspended)
        try repo.deleteNote(id: card.noteID)
        XCTAssertEqual(try repo.presentation(now: now)?.emptyState?.reason, .noTargets)
        try repo.completeSession(now: now)
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "Front", answer: "Back", reverseEnabled: true), now: now)
        try repo.start(mode: .new, now: now)
        try revealAndGrade(repo, grade: .easy, date: now)
        XCTAssertEqual(try repo.presentation(now: now)?.emptyState?.reason, .siblings)
    }

    func testHomePrimaryActionPreservesEveryInterruptedModeAndOriginalScope() throws {
        for mode in StudyMode.allCases {
            let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
            let repo = store.repository
            try create(repo)
            if mode == .review {
                try repo.start(mode: .new, now: now)
                try revealAndGrade(repo, grade: .easy, date: now)
                let card = try XCTUnwrap(repo.cards().first)
                // A due review fixture without changing scheduler payload semantics.
                store.clock = { card.dueDate.addingTimeInterval(1) }
            }
            let date = store.clock()
            try repo.start(mode: mode, now: date)
            try repo.updateDraft(mode: .typing, text: "preserved", revealed: true, now: date)
            try repo.setSessionActive(false, now: date)
            let empty = try repo.createDeck(name: "Other scope", now: date)
            try repo.applyHomeScope(LearningScope(deckID: empty))
            try store.reload()
            XCTAssertEqual(store.homePrimaryAction, .resume(mode))
            XCTAssertEqual(store.counts.due, 0)
            let before = try XCTUnwrap(repo.session())
            let id = before.id, cardID = before.cardID, undo = before.undoLogID
            let scope = try repo.scope(), logs = try repo.logs().map(\.id)
            store.resume()
            XCTAssertTrue(store.showingReview)
            XCTAssertEqual(try repo.session()?.id, id)
            XCTAssertEqual(try repo.session()?.cardID, cardID)
            XCTAssertEqual(try repo.session()?.typedDraft, "preserved")
            XCTAssertEqual(try repo.session()?.answerRevealed, true)
            XCTAssertEqual(try repo.session()?.undoLogID, undo)
            XCTAssertEqual(try repo.scope(), scope)
            XCTAssertEqual(try repo.logs().map(\.id), logs)
        }
    }

    func testHomePrimaryActionWaitingDueAndCompletionKeepHistory() throws {
        var date = now
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { date })
        let repo = store.repository
        XCTAssertEqual(store.homePrimaryAction, .addCards)
        try create(repo); try store.reload()
        XCTAssertEqual(store.homePrimaryAction, .start(.new, 1))
        store.start(.new)
        try revealAndGrade(repo, grade: .again, date: date)
        store.pause()
        let next = try XCTUnwrap(store.review?.nextShortDue)
        XCTAssertEqual(store.homePrimaryAction, .waiting(next))
        let id = try repo.session()?.id, undo = try repo.session()?.undoLogID
        date = next
        store.refreshHome()
        XCTAssertEqual(store.homePrimaryAction, .resume(.new))
        XCTAssertEqual(try repo.session()?.id, id)
        XCTAssertEqual(try repo.session()?.undoLogID, undo)
        XCTAssertFalse(store.showingReview)
        XCTAssertThrowsError(try repo.completeSession(now: date))
        store.resume()
        try revealAndGrade(repo, grade: .easy, date: date)
        store.pause()
        XCTAssertEqual(store.homePrimaryAction, .complete)
        let logs = try repo.logs().map(\.id), payload = try repo.cards().first?.fsrsPayload
        store.completeSession()
        XCTAssertNil(try repo.session())
        XCTAssertEqual(try repo.logs().map(\.id), logs)
        XCTAssertEqual(try repo.cards().first?.fsrsPayload, payload)
        XCTAssertEqual(store.homePrimaryAction, .unavailable)
        date = try XCTUnwrap(repo.cards().first?.dueDate)
        store.refreshHome()
        XCTAssertEqual(store.homePrimaryAction, .start(.review, 1))
    }

    func testHomePrimaryActionUnavailableForQuotaFilterAndFailure() throws {
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
        let repo = store.repository
        try create(repo)
        var settings = try repo.settings(); settings.dailyNewLimit = 0
        try repo.updateSettings(settings); try store.reload()
        XCTAssertEqual(store.homePrimaryAction, .unavailable)
        XCTAssertTrue(store.newAvailabilityMessage.contains("上限"))
        settings.dailyNewLimit = 10; try repo.updateSettings(settings)
        let empty = try repo.createDeck(name: "Empty", now: now)
        try repo.applyHomeScope(LearningScope(deckID: empty)); try store.reload()
        XCTAssertEqual(store.homePrimaryAction, .unavailable)
        XCTAssertTrue(store.newAvailabilityMessage.contains("ほかの学習対象"))
        try repo.applyHomeScope(LearningScope()); try store.reload()
        XCTAssertEqual(store.homePrimaryAction, .start(.new, 1))
        store.homeFailure = "read failure"
        XCTAssertEqual(store.homePrimaryAction, .unavailable)
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
        XCTAssertTrue(store.newAvailabilityMessage.contains("短期復習"))
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

    func testNewLimitChangesPreserveCardsAndSharedHistory() throws {
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
        let repo = store.repository
        for _ in 0..<200 { try create(repo) }
        for index in 0..<10 {
            try repo.start(mode: index.isMultiple(of: 2) ? .new : .mixed, now: now)
            try revealAndGrade(repo, grade: .easy, date: now)
        }
        try store.reload()
        XCTAssertTrue(store.isNewLimitReached)
        XCTAssertEqual(store.counts.totalNew, 190)
        XCTAssertTrue(store.newLimitRemainingMessage.contains("190枚"))
        XCTAssertTrue(store.newAvailabilityMessage.contains("10枚"))
        let logs = try repo.logs().map(\.id)
        let cards = try repo.cards().map(\.id)
        var settings = store.settings
        settings.dailyNewLimit = 30; settings.dailyGoal = 1
        XCTAssertTrue(store.perform { try repo.updateSettings(settings) })
        XCTAssertEqual(store.counts.newRemaining, 20)
        XCTAssertTrue(store.canStart(.new))
        settings.dailyNewLimit = 5
        XCTAssertTrue(store.perform { try repo.updateSettings(settings) })
        XCTAssertEqual(store.counts.newRemaining, 0)
        XCTAssertEqual(try repo.logs().map(\.id), logs)
        XCTAssertEqual(try repo.cards().map(\.id), cards)
        let empty = try repo.createDeck(name: "Empty", now: now)
        XCTAssertTrue(store.applyScope(LearningScope(deckID: empty)))
        XCTAssertFalse(store.isNewLimitReached)
        XCTAssertTrue(store.newAvailabilityMessage.contains("ほかの学習対象"))
        XCTAssertTrue(store.applyScope(LearningScope()))
        settings.dayStartHour = 16
        XCTAssertTrue(store.perform { try repo.updateSettings(settings) })
        XCTAssertEqual(store.studyDayBoundaryMessage, "学習日の切替：午後4時")
    }

    func testNewLimitDoesNotMaskBurySuspensionOrEmptyScope() throws {
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
        store.newSlotsRemaining = 0
        XCTAssertFalse(store.isNewLimitReached)
        XCTAssertEqual(store.newAvailabilityMessage, "未学習カードはありません。")
        store.counts = HomeCounts(totalNew: 2, eligibleNew: 0)
        XCTAssertFalse(store.isNewLimitReached)
        XCTAssertTrue(store.newAvailabilityMessage.contains("同日抑制"))
        store.counts = HomeCounts(suspendedNew: 2)
        XCTAssertFalse(store.isNewLimitReached)
        XCTAssertTrue(store.newAvailabilityMessage.contains("停止中"))
        store.counts = HomeCounts(totalNew: 2, eligibleNew: 1, suspendedNew: 3)
        store.globalCounts = HomeCounts(totalNew: 10)
        store.scope = LearningScope(deckID: UUID())
        XCTAssertTrue(store.isNewLimitReached)
        XCTAssertTrue(store.newLimitRemainingMessage.contains("全デッキ"))
        XCTAssertTrue(store.newLimitRemainingMessage.contains("フィルター内は2枚"))
        XCTAssertTrue(store.newLimitRemainingMessage.contains("うち1枚"))
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
