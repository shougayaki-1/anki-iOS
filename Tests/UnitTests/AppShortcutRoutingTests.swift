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
