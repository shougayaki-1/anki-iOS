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
    func testCelebrationWaitsForSuccessfulCompletionAndClaimsOnce() throws {
        let repo = try fixture()
        try create(repo)
        var settings = try repo.settings(); settings.dailyGoal = 1
        try repo.updateSettings(settings)
        let store = try StudyStore(container: repo.context.container, clock: { self.now })
        try store.repository.start(mode: .new, answerLimit: 1, now: now)
        store.resume(); store.draft(revealed: true); store.grade(.easy)
        XCTAssertNil(store.celebration)
        XCTAssertEqual(store.pendingCelebrationCount, 3)
        XCTAssertTrue(store.review?.canUndo == true)
        store.presentCelebration() // Even an explicit request cannot interrupt review.
        XCTAssertNil(store.celebration)
        store.pause()
        XCTAssertFalse(store.celebrationRequested)
        store.resume(); store.undo()
        XCTAssertEqual(store.pendingCelebrationCount, 0)
        store.draft(revealed: true); store.grade(.easy)
        store.repository.save = { _ in throw Failure.save }
        store.completeSession()
        XCTAssertTrue(store.showingReview)
        XCTAssertFalse(store.celebrationRequested)
        XCTAssertNil(store.celebration)
        store.repository.save = { try $0.save() }
        store.completeSession()
        XCTAssertFalse(store.showingReview)
        XCTAssertTrue(store.celebrationRequested)
        XCTAssertNil(store.celebration) // Review's onDismiss owns presentation.
        store.presentCelebration()
        XCTAssertEqual(store.celebration?.primary.kind, .dailyGoalReached)
        XCTAssertEqual(store.celebration?.events.count, 3)
        XCTAssertEqual(store.celebration?.secondary.count, 1) // First study and day 1 overlap.
        XCTAssertEqual(store.pendingCelebrationCount, 0)
        store.celebration = nil; store.presentCelebration()
        XCTAssertNil(store.celebration)
        let restarted = try StudyStore(container: repo.context.container, clock: { self.now })
        restarted.presentCelebration()
        XCTAssertNil(restarted.celebration)
        XCTAssertFalse(restarted.canContinueAfterCelebration)
    }

    func testCelebrationGoalMidSessionAndExhaustedQueueBelowLimit() throws {
        let repo = try fixture()
        for _ in 0..<4 { try create(repo) }
        var settings = try repo.settings(); settings.dailyGoal = 3; try repo.updateSettings(settings)
        let store = try StudyStore(container: repo.context.container, clock: { self.now })
        store.start(.new)
        for _ in 0..<3 { store.draft(revealed: true); store.grade(.easy) }
        XCTAssertTrue(store.showingReview)
        XCTAssertNotNil(store.review?.card)
        XCTAssertNil(store.celebration)
        XCTAssertFalse(store.celebrationRequested)
        XCTAssertTrue(try store.repository.pendingAchievementEvents().contains { $0.kind == .dailyGoalReached })
        store.draft(revealed: true); store.grade(.easy)
        XCTAssertEqual(store.review?.emptyState?.reason, .complete)
        XCTAssertFalse(store.review!.sessionProgress!.isComplete) // Exhausted before answer limit.
        store.completeSession(); XCTAssertTrue(store.celebrationRequested)
        store.presentCelebration()
        XCTAssertEqual(store.celebration?.primary.record.value, 3)
        XCTAssertEqual(store.celebration?.primary.record.threshold, 3)
        XCTAssertFalse(store.canContinueAfterCelebration)
    }

    func testCelebrationContinueCreatesOneNewSessionAfterCompletedSet() throws {
        let repo = try fixture(); try create(repo); try create(repo)
        let store = try StudyStore(container: repo.context.container, clock: { self.now })
        try store.repository.start(mode: .new, answerLimit: 1, now: now)
        store.resume(); store.draft(revealed: true); store.grade(.easy)
        store.completeSession(); store.presentCelebration()
        XCTAssertTrue(store.canContinueAfterCelebration)
        XCTAssertNil(try store.repository.session())
        store.celebration = nil // Cover dismissal precedes continuation.
        store.startRecommended()
        XCTAssertTrue(store.showingReview)
        XCTAssertNotNil(store.review?.card)
        XCTAssertEqual(try store.repository.context.fetchCount(FetchDescriptor<SessionDraft>()), 1)
        XCTAssertFalse(store.celebrationRequested)
    }

    func testCelebrationWaitingAndZeroCardsNeverForcePresentation() throws {
        let repo = try fixture(); try create(repo)
        let store = try StudyStore(container: repo.context.container, clock: { self.now })
        store.start(.new); store.draft(revealed: true); store.grade(.again)
        XCTAssertEqual(store.review?.emptyState?.reason, .waiting)
        store.completeSession()
        XCTAssertFalse(store.celebrationRequested)
        XCTAssertNil(store.celebration)
        store.presentCelebration() // Manual home action may confirm saved achievements.
        XCTAssertNotNil(store.celebration)
        XCTAssertFalse(store.canContinueAfterCelebration)
        let empty = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
        empty.start(.new); empty.presentCelebration()
        XCTAssertNil(empty.celebration)
        XCTAssertFalse(empty.canContinueAfterCelebration)
    }

    func testCelebrationPartialClaimAndPendingAfterRestart() throws {
        let repo = try fixture(); try create(repo)
        var settings = try repo.settings(); settings.dailyGoal = 1; try repo.updateSettings(settings)
        try repo.start(mode: .new, answerLimit: 1, now: now)
        try repo.updateDraft(revealed: true, now: now); try repo.grade(.easy, now: now)
        let store = try StudyStore(container: repo.context.container, clock: { self.now })
        XCTAssertNil(store.celebration) // Restart must not automatically replay pending events.
        store.refreshPendingCelebrations(); XCTAssertEqual(store.pendingCelebrationCount, 3)
        var saves = 0
        store.repository.save = { context in
            saves += 1
            if saves == 2 { throw Failure.save }
            try context.save()
        }
        store.presentCelebration()
        XCTAssertEqual(store.celebration?.events.count, 1)
        XCTAssertEqual(store.pendingCelebrationCount, 2)
        store.repository.save = { try $0.save() }
        let restarted = try StudyStore(container: repo.context.container, clock: { self.now })
        restarted.presentCelebration()
        XCTAssertEqual(restarted.celebration?.events.count, 2)
        XCTAssertTrue(Set(store.celebration!.events.map(\.id)).isDisjoint(with: Set(restarted.celebration!.events.map(\.id))))
    }

    func testCelebrationPrioritiesAndVisualContent() {
        func event(_ kind: AchievementKind, _ value: Int, _ threshold: Int = 1) -> AchievementEvent {
            AchievementEvent(record: AchievementRecord(id: "\(kind.rawValue)-\(value)", kind: kind,
                studyDay: "2026-10-14", threshold: threshold, value: value, occurredAt: now,
                sourceLogID: UUID(), timeZoneID: "Asia/Tokyo", startHour: 4))
        }
        let first = event(.firstStudyToday, 1), normal = event(.streakAdvanced, 12), milestone = event(.streakAdvanced, 7)
        let goal = event(.dailyGoalReached, 20, 20), mature = event(.matureMilestone, 100, 100)
        XCTAssertEqual(CelebrationSummary(events: [first])?.headline, "今日も一歩、\n積み重ねました")
        XCTAssertFalse(CelebrationSummary(events: [normal])!.isSpecial)
        XCTAssertTrue(CelebrationSummary(events: [milestone])!.isSpecial)
        XCTAssertEqual(CelebrationSummary(events: [goal])?.unit, "/ 20 枚")
        XCTAssertTrue(CelebrationSummary(events: [mature])!.detail.contains("FSRS Stability"))
        XCTAssertEqual(CelebrationSummary(events: [first, normal, goal, milestone, milestone])?.events.count, 4)
        XCTAssertEqual(CelebrationSummary(events: [first, normal, goal, milestone])?.primary, milestone)
        XCTAssertEqual(CelebrationSummary(events: [first, normal, goal])?.primary, goal)
        XCTAssertEqual(CelebrationSummary(events: [first, normal])?.secondary.count, 0)
        XCTAssertNil(CelebrationSummary(events: []))
    }

    func testAchievementsSaveFailureUndoRestartAndClaim() throws {
        let repo = try fixture()
        try create(repo)
        var settings = try repo.settings(); settings.dailyGoal = 1
        try repo.updateSettings(settings)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(revealed: true, now: now)
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.grade(.again, now: now))
        XCTAssertTrue(try repo.pendingAchievementEvents().isEmpty)
        XCTAssertFalse(try repo.achievementProgress(now: now).studiedToday)
        repo.save = { try $0.save() }
        try repo.grade(.again, now: now)
        let pending = try repo.pendingAchievementEvents()
        XCTAssertEqual(Set(pending.map(\.kind)), [.firstStudyToday, .streakAdvanced, .dailyGoalReached])
        XCTAssertEqual(try repo.achievementProgress(now: now).uniqueCardsToday, 1)
        let restarted = StudyRepository(container: repo.context.container, calendar: repo.calendar)
        XCTAssertEqual(try restarted.pendingAchievementEvents().map(\.id), pending.map(\.id))
        try repo.undo(now: now)
        XCTAssertTrue(try repo.pendingAchievementEvents().isEmpty)
        XCTAssertEqual(try repo.achievementProgress(now: now).currentStreak, 0)
        try revealAndGrade(repo, grade: .again, date: now)
        let event = try XCTUnwrap(repo.pendingAchievementEvents().first)
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.claimAchievementEvent(id: event.id, now: now))
        repo.save = { try $0.save() }
        XCTAssertNotNil(try repo.claimAchievementEvent(id: event.id, now: now))
        XCTAssertNil(try repo.claimAchievementEvent(id: event.id, now: now))
        let afterClaim = StudyRepository(container: repo.context.container, calendar: repo.calendar)
        XCTAssertNil(try afterClaim.claimAchievementEvent(id: event.id, now: now))
        try repo.undo(now: now)
        XCTAssertFalse(try repo.achievementProgress(now: now).studiedToday)
        try revealAndGrade(repo, grade: .again, date: now)
        XCTAssertFalse(try repo.pendingAchievementEvents().contains { $0.id == event.id })
    }

    func testDailyGoalCountsUniqueCardsRatherThanTwentyAnswers() throws {
        let repeated = try fixture()
        try create(repeated)
        try repeated.start(mode: .new, answerLimit: 0, now: now)
        for index in 0..<20 {
            let date = now.addingTimeInterval(Double(index * 120))
            if index > 0 { try repeated.resume(now: date) }
            try revealAndGrade(repeated, grade: .again, date: date)
        }
        XCTAssertEqual(try repeated.logs().count, 20)
        XCTAssertEqual(try repeated.achievementProgress(now: now.addingTimeInterval(2400)).uniqueCardsToday, 1)
        XCTAssertFalse(try repeated.pendingAchievementEvents().contains { $0.kind == .dailyGoalReached })

        let unique = try fixture()
        for _ in 0..<21 { try create(unique) }
        var settings = try unique.settings(); settings.dailyNewLimit = 30; settings.dailyGoal = 20
        try unique.updateSettings(settings)
        try unique.start(mode: .new, answerLimit: 20, now: now)
        for _ in 0..<20 { try revealAndGrade(unique, grade: .easy, date: now) }
        XCTAssertEqual(try unique.achievementProgress(now: now).uniqueCardsToday, 20)
        XCTAssertEqual(try unique.pendingAchievementEvents().filter { $0.kind == .dailyGoalReached }.count, 1)
        try unique.startAnotherSession(now: now)
        try revealAndGrade(unique, grade: .easy, date: now)
        XCTAssertEqual(try unique.achievementProgress(now: now).uniqueCardsToday, 21)
        XCTAssertEqual(try unique.pendingAchievementEvents().filter { $0.kind == .dailyGoalReached }.count, 1)
    }

    func testMatureMilestoneCrossingUndoAndImportedBaseline() throws {
        let repo = try fixture(), scheduler = try ReviewScheduler()
        let matureDeck = try repo.createDeck(name: "既存定着", now: now)
        for index in 0..<9 {
            try repo.createNote(NoteInput(deckID: matureDeck, question: "M\(index)", answer: "A"), now: now)
        }
        let candidateNote = try create(repo)
        let candidate = try XCTUnwrap(repo.cards().first { $0.noteID == candidateNote })
        let base = try scheduler.review(scheduler.newCard(now: now), grade: .easy, now: now).after
        try repo.transaction {
            for card in try repo.cards() {
                var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: base.cardData) as? [String: Any])
                raw["stability"] = card.id == candidate.id ? 20.0 : 21.0
                let state = SchedulerSnapshot(schemaVersion: base.schemaVersion, algorithmVersion: base.algorithmVersion,
                    cardData: try JSONSerialization.data(withJSONObject: raw))
                card.fsrsPayload = try JSONEncoder().encode(state)
                card.dueDate = try scheduler.summary(state).dueDate
            }
        }
        XCTAssertEqual(try repo.matureCardCount(), 9)
        let date = now.addingTimeInterval(100 * 86400)
        try repo.start(mode: .review, scope: LearningScope(deckID: repo.decks()[0].id), now: date)
        XCTAssertEqual(try repo.session()?.cardID, candidate.id)
        try revealAndGrade(repo, grade: .easy, date: date)
        XCTAssertEqual(try repo.matureCardCount(), 10)
        let event = try XCTUnwrap(repo.pendingAchievementEvents().first { $0.kind == .matureMilestone })
        XCTAssertEqual(event.record.threshold, 10)
        try repo.undo(now: date)
        XCTAssertEqual(try repo.matureCardCount(), 9)
        XCTAssertFalse(try repo.pendingAchievementEvents().contains { $0.kind == .matureMilestone })
        try revealAndGrade(repo, grade: .easy, date: date)
        XCTAssertNotNil(try repo.claimAchievementEvent(id: event.id, now: date))
        try repo.undo(now: date)
        try revealAndGrade(repo, grade: .easy, date: date)
        XCTAssertFalse(try repo.pendingAchievementEvents().contains { $0.kind == .matureMilestone })
        // Installing over already mature/imported cards silently establishes a baseline.
        var options = try repo.options(); options.achievements = nil; options.matureAchievementBaseline = nil
        try repo.updateOptions(options)
        try repo.initialize(now: date)
        XCTAssertEqual(try repo.options().matureAchievementBaseline, [10])
        XCTAssertTrue(try repo.pendingAchievementEvents().isEmpty)
    }

    func testAchievementsGoalChangesAndLegacyHistoryRestore() throws {
        let repo = try fixture()
        try create(repo)
        var settings = try repo.settings(); settings.dailyGoal = nil
        try repo.updateSettings(settings)
        try repo.start(mode: .new, now: now)
        try revealAndGrade(repo, grade: .good, date: now)
        XCTAssertFalse(try repo.pendingAchievementEvents().contains { $0.kind == .dailyGoalReached })
        settings.dailyGoal = 1; try repo.updateSettings(settings)
        XCTAssertFalse(try repo.pendingAchievementEvents().contains { $0.kind == .dailyGoalReached })
        // Simulate an old backup: original FSRS/Card IDs and logs, no achievement JSON.
        var options = try repo.options(); options.achievements = nil
        try repo.updateOptions(options)
        let restarted = StudyRepository(container: repo.context.container, calendar: repo.calendar)
        XCTAssertEqual(try restarted.achievementProgress(now: now).currentStreak, 1)
        XCTAssertEqual(try restarted.achievementProgress(now: now).longestStreak, 1)
        XCTAssertTrue(try restarted.pendingAchievementEvents().isEmpty)
        XCTAssertEqual(try restarted.logs().count, 1)
        let oldJSON = Data("{\"schemaVersion\":2,\"siblingBuryEnabled\":true}".utf8)
        XCTAssertNil(try JSONDecoder().decode(StudyOptions.self, from: oldJSON).achievements)
    }

    func testRecommendationStartRevalidatesAndPreservesDraftAndUndo() throws {
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
        try create(store.repository)
        try store.reload()
        XCTAssertEqual(store.homeRecommendation?.mode, .new)
        let noteFetches = store.repository.queueNoteFetchCount
        store.startRecommended()
        XCTAssertEqual(store.repository.queueNoteFetchCount - noteFetches, 1)
        let id = try XCTUnwrap(store.review?.card?.cardID)
        store.draft(text: "keep", revealed: true)
        store.startRecommended()
        XCTAssertEqual(store.review?.card?.cardID, id)
        XCTAssertEqual(store.review?.typedDraft, "keep")
        store.grade(.good)
        let logCount = try store.repository.context.fetchCount(FetchDescriptor<StudyReviewLog>())
        store.startRecommended()
        XCTAssertEqual(try store.repository.context.fetchCount(FetchDescriptor<StudyReviewLog>()), logCount)
        store.undo()
        XCTAssertEqual(store.review?.card?.cardID, id)
    }

    func testHomeScopeMembershipCacheRechecksEditsTransactionsAndRollback() throws {
        let repo = try fixture()
        try create(repo)
        let note = try XCTUnwrap(repo.notes().first)
        let originalDeck = note.deckID
        let otherDeck = try repo.createDeck(name: "Other", now: now)
        let scope = LearningScope(deckID: originalDeck)
        let fetches = repo.queueNoteFetchCount
        XCTAssertEqual(try repo.queueScopeNoteIDs(scope), [note.id])
        XCTAssertEqual(try repo.queueScopeNoteIDs(scope), [note.id])
        XCTAssertEqual(repo.queueNoteFetchCount - fetches, 1)

        // Pending edits bypass the clean snapshot and never overwrite it.
        note.deckID = otherDeck
        XCTAssertTrue(try repo.queueScopeNoteIDs(scope).isEmpty)
        repo.context.rollback()
        XCTAssertEqual(try repo.queueScopeNoteIDs(scope), [note.id])

        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.transaction {
            note.deckID = otherDeck
            XCTAssertTrue(try repo.queueScopeNoteIDs(scope).isEmpty)
        })
        XCTAssertEqual(try repo.queueScopeNoteIDs(scope), [note.id])
        repo.save = { try $0.save() }
        try repo.updateNote(id: note.id, input: NoteInput(deckID: otherDeck, question: "Moved", answer: "A"), now: now)
        XCTAssertTrue(try repo.queueScopeNoteIDs(scope).isEmpty)
        XCTAssertEqual(try repo.queueScopeNoteIDs(LearningScope(deckID: otherDeck)), [note.id])
        try repo.deleteNote(id: note.id)
        XCTAssertTrue(try repo.queueScopeNoteIDs(LearningScope(deckID: otherDeck)).isEmpty)
    }

    func testPauseResumeReusesQueueNotesAndKeepsDraftOnSaveFailure() throws {
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
        let repo = store.repository
        try create(repo)
        try store.reload()
        store.startRecommended()
        store.draft(mode: .typing, text: "keep")
        let id = try XCTUnwrap(store.review?.card?.cardID)
        let payload = try XCTUnwrap(repo.card(id)?.fsrsPayload)
        let beforePause = repo.queueNoteFetchCount
        store.pause()
        XCTAssertEqual(repo.queueNoteFetchCount - beforePause, 1)
        XCTAssertFalse(store.showingReview)
        XCTAssertEqual(try repo.session()?.typedDraft, "keep")
        let beforeResume = repo.queueNoteFetchCount
        store.resume()
        XCTAssertEqual(repo.queueNoteFetchCount - beforeResume, 1)
        XCTAssertTrue(store.showingReview)
        XCTAssertEqual(store.review?.card?.cardID, id)
        XCTAssertEqual(store.review?.typedDraft, "keep")

        repo.save = { _ in throw Failure.save }
        store.pause()
        XCTAssertTrue(store.showingReview)
        XCTAssertEqual(try repo.session()?.cardID, id)
        XCTAssertEqual(try repo.session()?.typedDraft, "keep")
        XCTAssertEqual(try repo.card(id)?.fsrsPayload, payload)
        XCTAssertTrue(try repo.logs().isEmpty)
        repo.save = { try $0.save() }
        store.pause()
        repo.save = { _ in throw Failure.save }
        store.resume()
        XCTAssertFalse(store.showingReview)
        XCTAssertEqual(try repo.session()?.cardID, id)
        XCTAssertEqual(try repo.session()?.typedDraft, "keep")
        XCTAssertEqual(try repo.card(id)?.fsrsPayload, payload)
        XCTAssertTrue(try repo.logs().isEmpty)
        repo.save = { try $0.save() }
        let card = try XCTUnwrap(repo.card(id))
        let deck = try XCTUnwrap(repo.note(card.noteID)?.deckID)
        try repo.setStudyPaused(deckID: deck, paused: true, now: now)
        store.resume()
        XCTAssertFalse(store.showingReview)
        XCTAssertEqual(try repo.session()?.typedDraft, "keep")
        try repo.setStudyPaused(deckID: deck, paused: false, now: now)
        store.resume()
        XCTAssertTrue(store.showingReview)
        XCTAssertEqual(store.review?.card?.cardID, id)
        XCTAssertEqual(store.review?.typedDraft, "keep")
    }

    func testRecommendationUsesRiskOnlyForBacklogAndRechecksSettings() throws {
        func reviewStore() throws -> StudyStore {
            let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
            let repo = store.repository, deck = try repo.decks()[0].id
            for index in 0..<21 { try repo.createNote(NoteInput(deckID: deck, question: "Q\(index)", answer: "A"), now: now) }
            let scheduler = try ReviewScheduler()
            let past = now.addingTimeInterval(-864000)
            let transition = try scheduler.review(scheduler.newCard(now: past), grade: .easy, now: past)
            try repo.transaction {
                for card in try repo.cards() { card.fsrsPayload = try JSONEncoder().encode(transition.after); card.dueDate = now }
            }
            try store.reload()
            return store
        }
        let store = try reviewStore(), repo = store.repository
        XCTAssertEqual(store.homeRecommendation?.policy, .forgettingRisk)
        store.startRecommended()
        XCTAssertEqual(try repo.options().activeSessionProgress?.reviewOrderPolicy, .forgettingRisk)
        XCTAssertEqual(try repo.options().activeSessionProgress?.initialEligibleCount, 21)
        let manual = try reviewStore()
        manual.start(.review)
        XCTAssertEqual(try manual.repository.options().activeSessionProgress?.reviewOrderPolicy, .traditional)
        let changed = try reviewStore()
        var options = try changed.repository.options(); options.sessionAnswerLimit = 0
        try changed.repository.updateOptions(options)
        changed.startRecommended()
        XCTAssertNil(try changed.repository.session())
        XCTAssertNotNil(changed.noteSaveNotice)
        XCTAssertEqual(changed.homeRecommendation?.policy, .traditional)
        changed.startRecommended()
        XCTAssertEqual(try changed.repository.sessionProgress()?.limit, 21)
        XCTAssertEqual(try changed.repository.options().activeSessionProgress?.reviewOrderPolicy, .traditional)
    }

    func testRecommendationTimeCacheScopeAndThreeThousandCardHome() async throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        let scheduler = try ReviewScheduler()
        let transition = try scheduler.review(scheduler.newCard(now: now), grade: .easy, now: now)
        let payload = try JSONEncoder().encode(transition.after)
        let due = try scheduler.summary(transition.after).dueDate
        try repo.transaction {
            for index in 0..<3000 {
                let input = NoteInput(deckID: deck, question: "Q\(index)", answer: "A")
                let note = Note(input: input, content: try StudyRepository.encodeContent(input), now: now)
                repo.context.insert(note)
                let card = StudyCard(noteID: note.id, variantKey: "basic:front", payload: payload, now: now)
                card.dueDate = due; repo.context.insert(card)
                if index == 0 {
                    for sequence in 1...10000 {
                        let row = StudyReviewLog(card: card, transition: transition, before: payload, after: payload,
                            mode: .mental, durationMs: sequence <= 5 ? 24000 : 0, wasNew: false, sequence: sequence)
                        row.reviewedAt = due
                        repo.context.insert(row)
                    }
                }
            }
        }
        let date = due.addingTimeInterval(86400), cards = try repo.queueCards()
        let logs = try repo.todayQueueLogs(cards: cards, settings: repo.settings(), now: date)
        let before = repo.fullHistoryFetchCount, decodes = repo.queueStateDecodeCount
        let cold = Date(), snapshot = try repo.homeSnapshot(now: date, cards: cards, logs: logs)
        let coldSeconds = Date().timeIntervalSince(cold)
        XCTAssertEqual(snapshot.counts.due, 3000)
        XCTAssertEqual(snapshot.medianAnswerSeconds, 24)
        let fetches = repo.homeAnswerTimeFetchCount, warm = Date()
        for _ in 0..<5 { XCTAssertEqual(try repo.homeSnapshot(now: date, cards: cards, logs: logs), snapshot) }
        let warmSeconds = Date().timeIntervalSince(warm) / 5
        XCTAssertEqual(repo.homeAnswerTimeFetchCount, fetches)
        XCTAssertEqual(repo.fullHistoryFetchCount, before)
        XCTAssertEqual(repo.queueStateDecodeCount, decodes)
        let scoped = try repo.homeAnswerMedian(cardIDs: [], now: date, day: snapshot.dayStart)
        XCTAssertNil(scoped)
        XCTAssertNil(try repo.homeAnswerMedian(cardIDs: Set(cards.map(\.id)), responseMode: .typing, now: date, day: snapshot.dayStart))
        _ = try repo.homeSnapshot(now: date.addingTimeInterval(86400), cards: cards, logs: [])
        XCTAssertEqual(repo.homeAnswerTimeFetchCount, fetches + 1)
        repo.calendar.timeZone = TimeZone(secondsFromGMT: 3600)!
        _ = try repo.homeSnapshot(now: date.addingTimeInterval(86400), cards: cards, logs: [])
        XCTAssertEqual(repo.homeAnswerTimeFetchCount, fetches + 2)
        // Reuse the existing 3,000-card / 10,000-log fixture for the records tab.
        let store = try StudyStore(container: repo.context.container, clock: { date })
        let mainActorFetches = store.repository.fullHistoryFetchCount
        store.refreshStatistics()
        XCTAssertEqual(store.repository.fullHistoryFetchCount, mainActorFetches)
        for _ in 0..<1000 {
            if !store.statisticsLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.statisticsLoading)
        XCTAssertNil(store.statisticsError)
        XCTAssertEqual(store.repository.fullHistoryFetchCount, mainActorFetches)
        XCTAssertEqual(store.achievementProgress?.longestStreak, 1)
        XCTAssertEqual(store.statistics?.ratings.values.reduce(0, +), 10000)
        XCTAssertEqual(store.achievementHistory, [])
        print("Issue187 3000 cards / 10000 logs cold=\(coldSeconds)s warm=\(warmSeconds)s historyFetches=0 extraDecodes=0")
    }

    func testTodayQueueLogsMatchLegacyQuotaFallbackAndExcludeOldHistory() throws {
        let repo = try fixture(), parent = try repo.decks()[0].id
        let child = try repo.createDeck(name: "Child", parentID: parent, now: now)
        try repo.createNote(NoteInput(deckID: child, question: "Q", answer: "A", reverseEnabled: true), now: now)
        let card = try XCTUnwrap(repo.cards().first)
        let scheduler = try ReviewScheduler()
        let transition = try scheduler.review(scheduler.newCard(now: now), grade: .good, now: now)
        let after = try JSONEncoder().encode(transition.after)
        try repo.transaction {
            for index in 0..<3 {
                let row = StudyReviewLog(card: card, transition: transition, before: card.fsrsPayload, after: after,
                                         mode: .mental, durationMs: 100, wasNew: true, sequence: index + 1)
                row.reviewedAt = index == 0 ? now.addingTimeInterval(-86400) : now
                repo.context.insert(row)
            }
            // One entry has a saved historical quota; another is a legacy log
            // requiring the current deck fallback. Keep even deleted deck IDs.
            var options = try repo.options()
            options.deckNewUsage = [DeckNewUsage(sequence: 2, cardID: card.id, quotaDeckIDs: [UUID()])]
            try repo.writeOptionsInTransaction(options)
        }
        let cards = try repo.queueCards(), settings = try repo.settings()
        let day = StudyDay(calendar: repo.calendar, startHour: settings.dayStartHour).interval(containing: now)
        let expected = try repo.queueLogs().filter { $0.reviewedAt >= day.start && $0.reviewedAt < day.end }
        let actual = try repo.todayQueueLogs(cards: cards, settings: settings, now: now)
        XCTAssertEqual(actual.count, 2)
        func signature(_ rows: [QueueLog]) -> [String] {
            rows.map { "\($0.cardID)|\($0.noteID?.uuidString ?? "")|\($0.quotaDeckIDs.map(\.uuidString).joined(separator: ","))" }.sorted()
        }
        XCTAssertEqual(signature(actual), signature(expected))
        XCTAssertEqual(try repo.counts(now: now), ReviewQueueBuilder(calendar: repo.calendar).counts(cards: cards, logs: expected, settings: settings, now: now))
    }
    func testTypedDraftDebouncesOneHundredCharactersAndKeepsRefreshText() async throws {
        let baseline = try fixture()
        try create(baseline, mode: .typing)
        try baseline.start(mode: .new, now: now)
        var oldSaves = 0
        baseline.save = { context in oldSaves += 1; try context.save() }
        let baselineStart = Date()
        for count in 1...100 { try baseline.updateDraft(text: String(repeating: "あ", count: count), now: now) }
        let baselineMs = Date().timeIntervalSince(baselineStart) * 1000
        XCTAssertEqual(oldSaves, 100)
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
        try create(store.repository, mode: .typing)
        store.start(.new)
        var saves = 0
        store.repository.save = { context in saves += 1; try context.save() }
        let started = Date()
        for count in 1...100 { store.draft(text: String(repeating: "あ", count: count)) }
        let bufferedMs = Date().timeIntervalSince(started) * 1000
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(store.review?.typedDraft.count, 100)
        XCTAssertEqual(try store.repository.session()?.typedDraft, "")
        try store.reload()
        XCTAssertEqual(store.review?.typedDraft.count, 100)
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try store.repository.session()?.typedDraft.count, 100)
        print("TYPED_DRAFT characters=100 old_saves=\(oldSaves) new_saves=\(saves) old_input_ms=\(baselineMs) new_input_ms=\(bufferedMs) debounce_ms=600")
    }

    func testPreparedSwipeKeepsRevealGradeFailureAndUndoSemantics() throws {
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
        try create(store.repository)
        store.start(.new)
        let id = try XCTUnwrap(store.review?.card?.cardID)
        let before = try store.repository.card(id)?.fsrsPayload
        store.repository.save = { _ in throw Failure.save }
        store.draft(revealed: true, swipePrepared: true)
        XCTAssertFalse(store.review?.answerRevealed == true)
        XCTAssertNotNil(store.failure)
        store.repository.save = { try $0.save() }
        store.draft(revealed: true, swipePrepared: true)
        XCTAssertTrue(store.review?.answerRevealed == true)
        store.repository.save = { _ in throw Failure.save }
        store.grade(.good, swipePrepared: true)
        XCTAssertEqual(store.review?.card?.cardID, id)
        XCTAssertEqual(try store.repository.card(id)?.fsrsPayload, before)
        XCTAssertTrue(try store.repository.logs().isEmpty)
        store.repository.save = { try $0.save() }
        store.grade(.good, swipePrepared: true)
        XCTAssertEqual(try store.repository.logs().count, 1)
        store.undo()
        XCTAssertEqual(store.review?.card?.cardID, id)
        XCTAssertEqual(try store.repository.card(id)?.fsrsPayload, before)
        XCTAssertTrue(try store.repository.logs().isEmpty)
    }

    func testTypedDraftFailureKeepsInputBlocksGradeAndRetries() throws {
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
        try create(store.repository, mode: .typing)
        try store.repository.updateTypedAnswerPolicy(TypedAnswerPolicy(enabled: true, retentionDays: 30), now: now)
        store.start(.new)
        let id = try XCTUnwrap(store.review?.card?.cardID)
        store.draft(revealed: true)
        store.draft(text: "最新の日本語")
        store.repository.save = { _ in throw Failure.save }
        store.grade(.good)
        XCTAssertTrue(store.typedDraftSaveFailed)
        XCTAssertEqual(store.review?.typedDraft, "最新の日本語")
        XCTAssertEqual(store.review?.card?.cardID, id)
        XCTAssertTrue(try store.repository.logs().isEmpty)
        XCTAssertEqual(try store.repository.session()?.typedDraft, "")
        store.repository.save = { try $0.save() }
        XCTAssertTrue(store.flushTypedDraft())
        XCTAssertFalse(store.typedDraftSaveFailed)
        XCTAssertNil(store.failure)
        XCTAssertEqual(try store.repository.session()?.typedDraft, "最新の日本語")
        store.grade(.good)
        XCTAssertEqual(try store.repository.logs().count, 1)
        XCTAssertEqual(try store.repository.savedTypedAnswers(now: now).first?.answer, "最新の日本語")
        store.undo()
        XCTAssertEqual(store.review?.typedDraft, "")
        XCTAssertTrue(try store.repository.savedTypedAnswers(now: now).isEmpty)
    }

    func testTypedDraftBoundariesAndOldTaskNeverRestorePreviousCardText() async throws {
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
        try create(store.repository, mode: .typing); try create(store.repository, mode: .typing)
        store.start(.new)
        store.draft(text: "変換途中")
        store.sceneChanged(active: false)
        XCTAssertEqual(try store.repository.session()?.typedDraft, "変換途中")
        store.sceneChanged(active: true)
        store.draft(text: "確定回答")
        store.draft(revealed: true)
        XCTAssertEqual(try store.repository.session()?.typedDraft, "確定回答")
        let first = store.review?.card?.cardID
        store.grade(.easy)
        XCTAssertNotEqual(store.review?.card?.cardID, first)
        store.draft(text: "次カード")
        store.pause()
        XCTAssertEqual(try store.repository.session()?.typedDraft, "次カード")
        store.resume()
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertEqual(store.review?.typedDraft, "次カード")
        store.undo()
        XCTAssertEqual(store.review?.card?.cardID, first)
        XCTAssertEqual(store.review?.typedDraft, "")
    }
    func testCachedStatisticsHistoryFutureLogsBackwardClockAndDayBoundary() async throws {
        let container = try PersistenceController.makeStudyContainer(inMemory: true)
        let repo = StudyRepository(container: container)
        try repo.initialize(now: now)
        try create(repo)
        try repo.start(mode: .new, now: now)
        try revealAndGrade(repo, grade: .easy, date: now)
        try repo.transaction { try XCTUnwrap(repo.logs().first).reviewedAt = now.addingTimeInterval(60) }
        let reader = StatisticsReader(container: container)
        var calendar = repo.calendar
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for delta in [0.0, 120, 0, 86400, -86400] {
            let date = now.addingTimeInterval(delta)
            let cached = try await reader.load(now: date, calendar: calendar, startHour: 4, scope: LearningScope(), revision: 1)
            let uncached = try await StatisticsReader(container: container).load(now: date, calendar: calendar, startHour: 4, scope: LearningScope())
            XCTAssertEqual(cached.days.map(\.date), uncached.days.map(\.date))
            XCTAssertEqual(cached.days.map(\.answers), uncached.days.map(\.answers))
            XCTAssertEqual(cached.ratings, uncached.ratings)
            XCTAssertEqual(cached.streak, uncached.streak)
            XCTAssertEqual(cached.achievements?.progress.currentStreak, uncached.achievements?.progress.currentStreak)
            XCTAssertEqual(cached.achievements?.progress.uniqueCardsToday, uncached.achievements?.progress.uniqueCardsToday)
            XCTAssertEqual(cached.achievements?.history, uncached.achievements?.history)
            XCTAssertEqual(cached.meanRetrievability, uncached.meanRetrievability)
        }
        for _ in 0..<8 {
            _ = try await reader.load(now: now, calendar: calendar, startHour: 4, scope: LearningScope(tagIDs: [UUID()]), revision: 1)
        }
        let historyCount = await reader.cachedHistoryCount, cost = await reader.cachedCost
        XCTAssertEqual(historyCount, 4)
        XCTAssertLessThanOrEqual(cost, 16 * 1024 * 1024)
    }
    func testStatisticsStoreInvalidatesAfterGradeUndoAndFailedPostSaveProjection() async throws {
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
        try create(store.repository); try create(store.repository)
        try store.reload()
        func report() async throws {
            store.refreshStatistics()
            for _ in 0..<200 {
                if !store.statisticsLoading { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Statistics task did not finish")
        }
        try await report()
        XCTAssertNil(store.statisticsError)
        XCTAssertEqual(store.statistics?.days.first?.answers, 0)
        XCTAssertEqual(store.achievementProgress?.currentStreak, 0)
        XCTAssertTrue(store.achievementHistory.isEmpty)
        store.start(.new); store.draft(revealed: true); store.grade(.good)
        try await report()
        XCTAssertEqual(store.statistics?.days.first?.answers, 1)
        XCTAssertEqual(store.statistics?.dashboardPeriods[7]?.cards, 1)
        XCTAssertEqual(store.achievementProgress?.uniqueCardsToday, 1)
        XCTAssertEqual(Set(store.achievementHistory.map(\.kind)), [.firstStudyToday, .streakAdvanced])
        store.undo()
        try await report()
        XCTAssertEqual(store.statistics?.days.first?.answers, 0)
        XCTAssertEqual(store.achievementProgress?.currentStreak, 0)
        XCTAssertEqual(store.statistics?.dashboardPeriods[7]?.cards, 0)
        XCTAssertTrue(store.achievementHistory.isEmpty)
        // Save succeeds, then queue projection fails. A cached report from the
        // old revision must not hide the newly persisted invalid FSRS data.
        let id = try XCTUnwrap(store.review?.card?.cardID)
        XCTAssertFalse(store.perform {
            try store.repository.transaction {
                try XCTUnwrap(store.repository.card(id)).fsrsPayload = Data("invalid".utf8)
            }
        })
        try await report()
        XCTAssertNotNil(store.statisticsError)
    }
    func testStatisticsMaterialRevisionTimeScopeLimitsAndCancellation() async throws {
        let container = try PersistenceController.makeStudyContainer(inMemory: true)
        let repo = StudyRepository(container: container)
        try repo.initialize(now: now)
        let root = try repo.decks()[0].id
        let child = try repo.createDeck(name: "Child", parentID: root, now: now)
        try repo.createNote(NoteInput(deckID: child, question: "Q", answer: "A", tagNames: ["Tag"]), now: now)
        let tag = try XCTUnwrap(repo.tags().first?.id)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(revealed: true, now: now)
        try repo.grade(.easy, now: now)
        let reader = StatisticsReader(container: container)
        let cold = try await reader.load(now: now, calendar: repo.calendar, startHour: 4, scope: LearningScope(), revision: 1)
        let warm = try await reader.load(now: now, calendar: repo.calendar, startHour: 4, scope: LearningScope(deckID: root, tagIDs: [tag]), revision: 1)
        XCTAssertEqual(cold.days.first?.answers, warm.days.first?.answers)
        let excluded = try await reader.load(now: now, calendar: repo.calendar, startHour: 4,
            scope: LearningScope(deckID: UUID()), revision: 1)
        XCTAssertEqual(excluded.days.first?.answers, 0)
        XCTAssertEqual(excluded.achievements?.progress.uniqueCardsToday, 1)
        XCTAssertEqual(excluded.achievements?.history, try repo.achievementHistory())
        XCTAssertEqual(cold.achievements?.history, warm.achievements?.history)
        let achievementAggregations = await reader.achievementAggregations
        XCTAssertEqual(achievementAggregations, 1)
        let reads = await reader.materialReads
        XCTAssertEqual(reads, 1)
        var calendar = repo.calendar
        calendar.timeZone = TimeZone(secondsFromGMT: -8 * 3600)!
        let future = now.addingTimeInterval(86400 * 3)
        let cached = try await reader.load(now: future, calendar: calendar, startHour: 7, scope: LearningScope(), revision: 1)
        let uncached = try await StatisticsReader(container: container).load(now: future, calendar: calendar, startHour: 7, scope: LearningScope())
        XCTAssertEqual(cached.days.map(\.date), uncached.days.map(\.date))
        XCTAssertEqual(cached.days.map(\.answers), uncached.days.map(\.answers))
        XCTAssertEqual(cached.meanRetrievability, uncached.meanRetrievability)
        XCTAssertNotEqual(cached.meanRetrievability, cold.meanRetrievability)
        XCTAssertEqual(cached.achievements?.progress.currentStreak, 0)
        XCTAssertEqual(cached.achievements?.history, uncached.achievements?.history)
        XCTAssertEqual(cached.achievements?.progress.longestStreak, uncached.achievements?.progress.longestStreak)
        try repo.undo(now: now)
        let undone = try await reader.load(now: now, calendar: repo.calendar, startHour: 4, scope: LearningScope(), revision: 2)
        XCTAssertEqual(undone.days.first?.answers, 0)
        XCTAssertNil(undone.meanRetrievability)
        XCTAssertEqual(undone.achievements?.progress.longestStreak, 0)
        XCTAssertTrue(undone.achievements?.history.isEmpty == true)
        let afterUndoReads = await reader.materialReads
        XCTAssertEqual(afterUndoReads, 2)
        let bounded = StatisticsReader(container: container, maximumCacheCost: 0)
        _ = try await bounded.load(now: now, calendar: repo.calendar, startHour: 4, scope: LearningScope(), revision: 1)
        let cost = await bounded.cachedCost
        XCTAssertEqual(cost, 0)
        let expiring = StatisticsReader(container: container, cacheLifetime: .milliseconds(20))
        _ = try await expiring.load(now: now, calendar: repo.calendar, startHour: 4, scope: LearningScope(), revision: 1)
        try await Task.sleep(for: .milliseconds(80))
        let expiredCost = await expiring.cachedCost
        XCTAssertEqual(expiredCost, 0)
        let task = Task {
            try await reader.load(now: self.now, calendar: calendar, startHour: 4, scope: LearningScope(), revision: 2)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled report must not be published") }
        catch is CancellationError { }
        await reader.clearCache()
        let clearedCost = await reader.cachedCost
        XCTAssertEqual(clearedCost, 0)
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

    func testOperationQueueReuseIsBoundedAndRollbackDiscardsPendingProjection() throws {
        let repo = try fixture()
        try create(repo); try create(repo)
        let original = try repo.queueCards()
        let before = repo.queueProjectionCount
        try repo.withStudyQueueReuse {
            _ = try repo.queueCards()
            _ = try repo.queueCards()
            XCTAssertEqual(repo.queueProjectionCount - before, 1)
            let scope = LearningScope(deckID: try repo.decks()[0].id)
            XCTAssertEqual(try repo.scopedQueueCards(scope).count, 2)
            repo.save = { _ in throw Failure.save }
            XCTAssertThrowsError(try repo.transaction {
                try XCTUnwrap(repo.cards().first).isSuspended = true
                XCTAssertEqual(try repo.queueCards().filter(\.suspended).count, 1)
            })
            XCTAssertEqual(try repo.queueCards().filter(\.suspended).count, 0)
        }
        let after = repo.queueProjectionCount
        _ = try repo.queueCards()
        XCTAssertEqual(repo.queueProjectionCount, after + 1)
        XCTAssertEqual(try repo.cards().count, original.count)
        repo.save = { try $0.save() }
        let store = try StudyStore(container: repo.context.container, clock: { self.now })
        let start = store.repository.queueProjectionCount
        let noteFetches = store.repository.queueNoteFetchCount
        let noteRows = store.repository.queueNoteRowsFetched
        let cardRows = store.repository.queueCardRowsFetched
        store.start(.new)
        XCTAssertNil(store.failure)
        XCTAssertEqual(store.repository.queueProjectionCount - start, 1)
        XCTAssertEqual(store.repository.queueNoteFetchCount - noteFetches, 1)
        XCTAssertEqual(store.repository.queueNoteRowsFetched - noteRows, 2)
        XCTAssertEqual(store.repository.queueCardRowsFetched - cardRows, 2)
        XCTAssertNotNil(store.review?.card)
        store.draft(revealed: true)
        let grade = store.repository.queueProjectionCount
        store.grade(.good)
        XCTAssertNil(store.failure)
        XCTAssertEqual(store.repository.queueProjectionCount - grade, 1)
        store.undo()
        XCTAssertNil(store.failure)
        XCTAssertEqual(store.counts.newRemaining, 2)
        XCTAssertEqual(try store.repository.logs().count, 0)
    }

    func testQueueStateCacheTracksGradeUndoRollbackAndRemoval() throws {
        let repo = try fixture()
        try create(repo); try create(repo)
        let original = try repo.queueCards()
        XCTAssertEqual(repo.queueStateDecodeCount, 2)
        _ = try repo.queueCards()
        XCTAssertEqual(repo.queueStateDecodeCount, 2)
        try repo.start(mode: .new, now: now)
        let id = try XCTUnwrap(repo.session()?.cardID)
        try revealAndGrade(repo, grade: .easy, date: now)
        XCTAssertEqual(try repo.queueCards().first { $0.id == id }?.state, "review")
        XCTAssertEqual(repo.queueStateDecodeCount, 3)
        try repo.undo(now: now)
        XCTAssertEqual(try repo.queueCards().first { $0.id == id }?.state, "new")
        XCTAssertEqual(repo.queueStateDecodeCount, 4)
        try repo.updateDraft(revealed: true, now: now)
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.grade(.good, now: now))
        XCTAssertEqual(try repo.queueCards().map(\.state), original.map(\.state))
        XCTAssertEqual(try repo.logs().count, 0)
        repo.save = { try $0.save() }
        try repo.transaction { repo.context.delete(try XCTUnwrap(repo.card(id))) }
        XCTAssertFalse(try repo.queueCards().contains { $0.id == id })
    }

    func testThreeThousandBasicCardsReviewRefreshMeasurement() throws {
        let container = try PersistenceController.makeStudyContainer(inMemory: true)
        let repo = StudyRepository(container: container)
        try repo.initialize(now: now)
        let deckID = try XCTUnwrap(repo.decks().first?.id)
        let scheduler = try ReviewScheduler()
        let before = try scheduler.newCard(now: now)
        let transition = try scheduler.review(before, grade: .easy, now: now)
        let payload = try JSONEncoder().encode(transition.after)
        let due = try scheduler.summary(transition.after).dueDate
        try repo.transaction {
            for index in 0..<3000 {
                let input = NoteInput(deckID: deckID, kind: .basic, question: "Question \(index)", answer: "Answer")
                let content = try JSONEncoder().encode(TextContent(question: input.question, answer: input.answer, explanation: ""))
                let note = Note(input: input, content: content, now: now)
                repo.context.insert(note)
                let card = StudyCard(noteID: note.id, variantKey: "basic:front", payload: payload, now: now)
                card.dueDate = due
                repo.context.insert(card)
            }
        }
        let date = due.addingTimeInterval(1)
        let start = Date()
        let store = try StudyStore(container: container, clock: { date })
        let launch = Date().timeIntervalSince(start)
        let revision = store.dataRevision
        let sessionStart = Date()
        store.start(.review)
        let session = Date().timeIntervalSince(sessionStart)
        XCTAssertNotNil(store.review?.card)
        let cardID = store.review?.card?.cardID
        store.draft(revealed: true)
        let gradeStart = Date()
        store.grade(.good)
        let grade = Date().timeIntervalSince(gradeStart)
        XCTAssertNil(store.failure)
        let undoStart = Date()
        store.undo()
        let undo = Date().timeIntervalSince(undoStart)
        XCTAssertNil(store.failure)
        XCTAssertEqual(store.review?.card?.cardID, cardID)
        XCTAssertEqual(try store.repository.logs().count, 0)
        XCTAssertGreaterThanOrEqual(store.dataRevision, revision)
        print("Issue116 3000 notes/cards: launch=\(launch)s start=\(session)s grade=\(grade)s undo=\(undo)s")
    }

    func testTextLayoutsDraftEditingCSVAndBackupKeepIDsAndSchedule() async throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        var input = NoteInput(deckID: deck, question: "｜東京《とうきょう》", answer: "Capital", reverseEnabled: true, questionLayout: .vertical, answerLayout: .horizontal)
        let id = try repo.createNote(input, now: now)
        try repo.start(mode: .new, now: now)
        try revealAndGrade(repo, grade: .easy, date: now)
        let states = try repo.cards().map { ($0.id, $0.fsrsPayload, $0.dueDate) }
        input.questionLayout = .horizontal; input.answerLayout = .vertical
        input.question = "不［＃（ズ）］［＃一レ］知［＃（ラ）］。"
        try repo.updateNote(id: id, input: input, now: now)
        for (id, payload, due) in states {
            let card = try XCTUnwrap(repo.cards().first { $0.id == id })
            XCTAssertEqual(card.fsrsPayload, payload); XCTAssertEqual(card.dueDate, due)
        }
        try repo.saveEditorDraft(key: "new", input: input, now: now)
        XCTAssertEqual(try repo.editorDraft(key: "new")?.answerLayout, .vertical)
        let archive = try BackupArchive.decode(await BackupService.export(repository: repo, now: now, appVersion: "test"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = MediaStore(root: root.appendingPathComponent("Media"))
        let container = try BackupService.restore(archive, location: StudyStorageLocation(canonicalStore: root.appendingPathComponent("Study.store")), mediaStore: media, now: now)
        let restored = StudyRepository(container: container, mediaStore: media)
        try restored.initialize(now: now)
        let content = try JSONDecoder().decode(TextContent.self, from: restored.notes().first!.contentPayload)
        XCTAssertEqual(content.questionLayout, .horizontal); XCTAssertEqual(content.answerLayout, .vertical)
        XCTAssertEqual(content.question, input.question)
        XCTAssertEqual(try restored.editorDraft(key: "new")?.answerLayout, .vertical)
        XCTAssertEqual(Set(try restored.cards().map(\.id)), Set(states.map { $0.0 }))
        let table = try ImportParser.table("question,answer,question_layout,answer_layout\n不［＃（ズ）］［＃一レ］知［＃（ラ）］。,Capital,vertical,horizontal", delimiter: ",")
        let rows = ImportParser.map(table, header: true, questionColumn: 0, answerColumn: 1)
        _ = try restored.importRows(rows, deckID: deck, kind: .basic, tagNames: [], action: .update, source: "CSV", now: now)
        let updated = try JSONDecoder().decode(TextContent.self, from: restored.notes().first!.contentPayload)
        XCTAssertEqual(updated.questionLayout, .vertical); XCTAssertEqual(updated.answerLayout, .horizontal)
        XCTAssertEqual(Set(try restored.cards().map(\.id)), Set(states.map { $0.0 }))
        XCTAssertEqual(try restored.logs().count, 1)
    }
    func testWeakPracticeFiltersAndNeverChangesSchedulerHistoryOrDraft() throws {
        let repo = try fixture()
        let id = try create(repo)
        try repo.start(mode: .new, now: now)
        try revealAndGrade(repo, grade: .again, date: now)
        let later = now.addingTimeInterval(60)
        let before = try BackupData.capture(repo).canonical()
        let rows = try repo.weakCards(scope: LearningScope(), days: 7, now: later)
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.card.noteID, id)
        XCTAssertEqual(rows.first?.evidence.reasons, ["直近の評価がAgain"])
        var practice = try repo.weakPractice(scope: LearningScope(), days: 7, now: later)
        XCTAssertEqual(practice.phase, .practicing)
        XCTAssertEqual(practice.completedCount, 0)
        practice.next(); XCTAssertEqual(practice.index, 0)
        practice.reveal(); practice.next(); XCTAssertNil(practice.current)
        XCTAssertEqual(practice.phase, .completed)
        XCTAssertEqual(practice.completedCount, 1)
        let originalOrder = practice.cards.map(\.cardID)
        practice.restart()
        XCTAssertEqual(practice.phase, .practicing)
        XCTAssertEqual(practice.completedCount, 0)
        XCTAssertFalse(practice.revealed)
        XCTAssertEqual(practice.cards.map(\.cardID), originalOrder)
        practice.reveal(); practice.next()
        practice.previous(); XCTAssertEqual(practice.current?.noteID, id); XCTAssertFalse(practice.revealed)
        XCTAssertEqual(try BackupData.capture(repo).canonical(), before)
        let other = try repo.createDeck(name: "Other", now: now)
        XCTAssertTrue(try repo.weakCards(scope: LearningScope(deckID: other), days: nil, now: later).isEmpty)
        XCTAssertTrue(try repo.weakCards(scope: LearningScope(), days: 7, now: later.addingTimeInterval(10 * 86400)).isEmpty)
        try repo.setSuspended(cardID: rows[0].id, value: true, now: later)
        XCTAssertTrue(try repo.weakCards(scope: LearningScope(), days: nil, now: later).isEmpty)
        XCTAssertThrowsError(try repo.weakPractice(scope: LearningScope(), days: nil, now: later))
    }

    func testWeakPracticeKeepsSiblingSuppressionAndTagAndParentScopes() throws {
        let repo = try fixture(), parent = try repo.decks()[0].id
        let child = try repo.createDeck(name: "Child", parentID: parent, now: now)
        let note = try repo.createNote(NoteInput(deckID: child, question: "Q", answer: "A", tagNames: ["weak"], reverseEnabled: true), now: now)
        let cards = try repo.cards().filter { $0.noteID == note }
        // Build valid learned snapshots and histories for both siblings on a previous day.
        let yesterday = now.addingTimeInterval(-86400)
        let scheduler = try ReviewScheduler()
        for card in cards {
            let transition = try scheduler.review(repo.snapshot(card), grade: .again, now: yesterday)
            let after = try JSONEncoder().encode(transition.after)
            repo.context.insert(StudyReviewLog(card: card, transition: transition, before: card.fsrsPayload, after: after,
                mode: .mental, durationMs: 0, wasNew: true, sequence: card.id == cards[0].id ? 1 : 2))
            card.fsrsPayload = after; card.dueDate = try scheduler.summary(transition.after).dueDate
        }
        try repo.context.save()
        let tag = try repo.tags().first!.id
        let scope = LearningScope(deckID: parent, tagIDs: [tag])
        XCTAssertEqual(try repo.weakCards(scope: scope, days: 30, now: now).count, 2)
        // Short learning siblings are the deliberate exception.
        XCTAssertEqual(try repo.weakPractice(scope: scope, days: 30, now: now).cards.count, 2)
        XCTAssertTrue(try repo.weakCards(scope: LearningScope(tagIDs: [UUID()]), days: 30, now: now).count == 2) // normalized stale tag removed
        var sequence = 2
        for grade in [ReviewGrade.again, .easy] {
            for card in cards {
                sequence += 1
                let time = yesterday.addingTimeInterval(Double(sequence) * 600)
                let transition = try scheduler.review(repo.snapshot(card), grade: grade, now: time)
                let after = try JSONEncoder().encode(transition.after)
                repo.context.insert(StudyReviewLog(card: card, transition: transition, before: card.fsrsPayload, after: after,
                    mode: .mental, durationMs: 0, wasNew: false, sequence: sequence))
                card.fsrsPayload = after; card.dueDate = try scheduler.summary(transition.after).dueDate
            }
        }
        try repo.context.save()
        XCTAssertTrue(try repo.noteItems().allSatisfy { $0.summary.state == "review" })
        XCTAssertEqual(try repo.weakPractice(scope: scope, days: 30, now: now).cards.count, 1)
        try repo.createNote(NoteInput(deckID: child, question: "Strong", answer: "A", tagNames: ["strong"]), now: now)
        let strongTag = try repo.tags().first { $0.name == "strong" }!.id
        XCTAssertTrue(try repo.weakCards(scope: LearningScope(deckID: parent, tagIDs: [strongTag]), days: 30, now: now).isEmpty)
        var saved = try repo.options(); saved.siblingBuryEnabled = false
        try repo.updateOptions(saved)
        XCTAssertEqual(try repo.weakPractice(scope: scope, days: 30, now: now).cards.count, 2)
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

    func testSessionResponseSnapshotKeepsDraftUndoAndAnotherSet() throws {
        let repo = try fixture()
        try create(repo)
        try create(repo)
        var options = try repo.options()
        options.sessionResponseMode = .typing
        options.sessionAnswerLimit = 1
        try repo.updateOptions(options)
        try repo.start(mode: .new, now: now)
        XCTAssertEqual(try repo.presentation(now: now)?.responseMode, .typing)
        try repo.updateDraft(text: "draft", now: now)
        options = try repo.options(); options.sessionResponseMode = .mental
        try repo.updateOptions(options)
        try repo.setSessionActive(false, now: now)
        try repo.resume(now: now)
        XCTAssertEqual(try repo.session()?.typedDraft, "draft")
        XCTAssertEqual(try repo.presentation(now: now)?.responseMode, .typing)
        try revealAndGrade(repo, grade: .easy, date: now)
        try repo.undo(now: now)
        XCTAssertEqual(try repo.presentation(now: now)?.responseMode, .typing)
        try revealAndGrade(repo, grade: .easy, date: now)
        try repo.startAnotherSession(now: now)
        XCTAssertEqual(try repo.presentation(now: now)?.responseMode, .typing)
        XCTAssertTrue(try repo.notes().allSatisfy { $0.defaultResponseMode == "mental" })
        let optionsData = try JSONEncoder().encode(repo.options())
        let decoded = try JSONDecoder().decode(StudyOptions.self, from: optionsData)
        XCTAssertEqual(decoded.activeSessionProgress?.responseMode, .typing)
        let legacy = try JSONDecoder().decode(StudySessionProgressSnapshot.self,
            from: Data(#"{"startSequence":0,"answerLimit":20}"#.utf8))
        XCTAssertNil(legacy.responseMode)
    }

    func testOrderingOverrideFiltersCandidatesAndFailedStartKeepsSession() throws {
        let repo = try fixture()
        try create(repo)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(text: "keep", now: now)
        let before = try BackupData.capture(repo).canonical()
        XCTAssertThrowsError(try repo.start(mode: .new, responseMode: .ordering, now: now))
        XCTAssertEqual(try BackupData.capture(repo).canonical(), before)
        let id = try repo.createNote(NoteInput(deckID: repo.decks()[0].id,
            question: "英語", answer: "I like green tea."), now: now)
        var saved = try repo.options(); saved.sessionResponseMode = .ordering
        try repo.updateOptions(saved)
        XCTAssertEqual(try repo.homeSnapshot(now: now).counts.newRemaining, 1)
        let unchanged = try BackupData.capture(repo).canonical()
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.start(mode: .new, now: now))
        XCTAssertEqual(try BackupData.capture(repo).canonical(), unchanged)
        repo.save = { try $0.save() }
        try repo.start(mode: .new, now: now)
        XCTAssertEqual(try repo.presentation(now: now)?.card?.noteID, id)
        XCTAssertEqual(try repo.presentation(now: now)?.responseMode, .ordering)
        try repo.updateDraft(mode: .mental, now: now)
        XCTAssertEqual(try repo.presentation(now: now)?.responseMode, .mental)
        XCTAssertEqual(try repo.options().activeSessionProgress?.responseMode, .ordering)
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
        options.sessionResponseMode = .typing
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
        let event = try XCTUnwrap(repo.pendingAchievementEvents().first)
        XCTAssertNotNil(try repo.claimAchievementEvent(id: event.id, now: boundary))
        let achievementRecords = try repo.options().achievements
        let backup = try BackupArchive.decode(await BackupService.export(repository: repo, now: boundary, appVersion: "audit"))
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("Restored.store"))
        let restoredContainer = try BackupService.restore(backup, location: location, mediaStore: media, now: boundary)
        let restored = StudyRepository(container: restoredContainer, mediaStore: media)
        try restored.initialize(now: boundary)
        XCTAssertEqual(try restored.options().achievements, achievementRecords)
        let restoredReport = try await StatisticsReader(container: restoredContainer).load(now: boundary,
            calendar: restored.calendar, startHour: 4, scope: LearningScope())
        XCTAssertEqual(restoredReport.achievements?.history, try restored.achievementHistory())
        XCTAssertEqual(restoredReport.achievements?.progress.currentStreak, 2)
        XCTAssertNil(try restored.claimAchievementEvent(id: event.id, now: boundary))
        XCTAssertEqual(try restored.achievementProgress(now: boundary).currentStreak, 2)
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

    func testVisibleAnswerTotalStaysAtAnswerCapDuringShortRelearning() throws {
        let repo = try fixture()
        try create(repo)
        try repo.start(mode: .new, answerLimit: 20, now: now)
        let first = try XCTUnwrap(repo.presentation(now: now))
        XCTAssertEqual(first.sessionProgress?.limit, 20)
        XCTAssertEqual(first.visibleAnswerTotal, 20)

        try revealAndGrade(repo, grade: .again, date: now)
        let waiting = try XCTUnwrap(repo.presentation(now: now))
        XCTAssertNil(waiting.card)
        XCTAssertEqual(waiting.sessionProgress?.answered, 1)
        XCTAssertEqual(waiting.visibleAnswerTotal, 20)
        XCTAssertEqual(waiting.emptyState?.reason, .waiting)

        let due = try XCTUnwrap(waiting.nextShortDue)
        try repo.resume(now: due)
        let repeated = try XCTUnwrap(repo.presentation(now: due))
        XCTAssertNotNil(repeated.card)
        XCTAssertEqual(repeated.visibleAnswerTotal, 20)
        XCTAssertEqual(repeated.sessionProgress?.limit, 20)
        try repo.undo(now: due)
        let undone = try XCTUnwrap(repo.presentation(now: due))
        XCTAssertEqual(undone.sessionProgress?.answered, 0)
        XCTAssertEqual(undone.visibleAnswerTotal, 20)
    }

    func testVisibleAnswerTotalUsesEightAvailableCardsAndConfiguredCap() throws {
        let repo = try fixture()
        for _ in 0..<8 { try create(repo) }
        try repo.start(mode: .new, answerLimit: 20, now: now)
        XCTAssertEqual(try repo.presentation(now: now)?.visibleAnswerTotal, 20)
        for _ in 0..<8 { try revealAndGrade(repo, grade: .easy, date: now) }
        let finished = try XCTUnwrap(repo.presentation(now: now))
        XCTAssertNil(finished.card)
        XCTAssertEqual(finished.sessionProgress?.answered, 8)
        XCTAssertEqual(finished.sessionProgress?.limit, 20)
        XCTAssertEqual(finished.visibleAnswerTotal, 20)
        XCTAssertEqual(finished.emptyState?.reason, .complete)
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

    func testHomeAnswerLimitChangesKeep80CardPoolAndExistingSessionSnapshot() throws {
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
        let repo = store.repository
        var settings = try repo.settings(); settings.dailyNewLimit = 100
        try repo.updateSettings(settings)
        for _ in 0..<80 { try create(repo) }
        try store.reload()
        for limit in [10, 20, 30, 0] {
            store.changeSessionAnswerLimit(limit)
            XCTAssertNil(store.failure)
            XCTAssertEqual(store.homePrimaryAction, .start(.new, 80))
            XCTAssertEqual(store.homeCardCount(.new), 80)
            XCTAssertEqual(store.homeCardCount(.mixed), 80)
            XCTAssertEqual(store.homeCardCount(.review), 0)
            XCTAssertTrue(store.canStart(.new)); XCTAssertFalse(store.canStart(.review))
            XCTAssertEqual(store.homePrimaryAction.buttonTitle(answerLimit: store.sessionAnswerLimit),
                           HomeStudyPresentation.startTitle(mode: .new, answerLimit: limit))
        }
        store.changeSessionAnswerLimit(20)
        try repo.start(mode: .new, now: now)
        try repo.setSessionActive(false, now: now)
        try store.reload()
        store.changeSessionAnswerLimit(10)
        XCTAssertEqual(store.homePrimaryAction.buttonTitle(answerLimit: store.sessionAnswerLimit), "続きから再開")
        XCTAssertEqual(store.review?.sessionProgress?.limit, 20)
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
    func testMemoryAnalysisReadsReviewBeforeStateAndPreservesData() async throws {
        let container = try PersistenceController.makeStudyContainer(inMemory: true)
        let repo = StudyRepository(container: container)
        try repo.initialize(now: now)
        let root = try repo.decks()[0].id
        let child = try repo.createDeck(name: "Child", parentID: root, now: now)
        let tag = UUID()
        let noteID = try repo.createNote(NoteInput(deckID: child, question: "Q", answer: "A"), now: now)
        let note = try XCTUnwrap(repo.notes().first)
        let card = try XCTUnwrap(repo.cards().first)
        let scheduler = try ReviewScheduler()
        let learned = try scheduler.review(scheduler.newCard(now: now), grade: .easy, now: now).after
        XCTAssertEqual(try scheduler.summary(learned).state, "review")
        let transition = try scheduler.review(learned, grade: .again, now: now.addingTimeInterval(86400))
        let before = try JSONEncoder().encode(learned), after = try JSONEncoder().encode(transition.after)
        try repo.transaction {
            note.tagIDs = [tag]
            card.fsrsPayload = before
            repo.context.insert(StudyReviewLog(card: card, transition: transition, before: before, after: after,
                                               mode: .mental, durationMs: 1000, wasNew: false, sequence: 1))
        }
        try repo.saveDeckLearning(DeckLearningOverride(deckID: root, retention: 0.95))
        let reader = StatisticsReader(container: container), date = now.addingTimeInterval(86401)
        let report = try await reader.load(now: date, calendar: repo.calendar, startHour: 4,
                                          scope: LearningScope(deckID: root, tagIDs: [tag]))
        XCTAssertEqual(report.memory?.distributions[0].count, 1)
        XCTAssertEqual(report.memory?.retention[1].trials, 1)
        XCTAssertEqual(report.memory?.retention[1].successes, 0)
        XCTAssertEqual(report.memory?.targets, [0.95])
        XCTAssertEqual(try repo.card(card.id)?.fsrsPayload, before)
        XCTAssertEqual(try repo.logs().count, 1)
        try repo.transaction { card.isSuspended = true }
        let stopped = try await reader.load(now: date, calendar: repo.calendar, startHour: 4, scope: LearningScope())
        XCTAssertEqual(stopped.memory?.distributions[0].count, 0)
        XCTAssertEqual(stopped.memory?.retention[1].trials, 1)
        try repo.deleteNote(id: noteID)
        let deleted = try await reader.load(now: date, calendar: repo.calendar, startHour: 4, scope: LearningScope())
        XCTAssertEqual(deleted.memory?.retention[1].trials, 1)
        let scoped = try await reader.load(now: date, calendar: repo.calendar, startHour: 4, scope: LearningScope(deckID: root))
        XCTAssertEqual(scoped.memory?.retention[1].trials, 0)
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

extension StudyRepositoryTests {
    func testTypedAnswerDefaultOffAndOnlyTypingIsCapturedWithSnapshot() throws {
        let repo = try fixture()
        try create(repo, mode: .typing); try repo.start(mode: .new, now: now)
        try repo.updateDraft(text: "OFF response", revealed: true, now: now); try repo.grade(.good, now: now)
        XCTAssertTrue(try repo.savedTypedAnswers(now: now).isEmpty)
        XCTAssertEqual(try repo.logs().count, 1)
        try repo.updateTypedAnswerPolicy(TypedAnswerPolicy(enabled: true, retentionDays: 30), now: now)
        let noteID = try create(repo, mode: .typing)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(text: "とうきょう\n入力時の本文", revealed: true, now: now); try repo.grade(.hard, now: now)
        let record = try XCTUnwrap(repo.savedTypedAnswers(now: now).first)
        XCTAssertEqual(record.answer, "とうきょう\n入力時の本文")
        XCTAssertEqual(record.question, "日本の首都は？"); XCTAssertEqual(record.modelAnswer, "東京")
        XCTAssertEqual(record.id, try repo.logs().last?.id); XCTAssertEqual(record.cardID, try repo.logs().last?.cardID)
        try repo.updateNote(id: noteID, input: NoteInput(deckID: repo.decks()[0].id, question: "編集後", answer: "別の解答"), now: now)
        XCTAssertEqual(try repo.savedTypedAnswers(now: now).first, record)
        try repo.updateTypedAnswerPolicy(TypedAnswerPolicy(enabled: false, retentionDays: 30), now: now)
        try create(repo, mode: .typing); try repo.start(mode: .new, now: now)
        try repo.updateDraft(text: "OFF again", revealed: true, now: now); try repo.grade(.easy, now: now)
        XCTAssertEqual(try repo.savedTypedAnswers(now: now), [record])
    }
    func testTypedAnswerUndoAndFailedGradeAreAtomic() throws {
        let repo = try fixture(); try create(repo, mode: .typing)
        try repo.updateTypedAnswerPolicy(TypedAnswerPolicy(enabled: true, retentionDays: 0), now: now)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(text: "saved", revealed: true, now: now)
        let before = try BackupData.capture(repo).canonical()
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.grade(.good, now: now))
        XCTAssertEqual(try BackupData.capture(repo).canonical(), before)
        repo.save = { try $0.save() }
        try repo.grade(.good, now: now)
        XCTAssertEqual(try repo.savedTypedAnswers(now: now).count, 1)
        let graded = try BackupData.capture(repo).canonical()
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.undo(now: now))
        XCTAssertEqual(try BackupData.capture(repo).canonical(), graded)
        repo.save = { try $0.save() }
        try repo.undo(now: now)
        XCTAssertTrue(try repo.savedTypedAnswers(now: now).isEmpty)
        XCTAssertTrue(try repo.logs().isEmpty)
        XCTAssertEqual(try repo.cards().first?.fsrsPayload, before.cards.first?.fsrsPayload)
        XCTAssertEqual(try repo.session()?.answerMode, "typing")
    }
    func testTypedAnswerRetentionAndDeletionDoNotChangeReviewHistory() throws {
        let repo = try fixture(); try create(repo, mode: .typing)
        try repo.updateTypedAnswerPolicy(TypedAnswerPolicy(enabled: true, retentionDays: 30), now: now)
        try repo.start(mode: .new, now: now); try repo.updateDraft(text: "private", revealed: true, now: now)
        try repo.grade(.good, now: now)
        let cards = try repo.cards().map { ($0.id, $0.fsrsPayload) }, logIDs = try repo.logs().map(\.id)
        XCTAssertEqual(try repo.savedTypedAnswers(now: now.addingTimeInterval(7 * 86400)).count, 1)
        try repo.updateTypedAnswerPolicy(TypedAnswerPolicy(enabled: false, retentionDays: 7), now: now.addingTimeInterval(8 * 86400))
        XCTAssertTrue(try repo.savedTypedAnswers(now: now.addingTimeInterval(8 * 86400)).isEmpty)
        XCTAssertEqual(try repo.logs().map(\.id), logIDs)
        XCTAssertEqual(try repo.cards().first?.id, cards[0].0); XCTAssertEqual(try repo.cards().first?.fsrsPayload, cards[0].1)
        XCTAssertThrowsError(try repo.updateTypedAnswerPolicy(TypedAnswerPolicy(enabled: true, retentionDays: -1), now: now))
        try repo.deleteTypedAnswers() // Repeated deletion is safe.
        XCTAssertEqual(try repo.logs().map(\.id), logIDs)
    }
    func testTypedAnswerMentalModeNeverStoresStaleDraftAndDeletionFailureKeepsAnswer() throws {
        let repo = try fixture(); try create(repo, mode: .typing)
        try repo.updateTypedAnswerPolicy(TypedAnswerPolicy(enabled: true, retentionDays: 0), now: now)
        try repo.start(mode: .new, now: now); try repo.updateDraft(text: "private", revealed: true, now: now); try repo.grade(.good, now: now)
        let before = try BackupData.capture(repo).canonical()
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.deleteTypedAnswers())
        XCTAssertEqual(try BackupData.capture(repo).canonical(), before)
        repo.save = { try $0.save() }
        try repo.deleteTypedAnswers(ids: [try repo.savedTypedAnswers(now: now)[0].id])
        XCTAssertTrue(try repo.savedTypedAnswers(now: now).isEmpty); XCTAssertEqual(try repo.logs().count, 1)
        try create(repo); try repo.start(mode: .new, now: now)
        try repo.updateDraft(text: "stale text", revealed: true, now: now); try repo.grade(.good, now: now)
        XCTAssertTrue(try repo.savedTypedAnswers(now: now).isEmpty)
    }
}

extension StudyRepositoryTests {
    func testTypedAnswerCapturesActualClozeVariantInsteadOfEmptySourceAnswer() throws {
        let repo = try fixture()
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, kind: .cloze, question: "{{c1::東京}}と{{c2::京都}}"), now: now)
        try repo.updateTypedAnswerPolicy(TypedAnswerPolicy(enabled: true, retentionDays: 30), now: now)
        try repo.start(mode: .new, now: now)
        let presented = try XCTUnwrap(repo.presentation(now: now)?.card)
        XCTAssertTrue(["東京", "京都"].contains(presented.content.answer))
        try repo.updateDraft(mode: .typing, text: "変種への回答", revealed: true, now: now)
        try repo.grade(.good, now: now)
        let saved = try XCTUnwrap(repo.savedTypedAnswers(now: now).first)
        XCTAssertEqual(saved.cardID, presented.cardID)
        XCTAssertEqual(saved.question, presented.content.question)
        XCTAssertEqual(saved.modelAnswer, presented.content.answer)
        XCTAssertEqual(saved.answer, "変種への回答")
    }

    func testForecastScheduleVersusSimulationDeckQuotaUndoAndReadOnly() throws {
        let repo = try fixture(), root = try repo.decks()[0].id
        let child = try repo.createDeck(name: "Forecast child", parentID: root, now: now)
        try repo.saveDeckLearning(DeckLearningOverride(deckID: root, newLimit: 1, retention: 0.9))
        var settings = try repo.settings(); settings.dailyNewLimit = 3; settings.dailyGoal = 2
        try repo.updateSettings(settings)
        for index in 0..<3 {
            try repo.createNote(NoteInput(deckID: child, question: "Fresh \(index)", answer: "A"), now: now.addingTimeInterval(-Double(index)))
        }
        let scheduler = try ReviewScheduler(), past = now.addingTimeInterval(-86400 * 30)
        for index in 0..<2 {
            let note = try repo.createNote(NoteInput(deckID: root, question: "Due \(index)", answer: "A"), now: past)
            let card = try XCTUnwrap(repo.cards().first { $0.noteID == note })
            let transition = try scheduler.review(repo.snapshot(card), grade: .easy, now: past)
            let before = card.fsrsPayload, after = try JSONEncoder().encode(transition.after)
            try repo.transaction {
                card.fsrsPayload = after; card.dueDate = try scheduler.summary(transition.after).dueDate
                card.isSuspended = index == 1
                repo.context.insert(StudyReviewLog(card: card, transition: transition, before: before, after: after,
                                                 mode: .mental, durationMs: 1000, wasNew: true, sequence: index + 1))
            }
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let before = try BackupData.capture(repo).canonical()
        let report = try ReviewForecast.calculate(data: before, deckID: nil, days: 7, now: now, calendar: calendar)
        XCTAssertEqual(report.days.count, 7); XCTAssertEqual(report.scheduled, 1)
        XCTAssertEqual(report.overdue, 1); XCTAssertEqual(report.dailyGoal, 2)
        XCTAssertEqual(report.days[0].newCards, 1)
        XCTAssertEqual(report.days.reduce(0) { $0 + $1.newCards }, 3)
        XCTAssertEqual(report.remainingNew, 0)
        XCTAssertEqual(report, try ReviewForecast.calculate(data: before, deckID: nil, days: 7, now: now, calendar: calendar))
        XCTAssertEqual(try BackupData.capture(repo).canonical(), before)
        let scoped = try ReviewForecast.calculate(data: before, deckID: child, days: 30, now: now, calendar: calendar)
        XCTAssertEqual(scoped.scheduled, 0); XCTAssertEqual(scoped.days[0].newCards, 1)
        XCTAssertEqual(scoped.days.reduce(0) { $0 + $1.newCards }, 3)
        try repo.start(mode: .new, now: now); try revealAndGrade(repo, grade: .easy, date: now)
        let after = try BackupData.capture(repo)
        let graded = try ReviewForecast.calculate(data: after, deckID: nil, days: 7, now: now, calendar: calendar)
        XCTAssertEqual(graded.days[0].newCards, 0)
        try repo.undo(now: now)
        XCTAssertEqual(try ReviewForecast.calculate(data: BackupData.capture(repo), deckID: nil, days: 7, now: now, calendar: calendar), report)
        try repo.createNote(NoteInput(deckID: child, question: "Added", answer: "A"), now: now)
        let added = try ReviewForecast.calculate(data: BackupData.capture(repo), deckID: nil, days: 7, now: now, calendar: calendar)
        XCTAssertEqual(added.days.reduce(0) { $0 + $1.newCards }, 4)
    }
    func testForecastStudyBoundaryDSTTimeZoneSiblingBuryAndSharedGlobalQuota() throws {
        let repo = try fixture(), root = try repo.decks()[0].id
        let other = try repo.createDeck(name: "Other", now: now)
        for index in 0..<3 {
            try repo.createNote(NoteInput(deckID: root, question: "Sibling \(index)", answer: "A", reverseEnabled: true), now: now)
        }
        try repo.createNote(NoteInput(deckID: other, question: "Other new", answer: "A"), now: now.addingTimeInterval(-100))
        var settings = try repo.settings(); settings.dailyNewLimit = 2; settings.dayStartHour = 2
        try repo.updateSettings(settings)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!
        let data = try BackupData.capture(repo)
        let report = try ReviewForecast.calculate(data: data, deckID: root, days: 7, now: date, calendar: calendar)
        XCTAssertEqual(report.days[0].newCards, 1) // The other deck consumes the global first slot.
        XCTAssertTrue(report.days.contains { $0.end.timeIntervalSince($0.start) == 23 * 3600 })
        XCTAssertEqual(Set(report.days.map(\.start)).count, 7)
        let early = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 1))!
        let earlier = try ReviewForecast.calculate(data: data, deckID: nil, days: 7, now: early, calendar: calendar)
        XCTAssertLessThan(earlier.days[0].start, report.days[0].start)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let tokyo = try ReviewForecast.calculate(data: data, deckID: nil, days: 7, now: date, calendar: calendar)
        XCTAssertNotEqual(tokyo.days[0].start, report.days[0].start)
        XCTAssertThrowsError(try ReviewForecast.calculate(data: data, deckID: UUID(), days: 7, now: date, calendar: calendar))
    }
}

// Frozen schemas require their original Deck type, rather than the current alias.
@MainActor enum LegacyStudyFixture {
    static func write(url: URL, schema: Schema, now: Date, draftText: String) throws -> (UUID, Data, UUID) {
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration("Study", schema: schema, url: url, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let deck = StudySchema.Deck(name: "Legacy", now: now)
        let input = NoteInput(deckID: deck.id, question: "Legacy", answer: "I walk to school.", responseMode: .typing)
        let note = Note(input: input, content: try JSONEncoder().encode(TextContent(question: input.question, answer: input.answer, explanation: "")), now: now)
        let scheduler = try ReviewScheduler(), snapshot = try scheduler.newCard(now: now)
        let before = try JSONEncoder().encode(snapshot)
        let card = StudyCard(noteID: note.id, variantKey: "basic:front", payload: before, now: now)
        let transition = try scheduler.review(snapshot, grade: .good, now: now)
        let after = try JSONEncoder().encode(transition.after)
        let log = StudyReviewLog(card: card, transition: transition, before: before, after: after, mode: .typing, durationMs: 2000, wasNew: true, sequence: 1)
        card.fsrsPayload = after; card.dueDate = try scheduler.summary(transition.after).dueDate
        let draft = SessionDraft(mode: .review, now: now)
        draft.cardID = card.id; draft.answerMode = "typing"; draft.typedDraft = draftText
        context.insert(deck); context.insert(note); context.insert(card); context.insert(log)
        context.insert(draft); context.insert(StudyPreferences()); try context.save()
        return (card.id, after, log.id)
    }
}

extension StudyRepositoryTests {
    func testDeckPauseHierarchyQueuesCountsAndPreservesCards() throws {
        let repo = try fixture(), parent = try repo.decks()[0].id
        let child = try repo.createDeck(name: "Child", parentID: parent, now: now)
        let sibling = try repo.createDeck(name: "Sibling", parentID: parent, now: now)
        for id in [parent, child, sibling] { try repo.createNote(NoteInput(deckID: id, question: "Q", answer: "A"), now: now) }
        let original = try BackupData.capture(repo)
        try repo.setStudyPaused(deckID: child, paused: true, now: now)
        XCTAssertEqual(try repo.pausedDeckIDs(), [child])
        try repo.setStudyPaused(deckID: parent, paused: true, now: now)
        XCTAssertEqual(try repo.pausedDeckIDs(), [parent, child, sibling])
        let cards = try repo.queueCards(), settings = try repo.settings()
        let builder = ReviewQueueBuilder(calendar: repo.calendar)
        for mode in [StudyMode.review, .new, .mixed] {
            XCTAssertTrue(builder.queue(cards: cards, logs: [], settings: settings, mode: mode, touched: [], reviewStreak: 0, now: now).isEmpty)
        }
        XCTAssertEqual(try repo.homeSnapshot(now: now).counts.newRemaining, 0)
        XCTAssertTrue(NotificationPlanner(calendar: repo.calendar).plan(cards: cards, options: NotificationOptions(enabled: true), authorized: true, delivered: [], now: now).isEmpty)
        let widget = try WidgetProjection.make(cards: cards, logs: [], settings: WidgetProjectionSettings(settings), now: now, calendar: repo.calendar)
        XCTAssertTrue(widget.points.allSatisfy { $0.due == 0 && $0.newAvailable == 0 })
        let backup = try BackupData.capture(repo)
        XCTAssertEqual(backup.cards, original.cards); XCTAssertEqual(backup.notes, original.notes); XCTAssertEqual(backup.logs, original.logs)
        let forecast = try ReviewForecast.calculate(data: backup, deckID: nil, days: 7, now: now, calendar: repo.calendar)
        XCTAssertTrue(forecast.days.allSatisfy { $0.newCards == 0 && $0.reviews == 0 })
        try repo.setStudyPaused(deckID: parent, paused: false, now: now)
        XCTAssertEqual(try repo.pausedDeckIDs(), [child])
        XCTAssertEqual(try repo.counts(now: now).newRemaining, 2)
        try repo.moveDeck(id: child, name: "Moved", parentID: nil, learning: nil, now: now)
        XCTAssertEqual(try repo.pausedDeckIDs(), [child])
        try repo.setStudyPaused(deckID: child, paused: false, now: now)
        XCTAssertEqual(try repo.counts(now: now).newRemaining, 3)
    }

    func testDeckPauseKeepsDraftUndoAndRollsBackFailedSave() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        try repo.createNote(NoteInput(deckID: deck, question: "Q", answer: "A", responseMode: .typing), now: now)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(text: "my draft", revealed: true, now: now)
        let id = try XCTUnwrap(repo.session()?.cardID)
        try repo.setStudyPaused(deckID: deck, paused: true, now: now)
        XCTAssertEqual(try repo.session()?.typedDraft, "my draft")
        XCTAssertNil(try repo.presentation(now: now)?.card)
        XCTAssertThrowsError(try repo.grade(.good, now: now))
        XCTAssertThrowsError(try repo.resume(now: now))
        XCTAssertEqual(try repo.session()?.cardID, id)
        XCTAssertTrue(try repo.logs().isEmpty)
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.setStudyPaused(deckID: deck, paused: false, now: now))
        XCTAssertTrue(try repo.decks()[0].isStudyPaused)
        repo.save = { try $0.save() }
        try repo.setStudyPaused(deckID: deck, paused: false, now: now)
        try repo.resume(now: now)
        XCTAssertEqual(try repo.presentation(now: now)?.typedDraft, "my draft")
        try repo.grade(.good, now: now)
        try repo.setStudyPaused(deckID: deck, paused: true, now: now)
        try repo.undo(now: now)
        XCTAssertNil(try repo.presentation(now: now)?.card)
        XCTAssertEqual(try repo.session()?.cardID, id)
        XCTAssertTrue(try repo.logs().isEmpty)
        XCTAssertEqual(try repo.queueCards()[0].state, "new")
        try repo.setStudyPaused(deckID: deck, paused: false, now: now)
        XCTAssertEqual(try repo.presentation(now: now)?.card?.cardID, id)
    }

    func testV5MigrationPauseReopenAndBackupCompatibility() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Study.store")
        let old = try LegacyStudyFixture.write(url: url, schema: Schema(versionedSchema: StudySchemaV5.self), now: now, draftText: "pending")
        var deckID: UUID!
        do {
            let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: url))
            try repo.initialize(now: now)
            XCTAssertEqual(try repo.cards()[0].id, old.0); XCTAssertEqual(try repo.cards()[0].fsrsPayload, old.1)
            XCTAssertEqual(try repo.logs()[0].id, old.2); XCTAssertEqual(try repo.session()?.typedDraft, "pending")
            XCTAssertFalse(try repo.decks()[0].isStudyPaused)
            deckID = try repo.decks()[0].id
            try repo.setStudyPaused(deckID: deckID, paused: true, now: now)
        }
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: url))
        XCTAssertTrue(try repo.decks()[0].isStudyPaused)
        XCTAssertEqual(try repo.cards()[0].fsrsPayload, old.1)
        let backup = try BackupData.capture(repo)
        let bytes = try BackupArchive.create(data: backup, media: [:], now: now, appVersion: "test")
        let decoded = try BackupArchive.decode(bytes)
        let restoreLocation = StudyStorageLocation(canonicalStore: dir.appendingPathComponent("restore/Study.store"))
        let restored = StudyRepository(container: try BackupService.restore(decoded, location: restoreLocation, mediaStore: MediaStore(root: dir.appendingPathComponent("Media")), now: now))
        XCTAssertTrue(try restored.decks()[0].isStudyPaused)
        XCTAssertEqual(try restored.cards()[0].id, old.0)
        var legacy = backup; legacy.decks[0].isStudyPaused = nil
        let json = try JSONEncoder().encode(legacy)
        XCTAssertNil(try JSONDecoder().decode(BackupData.self, from: json).decks[0].isStudyPaused)
        let oldBackup = try BackupArchive.decode(BackupArchive.create(data: legacy, media: [:], now: now, appVersion: "legacy"))
        let oldLocation = StudyStorageLocation(canonicalStore: dir.appendingPathComponent("old-restore/Study.store"))
        let fresh = StudyRepository(container: try BackupService.restore(oldBackup, location: oldLocation, mediaStore: MediaStore(root: dir.appendingPathComponent("OldMedia")), now: now))
        XCTAssertFalse(try fresh.decks()[0].isStudyPaused)
    }

    func testDeckPauseResumesOverdueAndKeepsSuspensionImportsAndHomeDraft() throws {
        let repo = try fixture(), parent = try repo.decks()[0].id
        let child = try repo.createDeck(name: "Child", parentID: parent, now: now)
        for id in [parent, child] { try repo.createNote(NoteInput(deckID: id, question: "Q", answer: "A"), now: now) }
        let cards = try repo.cards(), scheduler = try ReviewScheduler()
        try repo.transaction {
            for card in cards {
                let transition = try scheduler.review(repo.snapshot(card), grade: .good, now: now.addingTimeInterval(-86400 * 10))
                card.fsrsPayload = try JSONEncoder().encode(transition.after)
                card.dueDate = try scheduler.summary(transition.after).dueDate
            }
            cards[1].isSuspended = true
        }
        let original = try BackupData.capture(repo)
        XCTAssertEqual(try repo.counts(now: now).due, 1)
        try repo.setStudyPaused(deckID: parent, paused: true, now: now)
        XCTAssertEqual(try repo.counts(now: now).due, 0)
        let forecast = try ReviewForecast.calculate(data: BackupData.capture(repo), deckID: nil, days: 7, now: now, calendar: repo.calendar)
        XCTAssertTrue(forecast.days.allSatisfy { $0.scheduled == 0 })
        try repo.setStudyPaused(deckID: parent, paused: false, now: now)
        XCTAssertEqual(try BackupData.capture(repo).cards, original.cards)
        XCTAssertEqual(try repo.counts(now: now).due, 1)
        XCTAssertTrue(try repo.cards().contains(where: \.isSuspended))
        try repo.setStudyPaused(deckID: child, paused: true, now: now)
        _ = try repo.importRows([ImportRow(line: 1, question: "Import", answer: "Answer")], deckID: child, kind: .basic, tagNames: [], action: .skip, source: "test", now: now)
        XCTAssertTrue(try repo.decks().first(where: { $0.id == child })!.isStudyPaused)
        XCTAssertEqual(try repo.counts(now: now).newRemaining, 0)
        let store = try StudyStore(container: repo.context.container, clock: { self.now })
        try store.repository.applyHomeScope(LearningScope(deckID: child)); try store.reload()
        XCTAssertTrue(store.homeStudyPaused)
        try store.repository.applyHomeScope(LearningScope()); try store.reload()
        store.start(.review)
        store.toggleStudyPaused(parent)
        XCTAssertTrue(store.sessionStudyPaused)
        if case .unavailable = store.homePrimaryAction {} else { XCTFail("Paused draft must not appear complete") }
        XCTAssertNotNil(try store.repository.session()?.cardID)
        store.toggleStudyPaused(parent)
        XCTAssertFalse(store.sessionStudyPaused)
    }

    func testDeckPauseThreeThousandCardsReusesProjectionAndHandlesCycles() throws {
        let repo = try fixture(), root = try repo.decks()[0].id
        let scheduler = try ReviewScheduler(), payload = try JSONEncoder().encode(scheduler.newCard(now: now))
        try repo.transaction {
            for index in 0..<3000 {
                let input = NoteInput(deckID: root, question: "Q\(index)", answer: "A")
                let note = Note(input: input, content: try StudyRepository.encodeContent(input), now: now)
                repo.context.insert(note)
                repo.context.insert(StudyCard(noteID: note.id, variantKey: "basic:front", payload: payload, now: now))
            }
        }
        _ = try repo.queueCards()
        let decodes = repo.queueStateDecodeCount
        try repo.setStudyPaused(deckID: root, paused: true, now: now)
        let started = Date()
        try repo.withStudyQueueReuse {
            let projections = repo.queueProjectionCount
            XCTAssertTrue(try repo.queueCards().allSatisfy(\.suspended))
            _ = try repo.queueCards()
            XCTAssertEqual(repo.queueProjectionCount, projections + 1)
        }
        XCTAssertEqual(repo.queueStateDecodeCount, decodes)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(DeckStudyEligibility.pausedIDs([(a, b, false), (b, a, true), (c, a, false)]), [a, b, c])
        XCTAssertTrue(DeckStudyEligibility.pausedIDs([(a, b, false), (b, a, false), (c, UUID(), false)]).isEmpty)
    }
}

