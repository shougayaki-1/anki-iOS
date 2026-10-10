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

    func testDeckLimitsInheritanceUndoMoveDeleteAndBackup() async throws {
        let repo = try fixture(), parent = try repo.decks()[0].id
        let child = try repo.createDeck(name: "Child", parentID: parent, now: now)
        let other = try repo.createDeck(name: "Other", now: now)
        try repo.saveDeckLearning(DeckLearningOverride(deckID: parent, newLimit: 1, retention: 0.85))
        try repo.saveDeckLearning(DeckLearningOverride(deckID: child, newLimit: 2, retention: 0.95))
        XCTAssertEqual(try repo.deckRetention(child), 0.95)
        XCTAssertEqual(try repo.deckRetention(other), try repo.settings().desiredRetention)
        for n in 0..<3 {
            try repo.createNote(NoteInput(deckID: child, question: "Q\(n)", answer: "A"), now: now)
        }
        XCTAssertEqual(try repo.homeSnapshot(now: now).counts.newRemaining, 1)
        try repo.start(mode: .new, now: now)
        try revealAndGrade(repo, grade: .good, date: now)
        XCTAssertEqual(try repo.homeSnapshot(now: now).counts.newRemaining, 0)
        XCTAssertTrue(try repo.presentation(now: now)?.emptyState?.message.contains("デッキまたは親デッキ") == true)
        let bytes = try repo.cards().map(\.fsrsPayload)
        try repo.saveDeckLearning(DeckLearningOverride(deckID: child, newLimit: 2, retention: nil))
        XCTAssertEqual(try repo.cards().map(\.fsrsPayload), bytes)
        XCTAssertEqual(try repo.deckRetention(child), 0.85)
        let archive = try BackupArchive.decode(await BackupService.export(repository: repo, now: now, appVersion: "test"))
        XCTAssertEqual(try JSONDecoder().decode(StudyOptions.self, from: archive.data.options[0].payload).deckNewUsage?.count, 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = MediaStore(root: root.appendingPathComponent("Media"))
        let restoredContainer = try BackupService.restore(archive,
            location: StudyStorageLocation(canonicalStore: root.appendingPathComponent("Study.store")), mediaStore: media, now: now)
        let restored = StudyRepository(container: restoredContainer, mediaStore: media)
        try restored.initialize(now: now)
        XCTAssertEqual(try restored.deckRetention(child), 0.85)
        XCTAssertEqual(try restored.homeSnapshot(now: now).counts.newRemaining, 0)
        try restored.undo(now: now)
        XCTAssertEqual(try restored.homeSnapshot(now: now).counts.newRemaining, 1)
        try repo.undo(now: now)
        XCTAssertEqual(try repo.homeSnapshot(now: now).counts.newRemaining, 1)
        try revealAndGrade(repo, grade: .easy, date: now)
        try repo.moveDeck(id: child, name: "Moved", parentID: other, now: now)
        XCTAssertEqual(try repo.deckRetention(child), try repo.settings().desiredRetention)
        XCTAssertEqual(try repo.homeSnapshot(now: now).counts.newRemaining, 1)
        try repo.deleteDeck(id: child, moveNotesTo: other, now: now)
        XCTAssertFalse(try repo.options().deckLearning!.contains { $0.deckID == child })
        XCTAssertEqual(try repo.options().deckNewUsage?.count, 1)
        _ = try await BackupService.export(repository: repo, now: now, appVersion: "after-delete")
    }

    func testDeckSettingsSaveFailureIsAtomicAndLimitsRejectInvalidValues() throws {
        let repo = try fixture(), id = try repo.decks()[0].id
        let before = try BackupData.capture(repo).canonical()
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.moveDeck(id: id, name: "Changed", parentID: nil,
            learning: DeckLearningOverride(deckID: id, newLimit: 0, retention: 0.97), now: now))
        XCTAssertEqual(try BackupData.capture(repo).canonical(), before)
        repo.save = { try $0.save() }
        XCTAssertThrowsError(try repo.saveDeckLearning(DeckLearningOverride(deckID: id, newLimit: -1)))
        XCTAssertThrowsError(try repo.saveDeckLearning(DeckLearningOverride(deckID: id, retention: 0.99)))
        try repo.saveDeckLearning(DeckLearningOverride(deckID: id, newLimit: 0))
        try create(repo)
        XCTAssertEqual(try repo.homeSnapshot(now: now).counts.newRemaining, 0)
        XCTAssertThrowsError(try repo.start(mode: .new, now: now))
    }

    func testAnotherSetUsesOriginalScopeAndLimitAndEmptyOrFailedStartKeepsUndo() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        let other = try repo.createDeck(name: "Other", now: now)
        for index in 0..<2 {
            try repo.createNote(NoteInput(deckID: deck, question: "Q\(index)", answer: "A"), now: now)
        }
        var options = try repo.options(); options.sessionAnswerLimit = 1
        try repo.updateOptions(options)
        try repo.start(mode: .new, scope: LearningScope(deckID: deck), now: now)
        try revealAndGrade(repo, grade: .easy, date: now)
        options = try repo.options(); options.sessionAnswerLimit = 30
        try repo.updateOptions(options)
        try repo.applyHomeScope(LearningScope(deckID: other))
        let before = try BackupData.capture(repo).canonical()
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.startAnotherSession(now: now))
        XCTAssertEqual(try BackupData.capture(repo).canonical(), before)
        repo.save = { try $0.save() }
        try repo.startAnotherSession(now: now)
        XCTAssertEqual(try repo.sessionProgress(), SessionAnswerProgress(answered: 0, limit: 1))
        XCTAssertEqual(try repo.scope().deckID, deck)
        XCTAssertEqual(try repo.homeScope().deckID, other)
        try revealAndGrade(repo, grade: .easy, date: now)
        let exhausted = try BackupData.capture(repo).canonical()
        XCTAssertThrowsError(try repo.startAnotherSession(now: now))
        XCTAssertEqual(try BackupData.capture(repo).canonical(), exhausted)
        XCTAssertTrue(try repo.presentation(now: now)?.canUndo == true)
    }

    func testSessionProgressSaveFailureRepeatsDayBoundaryLegacyAndBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = MediaStore(root: root.appendingPathComponent("Media"))
        let container = try PersistenceController.makeStudyContainer(storeURL: root.appendingPathComponent("Study.store"))
        let repo = StudyRepository(container: container, mediaStore: media)
        try repo.initialize(now: now)
        try create(repo)
        var options = try repo.options(); options.sessionAnswerLimit = 10
        try repo.updateOptions(options)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(revealed: true, now: now)
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.grade(.again, now: now))
        XCTAssertEqual(try repo.sessionProgress()?.answered, 0)
        XCTAssertTrue(try repo.logs().isEmpty)
        repo.save = { try $0.save() }
        try repo.grade(.again, now: now)
        let boundary = StudyDay(calendar: repo.calendar, startHour: 4).interval(containing: now).end
        try repo.resume(now: boundary)
        try revealAndGrade(repo, grade: .easy, date: boundary)
        XCTAssertEqual(try repo.sessionProgress()?.answered, 2)
        XCTAssertEqual(Set(try repo.logs().map(\.cardID)).count, 1)
        let backup = try BackupArchive.decode(await BackupService.export(repository: repo, now: boundary, appVersion: "audit"))
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("Restored.store"))
        let restoredContainer = try BackupService.restore(backup, location: location, mediaStore: media, now: boundary)
        let restored = StudyRepository(container: restoredContainer, mediaStore: media)
        try restored.initialize(now: boundary)
        XCTAssertEqual(try restored.sessionProgress(), SessionAnswerProgress(answered: 2, limit: 10))
        try restored.undo(now: boundary)
        XCTAssertEqual(try restored.sessionProgress()?.answered, 1)
        var invalid = backup.data
        options = try JSONDecoder().decode(StudyOptions.self, from: invalid.options[0].payload)
        options.activeSessionProgress?.startSequence = -1
        invalid.options[0].payload = try JSONEncoder().encode(options)
        XCTAssertThrowsError(try BackupValidation.validate(invalid, media: backup.media))
        options.activeSessionProgress = nil
        try restored.updateOptions(options)
        XCTAssertNotNil(try restored.session())
        XCTAssertNil(try restored.sessionProgress()) // Legacy session stays intact; no invented count.
    }

    func testSessionAnswerProgressTracksRemainingAndFinishesAt20RegardlessOfDailyGoal() throws {
        let repo = try fixture()
        var settings = try repo.settings()
        settings.dailyNewLimit = 30
        settings.dailyGoal = 1 // Already reached after the first answer; not the session limit.
        try repo.updateSettings(settings)
        for index in 0..<25 {
            try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "Q\(index)", answer: "A\(index)"), now: now)
        }
        try repo.start(mode: .new, now: now)
        XCTAssertEqual(try repo.presentation(now: now)?.sessionProgress?.remaining, 20)
        for index in 1...20 {
            try revealAndGrade(repo, grade: .easy, date: now.addingTimeInterval(TimeInterval(index)))
            let progress = try XCTUnwrap(repo.presentation(now: now)?.sessionProgress)
            XCTAssertEqual(progress.answered, index)
            XCTAssertEqual(progress.remaining, 20 - index)
            XCTAssertEqual(progress.isComplete, index == 20)
            if index == 1 { XCTAssertEqual(try repo.counts(now: now).learnedToday, 1) }
        }
        let finished = try XCTUnwrap(repo.presentation(now: now))
        XCTAssertNil(finished.card)
        XCTAssertEqual(finished.emptyState?.reason, .complete)
        XCTAssertEqual(try repo.logs().count, 20)
        XCTAssertTrue(finished.canUndo)
        try repo.undo(now: now)
        XCTAssertEqual(try repo.presentation(now: now)?.sessionProgress?.remaining, 1)
        XCTAssertNotNil(try repo.presentation(now: now)?.card)
        try revealAndGrade(repo, grade: .easy, date: now.addingTimeInterval(30))
        XCTAssertEqual(try repo.presentation(now: now)?.sessionProgress?.remaining, 0)
        try repo.completeSession(now: now)
        XCTAssertNil(try repo.session())
        XCTAssertNil(try repo.options().activeSessionProgress)
        XCTAssertEqual(try repo.logs().count, 20)
        // Today's unique-card goal has been met, but the next set starts at 0 / 20.
        try repo.start(mode: .new, now: now.addingTimeInterval(31))
        XCTAssertEqual(try repo.presentation(now: now)?.sessionProgress?.answered, 0)
        XCTAssertEqual(try repo.presentation(now: now)?.sessionProgress?.remaining, 20)
    }

    func testSessionAnswerProgressUsesConfirmedGradesNotCluesAndSurvivesResume() throws {
        let container = try PersistenceController.makeStudyContainer(inMemory: true)
        let first = StudyRepository(container: container)
        try first.initialize(now: now)
        try create(first)
        try first.start(mode: .new, now: now)
        try first.updateDraft(mode: .typing, text: "東京", revealed: true, now: now)
        XCTAssertEqual(try first.sessionProgress()?.answered, 0)
        try first.grade(.again, now: now)
        XCTAssertEqual(try first.sessionProgress()?.answered, 1)
        XCTAssertEqual(try first.sessionProgress()?.remaining, 19)
        try first.setSessionActive(false, now: now)
        let next = StudyRepository(container: container)
        try next.initialize(now: now)
        XCTAssertEqual(try next.sessionProgress()?.answered, 1)
        XCTAssertEqual(try next.presentation(now: now)?.sessionProgress?.remaining, 19)
        try next.undo(now: now)
        XCTAssertEqual(try next.sessionProgress()?.answered, 0)
        XCTAssertEqual(try next.sessionProgress()?.remaining, 20)
    }

    func testUnlimitedSessionShowsAnsweredOnlyAndDefaultChangesApplyToNextSet() throws {
        let repo = try fixture()
        try create(repo); try create(repo)
        var options = try repo.options()
        options.sessionAnswerLimit = 0 // unlimited
        try repo.updateOptions(options)
        try repo.start(mode: .new, now: now)
        var progress = try XCTUnwrap(repo.sessionProgress())
        XCTAssertEqual(progress.limit, 0)
        XCTAssertNil(progress.remaining)
        options = try repo.options()
        options.sessionAnswerLimit = 10
        try repo.updateOptions(options)
        try revealAndGrade(repo, grade: .easy, date: now)
        progress = try XCTUnwrap(repo.sessionProgress())
        XCTAssertEqual(progress.answered, 1)
        XCTAssertEqual(progress.limit, 0) // A running session is a snapshot.
        try revealAndGrade(repo, grade: .easy, date: now.addingTimeInterval(1))
        try repo.completeSession(now: now)
        try create(repo) // New material remains available in the next session.
        try repo.start(mode: .new, now: now.addingTimeInterval(2))
        XCTAssertEqual(try repo.sessionProgress()?.limit, 10)
        XCTAssertEqual(try repo.sessionProgress()?.answered, 0)
    }

    func testNewEasyLongTermDueIsModeExcludedAndOtherModesCanReview() throws {
        for bury in [true, false] {
            let repo = try fixture()
            var settings = try repo.settings(); settings.siblingBuryEnabled = bury
            try repo.updateSettings(settings)
            try create(repo); try repo.start(mode: .new, now: now)
            try revealAndGrade(repo, grade: .easy, date: now)
            let card = try XCTUnwrap(repo.cards().first)
            XCTAssertEqual(try ReviewScheduler().summary(repo.snapshot(card)).state, "review")
            let due = card.dueDate
            let id = try repo.session()?.id, undo = try repo.session()?.undoLogID
            let scope = try repo.scope()
            for date in [due, due.addingTimeInterval(86400)] {
                try repo.resume(now: date)
                let view = try XCTUnwrap(repo.presentation(now: date))
                XCTAssertNil(view.card)
                XCTAssertEqual(view.emptyState?.reason, .modeExcluded)
                XCTAssertTrue(view.emptyState?.message.contains("「復習する」") == true)
                XCTAssertTrue(view.canUndo)
                XCTAssertEqual(try repo.session()?.id, id)
                XCTAssertEqual(try repo.session()?.undoLogID, undo)
                XCTAssertEqual(try repo.scope(), scope)
            }
            // Reads do not change persisted state; resume only advances draft timing.
            let afterReads = try BackupData.capture(repo).canonical()
            _ = try repo.presentation(now: due)
            XCTAssertEqual(try BackupData.capture(repo).canonical(), afterReads)
            repo.save = { _ in throw Failure.save }
            XCTAssertThrowsError(try repo.completeSession(now: due))
            XCTAssertEqual(try BackupData.capture(repo).canonical(), afterReads)
            repo.save = { try $0.save() }
            try repo.undo(now: due)
            XCTAssertNotNil(try repo.presentation(now: due)?.card)
            try revealAndGrade(repo, grade: .easy, date: now)
            try repo.completeSession(now: due)
            XCTAssertThrowsError(try repo.undo(now: due))
            for mode in [StudyMode.review, .mixed] {
                try repo.start(mode: mode, now: due)
                XCTAssertEqual(try repo.presentation(now: due)?.card?.cardID, card.id)
            }
        }
    }

    func testSiblingCauseRequiresActualQueueBlockAndResetsAtDayBoundary() throws {
        let repo = try fixture()
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "Front", answer: "Back", reverseEnabled: true), now: now)
        try repo.start(mode: .new, now: now)
        try revealAndGrade(repo, grade: .easy, date: now)
        let boundary = StudyDay(calendar: repo.calendar, startHour: 4).interval(containing: now).end
        XCTAssertEqual(try repo.presentation(now: boundary.addingTimeInterval(-1))?.emptyState?.reason, .siblings)
        var settings = try repo.settings(); settings.siblingBuryEnabled = false
        try repo.updateSettings(settings)
        XCTAssertEqual(try repo.presentation(now: now)?.emptyState?.reason, .retry)
        try repo.resume(now: now)
        XCTAssertNotNil(try repo.presentation(now: now)?.card)
        try repo.undo(now: now)
        try repo.updateSettings(StudySettings())
        try revealAndGrade(repo, grade: .easy, date: now)
        XCTAssertEqual(try repo.presentation(now: now)?.emptyState?.reason, .siblings)
        XCTAssertEqual(try repo.presentation(now: boundary)?.emptyState?.reason, .retry)
        try repo.resume(now: boundary)
        XCTAssertNotNil(try repo.presentation(now: boundary)?.card)
    }

    func testCombinedQuotaAndSiblingRulesAreNotFalselyAttributed() throws {
        let repo = try fixture()
        var settings = try repo.settings(); settings.dailyNewLimit = 1
        try repo.updateSettings(settings)
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "Front", answer: "Back", reverseEnabled: true), now: now)
        try repo.start(mode: .new, now: now)
        try revealAndGrade(repo, grade: .easy, date: now)
        XCTAssertEqual(try repo.presentation(now: now)?.emptyState?.reason, .retry)
        settings.siblingBuryEnabled = false; try repo.updateSettings(settings)
        XCTAssertEqual(try repo.presentation(now: now)?.emptyState?.reason, .newLimit)
        settings.dailyNewLimit = 2; try repo.updateSettings(settings)
        XCTAssertEqual(try repo.presentation(now: now)?.emptyState?.reason, .retry)
        try repo.resume(now: now)
        XCTAssertNotNil(try repo.presentation(now: now)?.card)
    }

    func testNewSessionExcludesUntouchedShortReviewEvenWhenDue() throws {
        let repo = try fixture(); try create(repo)
        try repo.start(mode: .new, now: now)
        try revealAndGrade(repo, grade: .again, date: now)
        let shortDue = try XCTUnwrap(repo.presentation(now: now)?.nextShortDue)
        try repo.completeSession(now: now)
        try create(repo); try repo.start(mode: .new, now: now)
        try revealAndGrade(repo, grade: .easy, date: now)
        let view = try XCTUnwrap(repo.presentation(now: shortDue))
        XCTAssertNil(view.nextShortDue)
        XCTAssertEqual(view.emptyState?.reason, .complete)
        try repo.resume(now: shortDue)
        XCTAssertNil(try repo.presentation(now: shortDue)?.card)
        try repo.completeSession(now: shortDue)
        try repo.start(mode: .review, now: shortDue)
        XCTAssertNotNil(try repo.presentation(now: shortDue)?.card)
    }

    func testFutureUntouchedReviewIsWaitingRatherThanCompleted() throws {
        let repo = try fixture(); try create(repo); try create(repo)
        try repo.start(mode: .new, now: now)
        try revealAndGrade(repo, grade: .easy, date: now)
        try revealAndGrade(repo, grade: .easy, date: now.addingTimeInterval(3600))
        let firstDue = try XCTUnwrap(repo.cards().map(\.dueDate).min())
        try repo.start(mode: .review, now: firstDue)
        try revealAndGrade(repo, grade: .easy, date: firstDue)
        XCTAssertEqual(try repo.presentation(now: firstDue)?.emptyState?.reason, .reviewWaiting)
        XCTAssertNil(try repo.presentation(now: firstDue)?.nextShortDue)
    }

    func testNumericSettingsBoundariesPersistenceAndFailure() throws {
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
        let repo = store.repository
        for _ in 0..<12 { try create(repo) }
        try store.reload()
        for limit in [200, 10, 0, 500] {
            XCTAssertTrue(store.updateSettings { $0.dailyNewLimit = limit })
            XCTAssertEqual(store.counts.newRemaining, min(limit, 12))
            XCTAssertEqual(try repo.settings().dailyNewLimit, limit)
        }
        for goal in [200, 1, 500] {
            XCTAssertTrue(store.updateSettings { $0.dailyGoal = goal })
            XCTAssertEqual(try repo.settings().dailyGoal, goal)
        }
        for hour in [0, 23, 4] {
            XCTAssertTrue(store.updateSettings { $0.dayStartHour = hour })
            XCTAssertEqual(try repo.settings().dayStartHour, hour)
        }
        let before = try BackupData.capture(repo).canonical()
        for edit: (inout StudySettings) -> Void in [
            { $0.dailyNewLimit = 501 }, { $0.dailyNewLimit = -1 },
            { $0.dailyGoal = 0 }, { $0.dailyGoal = 501 },
            { $0.dayStartHour = 24 }, { $0.desiredRetention = 0.98 }
        ] {
            var value = store.settings; edit(&value)
            XCTAssertThrowsError(try repo.updateSettings(value))
            XCTAssertEqual(try BackupData.capture(repo).canonical(), before)
        }
        repo.save = { _ in throw Failure.save }
        XCTAssertFalse(store.updateSettings { $0.dailyNewLimit = 200 })
        XCTAssertEqual(store.settings.dailyNewLimit, 500)
        XCTAssertEqual(try BackupData.capture(repo).canonical(), before)
        XCTAssertNotNil(store.failure)
    }

    func testRetentionEditsPreserveScheduleAndHistory() throws {
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
        let repo = store.repository
        try create(repo)
        store.start(.new); store.draft(revealed: true); store.grade(.easy)
        let cards = try repo.cards().map { ($0.id, $0.dueDate, $0.fsrsPayload) }
        let logs = try repo.logs().map(\.id)
        for percent in [80, 90, 97] {
            XCTAssertTrue(store.updateSettings { $0.desiredRetention = Double(percent) / 100 })
            XCTAssertEqual(store.settings.desiredRetention, Double(percent) / 100)
            XCTAssertEqual(try repo.logs().map(\.id), logs)
            let after = try repo.cards()
            XCTAssertEqual(after.map(\.id), cards.map { $0.0 })
            XCTAssertEqual(after.map(\.dueDate), cards.map { $0.1 })
            XCTAssertEqual(after.map(\.fsrsPayload), cards.map { $0.2 })
        }
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

    func testWaitingHomeRefreshWritesOnlyWhenDueAndRollsBackFailedSave() throws {
        var date = now
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { date })
        let repo = store.repository
        try create(repo)
        store.start(.new)
        try revealAndGrade(repo, grade: .again, date: date)
        store.pause()
        let next = try XCTUnwrap(store.review?.nextShortDue)
        let id = try repo.session()?.id, undo = try repo.session()?.undoLogID
        let scope = try repo.scope(), logs = try repo.logs().map(\.id)
        let before = try BackupData.capture(repo).canonical()
        var saves = 0
        repo.save = { context in saves += 1; try context.save() }
        for offset in 1...3 {
            date = now.addingTimeInterval(Double(offset) * 15)
            store.refreshHome()
        }
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(try BackupData.capture(repo).canonical(), before)
        XCTAssertEqual(store.nextHomeRefresh, next)
        let empty = try repo.createDeck(name: "Different home scope", now: date)
        XCTAssertTrue(store.applyScope(LearningScope(deckID: empty)))
        saves = 0
        date = next
        repo.save = { _ in saves += 1; throw Failure.save }
        store.refreshHome()
        XCTAssertEqual(saves, 1)
        XCTAssertNotNil(store.homeFailure)
        XCTAssertNil(try repo.session()?.cardID)
        XCTAssertEqual(try repo.session()?.id, id)
        XCTAssertEqual(try repo.session()?.undoLogID, undo)
        XCTAssertEqual(try repo.scope(), scope)
        XCTAssertEqual(try repo.logs().map(\.id), logs)
        repo.save = { context in saves += 1; try context.save() }
        store.sceneChanged(active: true)
        XCTAssertEqual(saves, 2)
        XCTAssertEqual(store.homePrimaryAction, .resume(.new))
        XCTAssertEqual(store.counts.due, 0)
        XCTAssertEqual(try repo.session()?.id, id)
        XCTAssertEqual(try repo.session()?.undoLogID, undo)
        XCTAssertNil(try repo.session()?.activeSince)
        XCTAssertEqual(try repo.scope(), scope)
        XCTAssertEqual(try repo.logs().map(\.id), logs)
        store.refreshHome()
        XCTAssertEqual(saves, 2)
        store.resume(); store.undo()
        XCTAssertEqual(try repo.logs().count, 0)
    }

    func testHomeRefreshKeepsTypedRevealedDraftAndUndoWithoutSaving() throws {
        var date = now
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { date })
        let repo = store.repository
        try create(repo); try create(repo)
        store.start(.new)
        try revealAndGrade(repo, grade: .easy, date: date)
        try repo.updateDraft(mode: .typing, text: "keep typing", revealed: true, now: date)
        store.pause()
        let before = try BackupData.capture(repo).canonical()
        let undo = try repo.session()?.undoLogID
        var saves = 0
        repo.save = { context in saves += 1; try context.save() }
        date = date.addingTimeInterval(45)
        store.refreshHome(); store.sceneChanged(active: true)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(try BackupData.capture(repo).canonical(), before)
        XCTAssertEqual(store.review?.typedDraft, "keep typing")
        XCTAssertEqual(store.review?.answerRevealed, true)
        XCTAssertEqual(try repo.session()?.undoLogID, undo)
    }

    func testEmptySessionSelectsNewCardAtStudyDayBoundaryWithOneSave() throws {
        var date = now
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { date })
        let repo = store.repository
        try create(repo); try create(repo)
        var settings = try repo.settings(); settings.dailyNewLimit = 1
        try repo.updateSettings(settings)
        store.start(.new)
        try revealAndGrade(repo, grade: .easy, date: date)
        store.pause()
        XCTAssertNil(try repo.session()?.cardID)
        let id = try repo.session()?.id, undo = try repo.session()?.undoLogID
        let boundary = StudyDay(calendar: repo.calendar, startHour: settings.dayStartHour).interval(containing: date).end
        XCTAssertEqual(store.nextHomeRefresh, boundary)
        var saves = 0
        repo.save = { context in saves += 1; try context.save() }
        date = boundary.addingTimeInterval(-1)
        store.refreshHome()
        XCTAssertEqual(saves, 0)
        date = boundary
        store.refreshHome()
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(store.homePrimaryAction, .resume(.new))
        XCTAssertEqual(try repo.session()?.id, id)
        XCTAssertEqual(try repo.session()?.undoLogID, undo)
        XCTAssertEqual(try repo.logs().count, 1)
        XCTAssertEqual(store.counts.newRemaining, 1)
        store.refreshHome()
        XCTAssertEqual(saves, 1)
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
    func testBackgroundStatisticsReaderKeepsDeletedHistoryAndRespectsDeckScope() async throws {
        let container = try PersistenceController.makeStudyContainer(inMemory: true)
        let repo = StudyRepository(container: container)
        try repo.initialize(now: now)
        let root = try XCTUnwrap(repo.decks().first).id
        let child = try repo.createDeck(name: "Child", parentID: root, now: now)
        let other = try repo.createDeck(name: "Other", now: now)
        let noteID = try repo.createNote(NoteInput(deckID: child, question: "Q", answer: "A"), now: now)
        try repo.start(mode: .new, scope: LearningScope(deckID: child), now: now)
        try revealAndGrade(repo, grade: .easy, date: now.addingTimeInterval(3))

        let reader = StatisticsReader(container: container)
        let calendar = Calendar.current
        let all = try await reader.load(now: now.addingTimeInterval(60), calendar: calendar,
                                        startHour: 4, scope: LearningScope())
        let descendant = try await reader.load(now: now.addingTimeInterval(60), calendar: calendar,
                                               startHour: 4, scope: LearningScope(deckID: root))
        let excluded = try await reader.load(now: now.addingTimeInterval(60), calendar: calendar,
                                             startHour: 4, scope: LearningScope(deckID: other))
        XCTAssertEqual(all.days[0].answers, 1)
        XCTAssertEqual(descendant.days[0].answers, 1)
        XCTAssertEqual(excluded.days[0].answers, 0)

        try repo.deleteNote(id: noteID)
        let orphan = try await reader.load(now: now.addingTimeInterval(60), calendar: calendar,
                                           startHour: 4, scope: LearningScope())
        let orphanScoped = try await reader.load(now: now.addingTimeInterval(60), calendar: calendar,
                                                 startHour: 4, scope: LearningScope(deckID: root))
        XCTAssertEqual(orphan.days[0].answers, 1)
        XCTAssertEqual(orphan.unattributedAnswers, 1)
        XCTAssertEqual(orphanScoped.days[0].answers, 0)
    }

}
