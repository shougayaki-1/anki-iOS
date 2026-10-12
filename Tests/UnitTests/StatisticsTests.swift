import XCTest
@testable import AnkiIOS

final class StatisticsTests: XCTestCase {
    func testEmptyWeakPracticeNeverReportsCompletion() {
        var session = WeakPracticeSession(cards: [])
        XCTAssertEqual(session.phase, .empty)
        XCTAssertEqual(session.completedCount, 0)
        session.reveal(); session.next(); session.previous(); session.restart()
        XCTAssertEqual(session.phase, .empty)
        XCTAssertNil(session.current)
        XCTAssertFalse(session.revealed)
    }

    func testWeakEvidenceThresholdsAndNoFutureOrInsufficientHistory() {
        let now = Date(timeIntervalSince1970: 1000), id = UUID()
        func log(_ grade: ReviewGrade, _ offset: Double = 0) -> StatisticLog {
            StatisticLog(cardID: id, date: now.addingTimeInterval(offset), grade: grade, durationMs: 0)
        }
        XCTAssertNil(WeakCardEvidence.evaluate(logs: [], difficulty: 10, retrievability: 0.1, now: now))
        XCTAssertNil(WeakCardEvidence.evaluate(logs: [log(.good)], difficulty: 10, retrievability: 0.1, now: now))
        XCTAssertNil(WeakCardEvidence.evaluate(logs: [log(.again, 1)], difficulty: 10, retrievability: 0.1, now: now))
        XCTAssertEqual(WeakCardEvidence.evaluate(logs: [log(.again)], difficulty: 1, retrievability: 1, now: now)?.reasons, ["直近の評価がAgain"])
        let evidence = WeakCardEvidence.evaluate(logs: [log(.again, -2), log(.again, -1), log(.good)], difficulty: 8, retrievability: 0.74, now: now)
        XCTAssertEqual(evidence?.reasons.count, 4)
        XCTAssertNil(WeakCardEvidence.evaluate(logs: [log(.good, -2), log(.good, -1), log(.good)], difficulty: 7.9, retrievability: 0.75, now: now))
    }