extension StudyRepositoryTests {
    func testRiskPolicyPersistsAcrossGradeUndoAndRepositoryRestart() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        for index in 0..<4 {
            try repo.createNote(NoteInput(deckID: deck, question: "Q\(index)", answer: "A"), now: now)
        }
        let scheduler = try ReviewScheduler()
        let state = try scheduler.review(scheduler.newCard(now: now), grade: .easy, now: now).after
        let payload = try JSONEncoder().encode(state)
        let date = try scheduler.summary(state).dueDate.addingTimeInterval(86400)
        try repo.transaction {
            for card in try repo.cards() { card.fsrsPayload = payload; card.dueDate = try scheduler.summary(state).dueDate }
        }
        let before = try repo.cards().map { ($0.id, $0.fsrsPayload, $0.dueDate) }
        try repo.start(mode: .review, answerLimit: 0, policy: .forgettingRisk, now: date)
        let order = try XCTUnwrap(repo.options().activeSessionProgress?.reviewOrder)
        XCTAssertEqual(order, before.map { $0.0 }.sorted { $0.uuidString < $1.uuidString })
        let id = try XCTUnwrap(repo.session()?.cardID)
        try revealAndGrade(repo, grade: .again, date: date)
        XCTAssertEqual(try repo.options().activeSessionProgress?.reviewOrder, order)
        try repo.undo(now: date)
        XCTAssertEqual(try repo.session()?.cardID, id)
        XCTAssertTrue(try repo.logs().isEmpty)
        for value in before {
            let card = try XCTUnwrap(repo.card(value.0))
            XCTAssertEqual(card.fsrsPayload, value.1); XCTAssertEqual(card.dueDate, value.2)
        }
        try repo.setSessionActive(false, now: date)
        let restored = StudyRepository(container: repo.context.container)
        try restored.initialize(now: date)
        try restored.resume(now: date)
        XCTAssertEqual(try restored.session()?.cardID, id)
        XCTAssertEqual(try restored.options().activeSessionProgress?.reviewOrderPolicy, .forgettingRisk)
        XCTAssertEqual(try restored.options().activeSessionProgress?.reviewOrder, order)
        let legacy = try JSONDecoder().decode(StudySessionProgressSnapshot.self,
            from: Data(#"{"startSequence":0,"answerLimit":20}"#.utf8))
        XCTAssertNil(legacy.reviewOrderPolicy); XCTAssertNil(legacy.reviewOrder)
    }
}

extension StudyRepositoryTests {
    func testRiskPolicyThreeThousandCardsTenThousandHistoryComparison() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        let scheduler = try ReviewScheduler()
        let transition = try scheduler.review(scheduler.newCard(now: now), grade: .easy, now: now)
        let payload = try JSONEncoder().encode(transition.after)
        let due = try scheduler.summary(transition.after).dueDate
        try repo.transaction {
            for index in 0..<3000 {
                let input = NoteInput(deckID: deck, question: "Q\(index)", answer: "A")
                let note = Note(input: input, content: try StudyRepository.encodeContent(input), now: now)
                repo.context.insert(note)
                let card = StudyCard(noteID: note.id, variantKey: "basic:front", payload: payload, now: now)
                card.dueDate = due; repo.context.insert(card)
                if index == 0 {
                    for sequence in 1...10000 {
                        repo.context.insert(StudyReviewLog(card: card, transition: transition, before: payload, after: payload,
                            mode: .mental, durationMs: 0, wasNew: false, sequence: sequence))
                    }
                }
            }
        }
        _ = try repo.queueCards()
        let date = due.addingTimeInterval(86400)
        for policy in [ReviewOrderPolicy.traditional, .forgettingRisk] {
            _ = try repo.queueCards() // Same warm-cache baseline after the preceding Undo.
            let decodes = repo.queueStateDecodeCount, history = repo.fullHistoryFetchCount
            let begin = Date()
            try repo.withStudyQueueReuse { try repo.start(mode: .review, policy: policy, now: date) }
            let start = Date().timeIntervalSince(begin)
            let id = try XCTUnwrap(repo.session()?.cardID)
            let gradeBegin = Date()
            try repo.withStudyQueueReuse { try revealAndGrade(repo, grade: .good, date: date) }
            let grade = Date().timeIntervalSince(gradeBegin)
            let undoBegin = Date()
            try repo.withStudyQueueReuse { try repo.undo(now: date) }
            let undo = Date().timeIntervalSince(undoBegin)
            XCTAssertEqual(try repo.session()?.cardID, id)
            XCTAssertEqual(repo.fullHistoryFetchCount, history)
            XCTAssertEqual(repo.queueStateDecodeCount - decodes, 1)
            XCTAssertEqual(try repo.sessionProgress()?.answered, 0)
            print("Issue186 \(policy.rawValue) 3000/10000 start=\(start)s grade=\(grade)s undo=\(undo)s decodes=\(repo.queueStateDecodeCount - decodes) fullHistory=\(repo.fullHistoryFetchCount - history)")
        }
    }

