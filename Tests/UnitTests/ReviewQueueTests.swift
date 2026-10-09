import XCTest
@testable import AnkiIOS

final class ReviewQueueTests: XCTestCase {
    func testHiddenImagesNeverHideImageOcclusionAndDefaultsStayCompatible() {
        let defaults = ReviewAppearance()
        XCTAssertFalse(defaults.gesturesEnabled); XCTAssertTrue(defaults.animationsEnabled)
        XCTAssertEqual(defaults.textSize, .standard); XCTAssertFalse(defaults.answerFirst)
        XCTAssertTrue(defaults.showsImage(for: .basic))
        var hidden = defaults; hidden.imageDisplay = .hidden
        XCTAssertFalse(hidden.showsImage(for: .basic))
        XCTAssertTrue(hidden.showsImage(for: .imageOcclusion))
    }
    func testSwipeDirectionsThresholdDiagonalAndRetreat() {
        XCTAssertEqual(ReviewSwipeAction.decide(x: 96, y: 0, revealed: false), .reveal)
        XCTAssertNil(ReviewSwipeAction.decide(x: 95, y: 0, revealed: false))
        XCTAssertNil(ReviewSwipeAction.decide(x: -120, y: 0, revealed: false))
        XCTAssertNil(ReviewSwipeAction.decide(x: 0, y: -120, revealed: false))
        XCTAssertNil(ReviewSwipeAction.decide(x: 120, y: 100, revealed: true))
        XCTAssertEqual(ReviewSwipeAction.decide(x: 120, y: 80, revealed: true), .grade(.good))
        XCTAssertEqual(ReviewSwipeAction.decide(x: -120, y: 0, revealed: true), .grade(.again))
        XCTAssertEqual(ReviewSwipeAction.decide(x: 0, y: 120, revealed: true), .grade(.hard))
        XCTAssertEqual(ReviewSwipeAction.decide(x: 0, y: -120, revealed: true), .grade(.easy))
        XCTAssertNil(ReviewSwipeAction.decide(x: 20, y: 0, revealed: true)) // Returned near the start.
        XCTAssertNil(ReviewSwipeAction.decide(x: .infinity, y: 0, revealed: true))
    }
    func testSwipeGateRejectsChangedCardChangedRevealAndQuickRepeat() {
        var gate = ReviewSwipeGate()
        let id = UUID(), now = Date(timeIntervalSince1970: 100)
        gate.begin(id: id, revealed: false)
        XCTAssertNil(gate.finish(id: UUID(), revealed: false, x: 120, y: 0, now: now))
        gate.begin(id: id, revealed: false)
        XCTAssertNil(gate.finish(id: id, revealed: true, x: 120, y: 0, now: now))
        gate.begin(id: id, revealed: false); gate.invalidate()
        gate.begin(id: id, revealed: true)
        XCTAssertNil(gate.finish(id: id, revealed: true, x: 120, y: 0, now: now))
        gate.begin(id: id, revealed: false); gate.cancel()
        XCTAssertNil(gate.finish(id: id, revealed: false, x: 120, y: 0, now: now))
        gate.begin(id: id, revealed: false)
        XCTAssertEqual(gate.finish(id: id, revealed: false, x: 120, y: 0, now: now), .reveal)
        gate.begin(id: id, revealed: true)
        XCTAssertNil(gate.finish(id: id, revealed: true, x: 120, y: 0, now: now.addingTimeInterval(0.1)))
        gate.begin(id: id, revealed: true)
        XCTAssertEqual(gate.finish(id: id, revealed: true, x: 120, y: 0, now: now.addingTimeInterval(1)), .grade(.good))
        XCTAssertNil(gate.finish(id: id, revealed: true, x: 120, y: 0, now: now.addingTimeInterval(2)))
    }
    func calendar(_ zone: String = "Asia/Tokyo") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func card(_ state: String, due: Date, suspended: Bool = false) -> QueueCard {
        QueueCard(id: UUID(), state: state, due: due, createdAt: due, suspended: suspended)
    }

