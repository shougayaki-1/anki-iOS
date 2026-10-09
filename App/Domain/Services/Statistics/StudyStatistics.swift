import Foundation

struct StatisticLog {
    let cardID: UUID
    let date: Date
    let grade: ReviewGrade
    let durationMs: Int
}

struct DailyStatistics: Identifiable {
    var id: Date { date }
    let date: Date
    let cards: Int
    let answers: Int
}

struct StudyStatistics {
    let days: [DailyStatistics]
    let streak: Int
    let ratings: [ReviewGrade: Int]
    let durationMs: Int
    let meanRetrievability: Double?

    static func calculate(logs: [StatisticLog], retrievabilities: [Double], now: Date,
                          calendar: Calendar, startHour: Int) -> Self {
        let day = StudyDay(calendar: calendar, startHour: startHour)
        let today = day.interval(containing: now).start
        let history = logs.filter { $0.date <= now }
        let grouped = Dictionary(grouping: history) { day.interval(containing: $0.date).start }
        let days = (0..<30).compactMap { offset -> DailyStatistics? in
            guard let midnight = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: today)),
                  let date = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: midnight) else { return nil }
            let answers = grouped[date] ?? []
            return DailyStatistics(date: date, cards: Set(answers.map(\.cardID)).count, answers: answers.count)
        }
        var streak = 0
        func previous(_ date: Date) -> Date {
            let midnight = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date))!
            return calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: midnight)!
        }
        var cursor = grouped[today] == nil ? previous(today) : today
        while grouped[cursor] != nil {
            streak += 1
            cursor = previous(cursor)
        }
        let valid = retrievabilities.filter { $0.isFinite && (0...1).contains($0) }
        return Self(days: days, streak: streak, ratings: Dictionary(grouping: history, by: \.grade).mapValues(\.count),
                    durationMs: history.reduce(0) { $0 + max(0, $1.durationMs) },
                    meanRetrievability: valid.isEmpty ? nil : valid.reduce(0, +) / Double(valid.count))
    }
}