    func testRiskPolicyUsesFSRSProbabilityAndUnrankablePredictionFallback() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        for index in 0..<3 { try repo.createNote(NoteInput(deckID: deck, question: "Q\(index)", answer: "A"), now: now) }
        let scheduler = try ReviewScheduler(), fresh = try scheduler.newCard(now: now)
        let first = try scheduler.review(fresh, grade: .good, now: now).after
        let weak = try scheduler.review(first, grade: .good, now: scheduler.summary(first).dueDate).after
        let strong = try scheduler.review(fresh, grade: .easy, now: now).after
        let date = now.addingTimeInterval(86400 * 30)
        let cards = try repo.cards().sorted { $0.id.uuidString < $1.id.uuidString }
        try repo.transaction {
            cards[0].fsrsPayload = try JSONEncoder().encode(strong); cards[0].dueDate = now
            cards[1].fsrsPayload = try JSONEncoder().encode(weak); cards[1].dueDate = now.addingTimeInterval(1)
            // A decodable review snapshot with no usable stability is not a
            // decode failure: only risk ranking falls back to its due-order slot.
            var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: strong.cardData) as? [String: Any])
            raw["stability"] = 0
            let unrankable = SchedulerSnapshot(schemaVersion: strong.schemaVersion,
                algorithmVersion: strong.algorithmVersion, cardData: try JSONSerialization.data(withJSONObject: raw))
            XCTAssertEqual(try scheduler.predictionState(unrankable).state, "review")
            XCTAssertFalse(try scheduler.predictionState(unrankable).canRankReview)
            cards[2].fsrsPayload = try JSONEncoder().encode(unrankable); cards[2].dueDate = now.addingTimeInterval(2)
        }
        XCTAssertLessThan(try scheduler.retrievability(weak, now: date), try scheduler.retrievability(strong, now: date))
        try repo.start(mode: .review, policy: .traditional, now: date)
        XCTAssertEqual(try repo.session()?.cardID, cards[0].id)
        try repo.start(mode: .review, policy: .forgettingRisk, now: date)
        XCTAssertEqual(try repo.options().activeSessionProgress?.reviewOrder, [cards[1].id, cards[0].id, cards[2].id])
        XCTAssertEqual(repo.reviewRankingFailureCount, 1)
        XCTAssertTrue(try repo.logs().isEmpty)
    }
}