    func testFourAMBoundaryAndUniqueGoalCount() {
        let before = date("2026-10-08T03:59:59+09:00"), after = date("2026-10-08T04:00:00+09:00")
        let fresh = card("new", due: before)
        let logs = [QueueLog(cardID: fresh.id, reviewedAt: before, wasNew: true),
                    QueueLog(cardID: fresh.id, reviewedAt: before, wasNew: false)]
        let builder = ReviewQueueBuilder(calendar: calendar(), shuffled: { $0 })
        var settings = StudySettings(); settings.dailyNewLimit = 1
        let previous = builder.counts(cards: [fresh], logs: logs, settings: settings, now: before)
        XCTAssertEqual(previous.newRemaining, 0)
        XCTAssertEqual(previous.learnedToday, 1)
        XCTAssertEqual(previous.answerCount, 2)
        let next = builder.counts(cards: [fresh], logs: logs, settings: settings, now: after)
        XCTAssertEqual(next.newRemaining, 1)
        XCTAssertEqual(next.learnedToday, 0)
    }

    func testSharedNewLimitAcrossAllModesAndSuspension() {
        let now = date("2026-10-08T12:00:00+09:00")
        let reviewed = card("review", due: now), fresh = card("new", due: now)
        let suspended = card("new", due: now, suspended: true)
        let logs = [QueueLog(cardID: reviewed.id, reviewedAt: now, wasNew: true)]
        var settings = StudySettings(); settings.dailyNewLimit = 1
        let builder = ReviewQueueBuilder(calendar: calendar(), shuffled: { $0 })
        for mode in StudyMode.allCases {
            let queue = builder.queue(cards: [reviewed, fresh, suspended], logs: logs, settings: settings,
                                      mode: mode, touched: [], reviewStreak: 0, now: now)
            XCTAssertFalse(queue.contains(fresh.id))
            XCTAssertFalse(queue.contains(suspended.id))
        }
        XCTAssertEqual(builder.queue(cards: [reviewed], logs: logs, settings: settings,
                                     mode: .review, touched: [], reviewStreak: 0, now: now), [reviewed.id])
    }

    func testOverdueAndShortStepsAcrossDays() {
        let now = date("2026-10-08T12:00:00+09:00")
        let overdue = card("review", due: now.addingTimeInterval(-86400 * 3))
        let short = card("learning", due: now)
        let future = card("relearning", due: now.addingTimeInterval(600))
        let builder = ReviewQueueBuilder(shuffled: { $0 })
        let cards = [overdue, short, future]
        XCTAssertEqual(builder.queue(cards: cards, logs: [], settings: StudySettings(), mode: .review,
                                     touched: [], reviewStreak: 0, now: now), [short.id, overdue.id])
        XCTAssertEqual(builder.queue(cards: cards, logs: [], settings: StudySettings(), mode: .new,
                                     touched: [short.id], reviewStreak: 0, now: now), [short.id])
        XCTAssertTrue(builder.queue(cards: cards, logs: [], settings: StudySettings(), mode: .review,
                                    touched: [], reviewStreak: 0, now: now.addingTimeInterval(86400)).contains(overdue.id))
    }

    func testMixedRatioAndGoalDoesNotLimitReviews() {
        let now = date("2026-10-08T12:00:00+09:00")
        let reviews = (0..<6).map { i in card("review", due: now.addingTimeInterval(Double(i - 10))) }
        let fresh = (0..<2).map { i in card("new", due: now.addingTimeInterval(Double(i))) }
        var settings = StudySettings(); settings.dailyGoal = 1
        let logs = [QueueLog(cardID: UUID(), reviewedAt: now, wasNew: false)]
        let builder = ReviewQueueBuilder(shuffled: { $0 })
        let queue = builder.queue(cards: reviews + fresh, logs: logs, settings: settings,
                                  mode: .mixed, touched: [], reviewStreak: 0, now: now)
        XCTAssertEqual(queue, reviews.prefix(3).map(\.id) + [fresh[0].id] + reviews.suffix(3).map(\.id) + [fresh[1].id])
        XCTAssertEqual(builder.queue(cards: reviews + fresh, logs: logs, settings: settings,
                                     mode: .mixed, touched: [], reviewStreak: 3, now: now).first, fresh[0].id)
    }

    func testTimeZoneAndDSTCalendarDays() {
        let la = StudyDay(calendar: calendar("America/Los_Angeles"))
        let window = la.interval(containing: date("2026-03-07T12:00:00-08:00"))
        XCTAssertEqual(window.end.timeIntervalSince(window.start), 23 * 3600)
        let tokyo = StudyDay(calendar: calendar())
        XCTAssertNotEqual(tokyo.interval(containing: window.start).start, window.start)
    }
}
