import XCTest
@testable import AnkiIOS

@MainActor
final class AppShortcutRoutingTests: XCTestCase {
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