extension StudyRepositoryTests {
    func testRiskPolicyDeckTagAndResponseScopeExcludeBeforeRanking() throws {
        let repo = try fixture(), parent = try repo.decks()[0].id
        let child = try repo.createDeck(name: "Child", parentID: parent, now: now)
        let outside = try repo.createDeck(name: "Other", now: now)
        let target = try repo.createNote(NoteInput(deckID: child, question: "Q", answer: "A", tagNames: ["target"]), now: now)
        try repo.createNote(NoteInput(deckID: child, question: "No tag", answer: "A"), now: now)
        try repo.createNote(NoteInput(deckID: outside, question: "Other", answer: "A", tagNames: ["target"]), now: now)
        let scheduler = try ReviewScheduler()
        let state = try scheduler.review(scheduler.newCard(now: now), grade: .easy, now: now).after
        let due = try scheduler.summary(state).dueDate
        try repo.transaction {
            for card in try repo.cards() { card.fsrsPayload = try JSONEncoder().encode(state); card.dueDate = due }
        }
        let tag = try XCTUnwrap(repo.tags().first?.id)
        let scope = LearningScope(deckID: parent, tagIDs: [tag])
        try repo.start(mode: .review, scope: scope, policy: .forgettingRisk, now: due)
        let id = try XCTUnwrap(repo.session()?.cardID)
        XCTAssertEqual(try repo.card(id)?.noteID, target)
        XCTAssertEqual(try repo.options().activeSessionProgress?.reviewOrder, [id])
        XCTAssertThrowsError(try repo.start(mode: .review, scope: scope, responseMode: .ordering, policy: .forgettingRisk, now: due))
        XCTAssertEqual(try repo.session()?.cardID, id)
    }
}