    func testFourAMUniqueCountsStreakRatingsAndRetention() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func date(_ day: Int, _ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
        let id = UUID()
        let logs = [StatisticLog(cardID: id, date: date(7, 12), grade: .good, durationMs: 1000),
                    StatisticLog(cardID: id, date: date(8, 3), grade: .again, durationMs: 2000),
                    StatisticLog(cardID: id, date: date(8, 5), grade: .easy, durationMs: 3000),
                    StatisticLog(cardID: UUID(), date: date(8, 6), grade: .hard, durationMs: 4000)]
        let result = StudyStatistics.calculate(logs: logs, retrievabilities: [0.8, 1, .nan], now: date(8, 10), calendar: calendar, startHour: 4)
        XCTAssertEqual(result.days[0].cards, 2); XCTAssertEqual(result.days[0].answers, 2)
        XCTAssertEqual(result.days[1].cards, 1); XCTAssertEqual(result.days[1].answers, 2)
        XCTAssertEqual(result.streak, 2)
        XCTAssertEqual(result.durationMs, 10000)
        XCTAssertEqual(result.meanRetrievability!, 0.9, accuracy: 0.0001)
        for grade in ReviewGrade.allCases { XCTAssertEqual(result.ratings[grade], 1) }
        let pendingToday = StudyStatistics.calculate(logs: Array(logs.prefix(2)), retrievabilities: [], now: date(8, 10), calendar: calendar, startHour: 4)
        XCTAssertEqual(pendingToday.streak, 1); XCTAssertNil(pendingToday.meanRetrievability)
        let broken = StudyStatistics.calculate(logs: logs, retrievabilities: [], now: date(10, 10), calendar: calendar, startHour: 4)
        XCTAssertEqual(broken.streak, 0)
    }
    func testStreakAcrossDSTAtNonexistentTwoAMBoundary() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func date(_ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: 12))! }
        let logs = (7...9).map { StatisticLog(cardID: UUID(), date: date($0), grade: .good, durationMs: 0) }
        let result = StudyStatistics.calculate(logs: logs, retrievabilities: [], now: date(9), calendar: calendar, startHour: 2)
        XCTAssertEqual(result.streak, 3)
        XCTAssertEqual(result.days.prefix(3).map(\.answers), [1, 1, 1])
    }
    func testSessionCountMatchesPersistedReviewLogsAndUndoRemoval() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func date(_ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: hour))!
        }
        let id = UUID()
        // Re-learning the same card is multiple answers but only one unique card.
        let logs = [
            StatisticLog(cardID: id, date: date(5), grade: .again, durationMs: 500, wasNew: true),
            StatisticLog(cardID: id, date: date(6), grade: .hard, durationMs: 600),
            StatisticLog(cardID: id, date: date(7), grade: .good, durationMs: 700)
        ]
        let before = StudyStatistics.calculate(logs: logs, retrievabilities: [], now: date(10),
                                                calendar: calendar, startHour: 4)
        XCTAssertEqual(before.days[0].answers, 3)
        XCTAssertEqual(before.days[0].cards, 1)
        XCTAssertEqual(before.days[0].newAnswers, 1)
        XCTAssertEqual(before.days[0].reviewAnswers, 2)
        XCTAssertEqual(before.days[0].ratings[.again], 1)
        XCTAssertEqual(before.days[0].ratings[.hard], 1)
        // Undo removes exactly the last persisted review log.
        let after = StudyStatistics.calculate(logs: Array(logs.dropLast()), retrievabilities: [],
                                               now: date(10), calendar: calendar, startHour: 4)
        XCTAssertEqual(after.days[0].answers, 2)
        XCTAssertEqual(after.days[0].cards, 1)
        XCTAssertEqual(after.days[0].reviewAnswers, 1)
        XCTAssertEqual(after.durationMs, 1100)
    }

    func testFilteringOrphanHistoryAndCurrentCardPredictions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func date(_ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: hour))!
        }
        let english = UUID(), japanese = UUID(), tag = UUID()
        let cardA = UUID(), cardB = UUID()
        let logs = [
            StatisticLog(cardID: cardA, date: date(3), grade: .good, durationMs: 100, deckID: english, tagIDs: [tag]),
            StatisticLog(cardID: cardA, date: date(5), grade: .again, durationMs: 100, wasNew: true, deckID: english, tagIDs: [tag]),
            StatisticLog(cardID: cardA, date: date(6), grade: .hard, durationMs: 100, deckID: english, tagIDs: [tag]),
            StatisticLog(cardID: cardB, date: date(7), grade: .easy, durationMs: 100, deckID: japanese),
            StatisticLog(cardID: UUID(), date: date(8), grade: .good, durationMs: 100),
            StatisticLog(cardID: cardB, date: date(12), grade: .good, durationMs: 100, deckID: japanese)
        ]
        let cards = [
            StatisticCardState(deckID: english, tagIDs: [tag], isSuspended: false,
                               isNew: false, dueDate: date(5), retrievability: 0.8),
            StatisticCardState(deckID: japanese, tagIDs: [], isSuspended: true,
                               isNew: false, dueDate: date(5), retrievability: 0.1),
            StatisticCardState(deckID: english, tagIDs: [tag], isSuspended: false,
                               isNew: true, dueDate: date(5), retrievability: nil)
        ]
        let all = StudyStatistics.calculate(logs: logs, retrievabilities: [], now: date(10),
                                             calendar: calendar, startHour: 4, cards: cards)
        XCTAssertEqual(all.days[0].answers, 4)
        XCTAssertEqual(all.days[1].answers, 1)
        XCTAssertEqual(all.days[0].cards, 3)
        XCTAssertEqual(all.unattributedAnswers, 1)
        XCTAssertEqual(all.overdueCount, 1)
        XCTAssertEqual(all.meanRetrievability!, 0.8, accuracy: 0.001)
        let scoped = StudyStatistics.calculate(logs: logs, retrievabilities: [], now: date(10),
                                                calendar: calendar, startHour: 4, cards: cards,
                                                selectedDeckIDs: [english], selectedTagIDs: [tag])
        XCTAssertEqual(scoped.days[0].answers, 2)
        XCTAssertEqual(scoped.days[0].cards, 1)
        XCTAssertEqual(scoped.unattributedAnswers, 0)
        XCTAssertEqual(scoped.ratings[.good], 1) // previous study day
    }

    func testCalendarWeeksMonthsAndTimeZonesUseStudyDayBoundaries() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        tokyo.firstWeekday = 2
        func date(_ day: Int, _ hour: Int) -> Date {
            tokyo.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
        }
        let card = UUID()
        let logs = [
            StatisticLog(cardID: card, date: date(1, 12), grade: .good, durationMs: 100),
            StatisticLog(cardID: card, date: date(5, 12), grade: .good, durationMs: 100),
            StatisticLog(cardID: card, date: date(10, 3), grade: .good, durationMs: 100)
        ]
        let result = StudyStatistics.calculate(logs: logs, retrievabilities: [], now: date(10, 12),
                                                calendar: tokyo, startHour: 4)
        XCTAssertEqual(result.days[0].answers, 0)
        XCTAssertEqual(result.days[1].answers, 1)
        XCTAssertEqual(result.weeks.suffix(2).map(\.answers), [1, 2])
        XCTAssertEqual(result.weeks.last?.cards, 1)
        XCTAssertEqual(result.months.last?.answers, 3)
        XCTAssertEqual(result.months.last?.cards, 1)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let utcResult = StudyStatistics.calculate(logs: [logs[2]], retrievabilities: [],
                                                   now: date(10, 12), calendar: utc, startHour: 4)
        XCTAssertEqual(utcResult.days[0].answers, 1)
    }

    func testTwelveThousandReviewAggregationCompletesWithinBudget() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let ids = (0..<200).map { _ in UUID() }
        let logs = (0..<12_000).map { index in
            StatisticLog(cardID: ids[index % ids.count],
                         date: now.addingTimeInterval(-Double(index % 600) * 3600),
                         grade: .good, durationMs: 300, wasNew: index < 200)
        }
        let start = Date()
        let result = StudyStatistics.calculate(logs: logs, retrievabilities: [], now: now,
                                                calendar: .current, startHour: 4)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result.ratings[.good], 12_000)
        XCTAssertEqual(result.durationMs, 3_600_000)
        XCTAssertEqual(result.weeks.count, 12)
        XCTAssertEqual(result.months.count, 12)
        print("Issue #9: 12000 answer aggregation: \(elapsed)s")
        XCTAssertLessThan(elapsed, 8, "Unexpectedly slow historical statistics aggregation")
    }

}
