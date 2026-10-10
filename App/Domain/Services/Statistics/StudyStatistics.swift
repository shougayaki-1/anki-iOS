import Foundation

// A ReviewLog represents one successfully persisted FSRS rating, not one unique card
// or one session. Undo deletes the log, so undone answers never enter statistics.
struct StatisticLog {
    let cardID: UUID
    let date: Date
    let grade: ReviewGrade
    let durationMs: Int
    var wasNew = false
    var deckID: UUID? = nil
    var tagIDs: [UUID] = []
}

struct StatisticCardState {
    let deckID: UUID?
    let tagIDs: [UUID]
    let isSuspended: Bool
    let isNew: Bool
    let dueDate: Date
    let retrievability: Double?
}

struct StatisticsBucket: Identifiable {
    var id: Date { date }
    let date: Date
    let cards: Int
    let answers: Int
    let newAnswers: Int
    let reviewAnswers: Int
    let ratings: [ReviewGrade: Int]
    let durationMs: Int
}

typealias DailyStatistics = StatisticsBucket

private struct StatisticsAccumulator {
    var cardIDs = Set<UUID>()
    var answers = 0
    var newAnswers = 0
    var ratings: [ReviewGrade: Int] = [:]
    var durationMs = 0

    mutating func record(_ log: StatisticLog) {
        cardIDs.insert(log.cardID)
        answers += 1
        if log.wasNew { newAnswers += 1 }
        ratings[log.grade, default: 0] += 1
        durationMs += max(0, log.durationMs)
    }

    func bucket(at date: Date) -> StatisticsBucket {
        StatisticsBucket(date: date, cards: cardIDs.count, answers: answers,
                         newAnswers: newAnswers, reviewAnswers: answers - newAnswers,
                         ratings: ratings, durationMs: durationMs)
    }
}

struct StudyStatistics {
    // days are newest-first to preserve the legacy summary API; trends may be
    // reversed in the chart to present time from left to right.
    let days: [DailyStatistics]
    let weeks: [StatisticsBucket]
    let months: [StatisticsBucket]
    let streak: Int
    let ratings: [ReviewGrade: Int]
    let durationMs: Int
    let meanRetrievability: Double?
    let overdueCount: Int
    let unattributedAnswers: Int

    static func calculate(
        logs: [StatisticLog], retrievabilities: [Double], now: Date,
        calendar: Calendar, startHour: Int,
        cards: [StatisticCardState] = [],
        selectedDeckIDs: Set<UUID>? = nil, selectedTagIDs: Set<UUID> = []
    ) -> Self {
        let studyDay = StudyDay(calendar: calendar, startHour: startHour)
        let today = studyDay.interval(containing: now).start
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)!.start
        let monthStart = calendar.dateInterval(of: .month, for: today)!.start

        func included(deckID: UUID?, tags: [UUID]) -> Bool {
            if let selectedDeckIDs {
                guard let deckID, selectedDeckIDs.contains(deckID) else { return false }
            }
            return selectedTagIDs.isSubset(of: Set(tags))
        }

        var daily: [Date: StatisticsAccumulator] = [:]
        var weekly: [Date: StatisticsAccumulator] = [:]
        var monthly: [Date: StatisticsAccumulator] = [:]
        var all = StatisticsAccumulator()
        var unattributedAnswers = 0

        for log in logs where log.date <= now && included(deckID: log.deckID, tags: log.tagIDs) {
            let studyDate = studyDay.interval(containing: log.date).start
            let week = calendar.dateInterval(of: .weekOfYear, for: studyDate)!.start
            let month = calendar.dateInterval(of: .month, for: studyDate)!.start
            daily[studyDate, default: StatisticsAccumulator()].record(log)
            weekly[week, default: StatisticsAccumulator()].record(log)
            monthly[month, default: StatisticsAccumulator()].record(log)
            all.record(log)
            if log.deckID == nil { unattributedAnswers += 1 }
        }

        // Adding calendar days rather than seconds preserves the configured
        // study-day boundary across DST transitions and time-zone changes.
        let days: [StatisticsBucket] = (0..<30).map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: now)!
            let key = studyDay.interval(containing: date).start
            return (daily[key] ?? StatisticsAccumulator()).bucket(at: key)
        }
        let weeks = (0..<12).reversed().map { offset -> StatisticsBucket in
            let key = calendar.date(byAdding: .weekOfYear, value: -offset, to: weekStart)!
            return (weekly[key] ?? StatisticsAccumulator()).bucket(at: key)
        }
        let months = (0..<12).reversed().map { offset -> StatisticsBucket in
            let key = calendar.date(byAdding: .month, value: -offset, to: monthStart)!
            return (monthly[key] ?? StatisticsAccumulator()).bucket(at: key)
        }

        var streak = 0
        var cursor = daily[today] == nil
            ? studyDay.interval(containing: calendar.date(byAdding: .day, value: -1, to: now)!).start
            : today
        while (daily[cursor]?.answers ?? 0) > 0 {
            streak += 1
            cursor = studyDay.interval(containing: calendar.date(byAdding: .day, value: -1, to: cursor)!).start
        }

        let scopedCards = cards.filter { included(deckID: $0.deckID, tags: $0.tagIDs) && !$0.isSuspended }
        let probabilities = (cards.isEmpty ? retrievabilities : scopedCards.compactMap(\.retrievability))
            .filter { $0.isFinite && (0...1).contains($0) }
        let mean = probabilities.isEmpty ? nil : probabilities.reduce(0, +) / Double(probabilities.count)
        let overdue = scopedCards.filter { !$0.isNew && $0.dueDate < now }.count

        return Self(days: days, weeks: weeks, months: months, streak: streak,
                    ratings: all.ratings, durationMs: all.durationMs,
                    meanRetrievability: mean, overdueCount: overdue,
                    unattributedAnswers: unattributedAnswers)
    }
}