extension StudyRepositoryTests {
    func testCorruptSnapshotThrowsForQueueHomeAndBothPoliciesWithoutChangingData() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        try repo.createNote(NoteInput(deckID: deck, question: "Q", answer: "A"), now: now)
        let card = try XCTUnwrap(repo.cards().first)
        let scheduler = try ReviewScheduler()
        let valid = try scheduler.review(scheduler.newCard(now: now), grade: .easy, now: now).after
        try repo.transaction {
            card.fsrsPayload = try JSONEncoder().encode(valid)
            card.dueDate = try scheduler.summary(valid).dueDate
        }
        let date = card.dueDate.addingTimeInterval(1)
        try repo.start(mode: .review, now: date)
        let sessionID = try XCTUnwrap(repo.session()?.cardID)
        let invalid = [
            Data("broken".utf8),
            try JSONEncoder().encode(SchedulerSnapshot(schemaVersion: 1, algorithmVersion: "FSRS-6", cardData: Data("broken".utf8))),
            try JSONEncoder().encode(SchedulerSnapshot(schemaVersion: 999, algorithmVersion: "FSRS-6", cardData: valid.cardData))
        ]
        for payload in invalid {
            try repo.transaction { card.fsrsPayload = payload }
            let before = (card.id, card.fsrsPayload, card.dueDate, card.updatedAt)
            // The warmed cache must not hide a newly corrupted persisted payload.
            XCTAssertThrowsError(try repo.queueCards())
            XCTAssertThrowsError(try repo.counts(now: date))
            for policy in [ReviewOrderPolicy.traditional, .forgettingRisk] {
                XCTAssertThrowsError(try repo.start(mode: .review, policy: policy, now: date))
                XCTAssertEqual(try repo.session()?.cardID, sessionID)
            }
            XCTAssertEqual(card.id, before.0); XCTAssertEqual(card.fsrsPayload, before.1)
            XCTAssertEqual(card.dueDate, before.2); XCTAssertEqual(card.updatedAt, before.3)
            XCTAssertEqual(repo.reviewRankingFailureCount, 0)
            XCTAssertTrue(try repo.logs().isEmpty)
        }
        try repo.transaction { card.fsrsPayload = try JSONEncoder().encode(valid) }
        XCTAssertEqual(try repo.queueCards().first?.state, "review")
        let decodes = repo.queueStateDecodeCount
        _ = try repo.queueCards()
        XCTAssertEqual(repo.queueStateDecodeCount, decodes)
    }
}


