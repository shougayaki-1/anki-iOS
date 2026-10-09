import XCTest
@testable import AnkiIOS

final class NotificationPlannerTests: XCTestCase {
    func testTestNamespacesAreIsolatedAndIdentifiersUseGregorianDates() {
        var japanese = Calendar(identifier: .japanese); japanese.timeZone = calendar.timeZone
        let now = date(8, 10)
        let production = NotificationPlanner(calendar: japanese).plan(cards: [card(now)], options: NotificationOptions(enabled: true), authorized: true, delivered: [], now: now)
        XCTAssertEqual(production.first?.id, "review-2026-10-08")
        let test = NotificationPlanner(calendar: japanese, identifierPrefix: "review-test-fixture-")
        let isolated = test.plan(cards: [card(now)], options: NotificationOptions(enabled: true), authorized: true, delivered: [], now: now)
        XCTAssertTrue(test.difference(pending: production, desired: []).remove.isEmpty)
        XCTAssertTrue(NotificationPlanner().difference(pending: isolated, desired: []).remove.isEmpty)
    }
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Tokyo")!; return value
    }
    func date(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    func card(_ due: Date, state: String = "review", suspended: Bool = false) -> QueueCard {
        QueueCard(id: UUID(), state: state, due: due, createdAt: date(1, 0), suspended: suspended)
    }
    func testNewSuspendedDisabledAndDeniedHaveNoNotifications() {
        let planner = NotificationPlanner(calendar: calendar), now = date(8, 10)
        let on = NotificationOptions(enabled: true)
        XCTAssertTrue(planner.plan(cards: [card(now, state: "new")], options: on, authorized: true, delivered: [], now: now).isEmpty)
        XCTAssertTrue(planner.plan(cards: [card(now, suspended: true)], options: on, authorized: true, delivered: [], now: now).isEmpty)
        XCTAssertTrue(planner.plan(cards: [card(now)], options: NotificationOptions(), authorized: true, delivered: [], now: now).isEmpty)
        XCTAssertTrue(planner.plan(cards: [card(now)], options: on, authorized: false, delivered: [], now: now).isEmpty)
    }
    func testActualDueTimeAndOverdueAcrossThirtyDayHorizon() {
        let planner = NotificationPlanner(calendar: calendar), now = date(8, 10)
        let options = NotificationOptions(enabled: true)
        let morning = planner.plan(cards: [card(date(9, 11))], options: options, authorized: true, delivered: [], now: now)
        XCTAssertEqual(morning.first?.date, date(9, 20)); XCTAssertEqual(morning.count, 29)
        let late = planner.plan(cards: [card(date(9, 21))], options: options, authorized: true, delivered: [], now: now)
        XCTAssertEqual(late.first?.date, date(10, 20)); XCTAssertEqual(late.count, 28)
        let overdue = planner.plan(cards: [card(date(1, 11))], options: options, authorized: true, delivered: [], now: now)
        XCTAssertEqual(overdue.count, 30)
        XCTAssertEqual(Set(overdue.map(\.id)).count, 30)
        XCTAssertEqual(overdue[2].id, "review-2026-10-10")
        let afterTime = planner.plan(cards: [card(now)], options: options, authorized: true, delivered: [], now: date(8, 21))
        XCTAssertEqual(afterTime.first?.date, date(9, 20)); XCTAssertEqual(afterTime.count, 30)
    }
    func testCompletionCancelsUndoReschedulesDeliveredNotRepeatedAndUnrelatedKept() {
        let planner = NotificationPlanner(calendar: calendar), now = date(8, 18)
        let options = NotificationOptions(enabled: true)
        let pending = planner.plan(cards: [card(now)], options: options, authorized: true, delivered: [], now: now)
        let completed = planner.plan(cards: [card(date(10, 11))], options: options, authorized: true, delivered: [], now: now)
        let diff = planner.difference(pending: pending, desired: completed)
        XCTAssertTrue(diff.remove.contains("review-2026-10-08"))
        XCTAssertTrue(diff.add.isEmpty)
        let undone = planner.difference(pending: completed, desired: pending)
        XCTAssertTrue(undone.add.contains { $0.id == "review-2026-10-08" })
        let delivered = planner.plan(cards: [card(now)], options: options, authorized: true, delivered: ["review-2026-10-08"], now: now)
        XCTAssertEqual(delivered.count, 29)
        XCTAssertTrue(planner.difference(pending: [PlannedNotification(id: "other", date: now, timeZoneID: "Asia/Tokyo")], desired: []).remove.isEmpty)
    }
    func testDSTAndTimeZoneChangeReplaceTriggersUsingLocalCalendar() {
        var ny = calendar; ny.timeZone = TimeZone(identifier: "America/New_York")!
        let now = ny.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 10))!
        let options = NotificationOptions(enabled: true)
        let pending = NotificationPlanner(calendar: ny).plan(cards: [card(now)], options: options, authorized: true, delivered: [], now: now)
        XCTAssertEqual(pending[1].date.timeIntervalSince(pending[0].date), 23 * 3600)
        let desired = NotificationPlanner(calendar: calendar).plan(cards: [card(now)], options: options, authorized: true, delivered: [], now: now)
        let diff = NotificationPlanner().difference(pending: pending, desired: desired)
        XCTAssertFalse(diff.remove.isEmpty); XCTAssertFalse(diff.add.isEmpty)
        XCTAssertEqual(desired.first?.timeZoneID, "Asia/Tokyo")
    }
}
