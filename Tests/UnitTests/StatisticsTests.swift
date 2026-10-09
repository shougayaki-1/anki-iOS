import XCTest
@testable import AnkiIOS

final class StatisticsTests: XCTestCase {
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
}