extension StudyRepositoryTests {
    private func dueReviewFixture(_ count: Int) throws -> StudyRepository {
        let repo = try fixture()
        let scheduler = try ReviewScheduler()
        let past = now.addingTimeInterval(-864000)
        let deck = try repo.decks()[0].id
        try repo.transaction {
            for index in 0..<count {
                let date = past.addingTimeInterval(Double(index))
                let state = try scheduler.review(scheduler.newCard(now: date), grade: .easy, now: date).after
                let input = NoteInput(deckID: deck, question: "Review \(index)", answer: "A")
                let note = Note(input: input, content: try StudyRepository.encodeContent(input), now: date)
                repo.context.insert(note)
                let card = StudyCard(noteID: note.id, variantKey: "basic:front", payload: try JSONEncoder().encode(state), now: date)
                card.dueDate = try scheduler.summary(state).dueDate
                repo.context.insert(card)
            }
        }
        return repo
    }

    func testFixedReviewSetCountsAndCapsForBothPolicies() throws {
        for count in [0, 1, 5, 20, 200] {
            let repo = try dueReviewFixture(count)
            for cap in [10, 20, 30, 0] {
                for policy in [ReviewOrderPolicy.traditional, .forgettingRisk] {
                    if count == 0 {
                        XCTAssertThrowsError(try repo.start(mode: .review, answerLimit: cap, policy: policy, now: now))
                        XCTAssertNil(try repo.session())
                        continue
                    }
                    try repo.start(mode: .review, answerLimit: cap, policy: policy, now: now)
                    let expected = cap == 0 ? count : min(count, cap)
                    let saved = try XCTUnwrap(repo.options().activeSessionProgress)
                    XCTAssertEqual(saved.answerLimit, expected)
                    XCTAssertEqual(saved.reviewSetLimit, cap)
                    XCTAssertEqual(saved.reviewOrder?.count, expected)
                    XCTAssertEqual(Set(saved.reviewOrder ?? []).count, expected)
                    XCTAssertEqual(try repo.presentation(now: now)?.visibleAnswerTotal, expected)
                    if policy == .traditional {
                        let ordered = try repo.cards().sorted { $0.dueDate < $1.dueDate }.prefix(expected).map(\.id)
                        XCTAssertEqual(saved.reviewOrder, ordered)
                    }
                }
            }
        }
    }

