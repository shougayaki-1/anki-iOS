import XCTest
@testable import AnkiIOS

@MainActor
final class AppShortcutRoutingTests: XCTestCase {
    func testSharedWorkspaceAndIndependentWindowActivityCannotPauseOtherWindow() {
        XCTAssertTrue(AppWorkspace.forWindow() === AppWorkspace.forWindow())
        var activity = WindowActivity()
        let first = UUID(), second = UUID()
        XCTAssertFalse(activity.isActive)
        activity.set(id: first, active: true); activity.set(id: second, active: true)
        activity.set(id: first, active: false)
        XCTAssertTrue(activity.isActive)
        activity.set(id: first, active: false) // repeated disappearance is idempotent
        XCTAssertTrue(activity.isActive)
        activity.set(id: second, active: false)
        XCTAssertFalse(activity.isActive)
    }

    func testTwoWindowsCannotCommitTheSameRevealedCardTwice() throws {
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        let deck = try store.repository.decks()[0].id
        for index in 0..<2 { try store.repository.createNote(NoteInput(deckID: deck, question: "Window \(index)", answer: "Answer"), now: store.clock()) }
        try store.reload(); store.start(.new); store.draft(revealed: true)
        store.grade(.easy)
        let saved = try BackupData.capture(store.repository).canonical()
        store.grade(.easy) // stale grade button in another scene
        XCTAssertEqual(try BackupData.capture(store.repository).canonical(), saved)
        XCTAssertEqual(try store.repository.logs().count, 1)
        XCTAssertNotNil(store.failure)
    }

    func testFourAppShortcutsAreRegistered() {
        XCTAssertEqual(StudyAppShortcuts.appShortcuts.count, 4)
    }

    func testSessionCannotBeReplacedWithoutConfirmation() {
        for mode in [StudyMode.review, .new] {
            XCTAssertEqual(ShortcutStudyDecision.resolve(mode: mode, sessionExists: true,
                canResume: true, canStart: true), .resume)
            XCTAssertEqual(ShortcutStudyDecision.resolve(mode: mode, sessionExists: true,
                canResume: false, canStart: true), .showExistingSession)
            XCTAssertEqual(ShortcutStudyDecision.resolve(mode: mode, sessionExists: false,
                canResume: false, canStart: true), .start(mode))
            XCTAssertEqual(ShortcutStudyDecision.resolve(mode: mode, sessionExists: false,
                canResume: false, canStart: false), .unavailable)
        }
    }

    func testRequestsSurviveColdLaunchAndAreConsumedOnce() {
        let suite = "issue18-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sender = ShortcutNavigation(defaults: defaults)
        sender.submit(.study(.new))
        let receiver = ShortcutNavigation(defaults: defaults)
        XCTAssertEqual(receiver.take(), .study(.new))
        XCTAssertNil(receiver.take())
        XCTAssertNil(ShortcutNavigation(defaults: defaults).pending)
        sender.submit(.progress)
        XCTAssertEqual(receiver.take(), .progress)
        let id = UUID()
        sender.submit(.deck(id))
        XCTAssertEqual(receiver.take(), .deck(id))
    }

    func testSameNameDecksAreSelectedByStableIDs() {
        let a = ShortcutDeckEntity(id: UUID().uuidString, path: "A / 共通")
        let b = ShortcutDeckEntity(id: UUID().uuidString, path: "B / 共通")
        let c = ShortcutDeckEntity(id: UUID().uuidString, path: "共通")
        let selected = ShortcutDeckDirectory.matching([b.id, a.id, UUID().uuidString, c.id], in: [a, b, c])
        XCTAssertEqual(selected.map(\.id), [b.id, a.id, c.id])
        XCTAssertEqual(Set(selected.map(\.path)).count, 3)
    }
}

@MainActor
final class ReviewEditingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testEditingPreservesCardAndScheduleAndRestartsPresentation() throws {
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
        let deck = try XCTUnwrap(store.repository.decks().first).id
        let id = try store.repository.createNote(NoteInput(deckID: deck, question: "Before", answer: "Answer"), now: now)
        try store.reload(); store.start(.new); store.draft(revealed: true); store.grade(.good)
        let studied = try XCTUnwrap(store.repository.cards().first)
        let dueNow = studied.dueDate.addingTimeInterval(1)
        try store.repository.start(mode: .review, now: dueNow)
        try store.reload(); store.draft(text: "draft", revealed: true)
        let history = try store.repository.logs().map(\.id)
        let card = try XCTUnwrap(store.review?.card)
        let original = try XCTUnwrap(store.repository.card(card.cardID))
        let payload = original.fsrsPayload, due = original.dueDate
        let progress = try store.repository.sessionProgress()
        let draftKey = "edit:\(id.uuidString)"
        let libraryDraft = NoteInput(deckID: deck, question: "Unsaved library edit", answer: "Draft answer")
        try store.repository.saveEditorDraft(key: draftKey, input: libraryDraft, now: now)
        try store.repository.updateNote(id: id, input: NoteInput(deckID: deck, question: "After", answer: "Answer", hint: "Hint"), duringReview: true, now: now)
        try store.reload()
        XCTAssertEqual(store.review?.card?.cardID, card.cardID)
        XCTAssertEqual(store.review?.card?.content.question, "After")
        XCTAssertEqual(original.fsrsPayload, payload); XCTAssertEqual(original.dueDate, due)
        XCTAssertEqual(try store.repository.logs().map(\.id), history)
        XCTAssertEqual(try store.repository.sessionProgress()?.answered, progress?.answered)
        XCTAssertEqual(store.review?.typedDraft, "")
        XCTAssertEqual(store.review?.answerRevealed, false)
        XCTAssertEqual(store.review?.canUndo, false)
        XCTAssertEqual(try store.repository.editorDraft(key: draftKey), libraryDraft)
    }

    func testStructureChangesAndSaveFailuresPreserveSessionAndNote() throws {
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
        let deck = try XCTUnwrap(store.repository.decks().first).id
        let id = try store.repository.createNote(NoteInput(deckID: deck, kind: .cloze, question: "{{c1::Before}}", answer: ""), now: now)
        try store.reload(); store.start(.new); store.draft(text: "draft", revealed: true)
        let before = try BackupData.capture(store.repository).canonical()
        XCTAssertThrowsError(try store.repository.updateNote(id: id, input: NoteInput(deckID: deck, kind: .cloze, question: "{{c2::After}}", answer: ""), duringReview: true, now: now))
        XCTAssertEqual(try BackupData.capture(store.repository).canonical(), before)
        XCTAssertThrowsError(try store.repository.updateNote(id: id, input: NoteInput(deckID: deck, kind: .cloze, question: "{{c1::After}}", answer: ""), resetHistory: true, duringReview: true, now: now))
        store.repository.save = { _ in throw StudyError.invalidContent }
        XCTAssertThrowsError(try store.repository.updateNote(id: id, input: NoteInput(deckID: deck, kind: .cloze, question: "{{c1::After}}", answer: ""), duringReview: true, now: now))
        XCTAssertEqual(try BackupData.capture(store.repository).canonical(), before)
    }
}