    func testFixedReviewSetGradesEachCardOnceAndKeepsAgainDueForNextSet() throws {
        for policy in [ReviewOrderPolicy.traditional, .forgettingRisk] {
            let repo = try dueReviewFixture(5)
            try repo.start(mode: .review, answerLimit: 20, policy: policy, now: now)
            let order = try XCTUnwrap(repo.options().activeSessionProgress?.reviewOrder)
            var date = now
            for (index, id) in order.enumerated() {
                XCTAssertEqual(try repo.session()?.cardID, id)
                XCTAssertEqual(try repo.presentation(now: date)?.visibleAnswerTotal, 5)
                try revealAndGrade(repo, grade: .again, date: date)
                XCTAssertEqual(try repo.sessionProgress()?.answered, index + 1)
                date = try XCTUnwrap(repo.card(id)?.dueDate).addingTimeInterval(1)
                // Previous Again steps are due; they must not displace untouched cards.
            }
            XCTAssertNil(try repo.session()?.cardID)
            XCTAssertEqual(try repo.sessionProgress(), SessionAnswerProgress(answered: 5, limit: 5))
            XCTAssertEqual(try repo.presentation(now: date)?.emptyState?.reason, .complete)
            XCTAssertEqual(try repo.logs().map(\.cardID), order)
            XCTAssertFalse(try repo.advanceWaitingSession(now: date))
            let last = try XCTUnwrap(order.last)
            let before = try XCTUnwrap(repo.logs().last?.fsrsBefore)
            try repo.undo(now: date)
            XCTAssertEqual(try repo.card(last)?.fsrsPayload, before)
            XCTAssertEqual(try repo.session()?.cardID, last)
            XCTAssertEqual(try repo.sessionProgress()?.answered, 4)
            try revealAndGrade(repo, grade: .again, date: date)
            date = try XCTUnwrap(repo.card(last)?.dueDate).addingTimeInterval(1)
            try repo.startAnotherSession(now: date)
            XCTAssertEqual(try repo.options().activeSessionProgress?.reviewSetLimit, 20)
            XCTAssertEqual(try repo.sessionProgress()?.limit, 5)
            XCTAssertNotNil(try repo.session()?.cardID)
        }
    }

    func testFixedReviewSetRollbackRestartBackupAndExclusions() async throws {
        let repo = try dueReviewFixture(5)
        try repo.start(mode: .review, answerLimit: 0, now: now)
        let order = try XCTUnwrap(repo.options().activeSessionProgress?.reviewOrder)
        try repo.updateDraft(revealed: true, now: now)
        let before = try BackupData.capture(repo).canonical()
        repo.save = { _ in throw Failure.save }
        do {
            try repo.grade(.again, now: now)
            XCTFail("Failed save must throw")
        } catch Failure.save { }
        repo.save = { try $0.save() }
        XCTAssertEqual(try BackupData.capture(repo).canonical(), before)
        try repo.grade(.again, now: now)
        try repo.undo(now: now)
        XCTAssertEqual(try repo.session()?.cardID, order[0])
        XCTAssertFalse(try XCTUnwrap(repo.session()).touchedCardIDs.contains(order[0]))
        try revealAndGrade(repo, grade: .good, date: now)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = MediaStore(root: root.appendingPathComponent("Media"))
        let backup = try BackupArchive.decode(await BackupService.export(repository: repo, now: now, appVersion: "212"))
        let restored = StudyRepository(container: try BackupService.restore(backup,
            location: StudyStorageLocation(canonicalStore: root.appendingPathComponent("Study.store")), mediaStore: media, now: now), mediaStore: media)
        try restored.initialize(now: now)
        try restored.resume(now: now)
        XCTAssertEqual(try restored.options().activeSessionProgress?.reviewOrder, order)
        XCTAssertEqual(try restored.sessionProgress(), SessionAnswerProgress(answered: 1, limit: 5))
        XCTAssertEqual(try restored.session()?.cardID, order[1])
        // Late entrants must not grow this set. Removed/held/paused targets count as no answers.
        let lateNote = try create(restored)
        try restored.transaction {
            let source = try XCTUnwrap(restored.card(order[2]))
            let late = try XCTUnwrap(restored.cards().first { $0.noteID == lateNote })
            late.fsrsPayload = source.fsrsPayload; late.dueDate = source.dueDate
            if let card = try restored.card(order[2]) { restored.context.delete(card) }
            try restored.card(order[3])?.isSuspended = true
        }
        try revealAndGrade(restored, grade: .easy, date: now)
        XCTAssertEqual(try restored.session()?.cardID, order[4])
        let deck = try restored.decks()[0].id
        try restored.setStudyPaused(deckID: deck, paused: true, now: now)
        XCTAssertThrowsError(try revealAndGrade(restored, grade: .good, date: now))
        XCTAssertEqual(try restored.sessionProgress()?.answered, 2)
        try restored.setStudyPaused(deckID: deck, paused: false, now: now)
        try restored.transaction { try restored.card(order[4])?.isSuspended = true }
        try restored.resume(now: now)
        XCTAssertNil(try restored.session()?.cardID)
        XCTAssertEqual(try restored.presentation(now: now)?.visibleAnswerTotal, 5)
        XCTAssertEqual(try restored.presentation(now: now)?.emptyState?.title, "今回はここまで")
    }

    func testLegacyReviewSessionKeepsDynamicRelearning() throws {
        let repo = try dueReviewFixture(1)
        try repo.start(mode: .review, answerLimit: 20, now: now)
        var options = try repo.options()
        options.activeSessionProgress?.reviewSetLimit = nil
        options.activeSessionProgress?.reviewOrder = nil
        options.activeSessionProgress?.answerLimit = 20
        try repo.updateOptions(options)
        let id = try XCTUnwrap(repo.session()?.cardID)
        try revealAndGrade(repo, grade: .again, date: now)
        let due = try XCTUnwrap(repo.card(id)?.dueDate)
        try repo.resume(now: due)
        XCTAssertEqual(try repo.session()?.cardID, id)
        XCTAssertEqual(try repo.sessionProgress(), SessionAnswerProgress(answered: 1, limit: 20))
        XCTAssertEqual(try repo.presentation(now: due)?.visibleAnswerTotal, 20)
    }
}

extension StudyRepositoryTests {
    func testFixedReviewSetOneAndHundredCardsFinishAtSelectedCount() throws {
        for count in [1, 100] {
            let repo = try dueReviewFixture(count)
            try repo.start(mode: .review, answerLimit: 20, now: now)
            let order = try XCTUnwrap(repo.options().activeSessionProgress?.reviewOrder)
            XCTAssertEqual(order.count, min(count, 20))
            for id in order {
                XCTAssertEqual(try repo.session()?.cardID, id)
                try revealAndGrade(repo, grade: .hard, date: now)
            }
            XCTAssertEqual(try repo.sessionProgress(), SessionAnswerProgress(answered: order.count, limit: order.count))
            XCTAssertNil(try repo.session()?.cardID)
            XCTAssertEqual(try repo.logs().map(\.cardID), order)
        }
    }

    func testUnlimitedFixedReviewBackupAcceptsMoreThan500TargetsAndRejectsCorruptSet() throws {
        let repo = try dueReviewFixture(501)
        try repo.start(mode: .review, answerLimit: 0, now: now)
        XCTAssertEqual(try repo.presentation(now: now)?.visibleAnswerTotal, 501)
        let bytes = try BackupArchive.create(data: BackupData.capture(repo), media: [:], now: now, appVersion: "212")
        var backup = try BackupArchive.decode(bytes).data
        var options = try JSONDecoder().decode(StudyOptions.self, from: backup.options[0].payload)
        XCTAssertEqual(options.activeSessionProgress?.reviewOrder?.count, 501)
        options.activeSessionProgress?.reviewOrder?.append(try XCTUnwrap(repo.session()?.cardID))
        backup.options[0].payload = try JSONEncoder().encode(options)
        XCTAssertThrowsError(try BackupValidation.validate(backup, media: [:]))
    }
}
