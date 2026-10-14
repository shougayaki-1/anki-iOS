import Foundation

// A ReviewLog represents one successfully persisted FSRS rating, not one unique card
// or one session. Undo deletes the log, so undone answers never enter statistics.
struct StatisticLog {
    let cardID: UUID
    let date: Date
    let grade: ReviewGrade
    let durationMs: Int
    var beforeState: String? = nil
    var sequence = 0
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
    var memory: MemoryAnalysis? = nil
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

        let report = Self(days: days, weeks: weeks, months: months, streak: streak,
                          ratings: all.ratings, durationMs: all.durationMs,
                          meanRetrievability: nil, overdueCount: 0,
                          unattributedAnswers: unattributedAnswers)
        return report.updatingCurrentCards(cards, now: now, selectedDeckIDs: selectedDeckIDs,
                                           selectedTagIDs: selectedTagIDs, fallback: retrievabilities)
    }

    func updatingCurrentCards(_ cards: [StatisticCardState], now: Date,
                              selectedDeckIDs: Set<UUID>?, selectedTagIDs: Set<UUID>,
                              fallback: [Double] = []) -> Self {
        func included(deckID: UUID?, tags: [UUID]) -> Bool {
            if let selectedDeckIDs {
                guard let deckID, selectedDeckIDs.contains(deckID) else { return false }
            }
            return selectedTagIDs.isSubset(of: Set(tags))
        }
        let scopedCards = cards.filter { included(deckID: $0.deckID, tags: $0.tagIDs) && !$0.isSuspended }
        let probabilities = (cards.isEmpty ? fallback : scopedCards.compactMap(\.retrievability))
            .filter { $0.isFinite && (0...1).contains($0) }
        let mean = probabilities.isEmpty ? nil : probabilities.reduce(0, +) / Double(probabilities.count)
        let overdue = scopedCards.filter { !$0.isNew && $0.dueDate < now }.count

        return Self(days: days, weeks: weeks, months: months, streak: streak,
                    ratings: ratings, durationMs: durationMs,
                    meanRetrievability: mean, overdueCount: overdue,
                    unattributedAnswers: unattributedAnswers)
    }
}

struct WeakCardEvidence: Equatable {
    let reasons: [String]
    let score: Double
    static func evaluate(logs: [StatisticLog], difficulty: Double, retrievability: Double?, now: Date) -> Self? {
        let history = logs.filter { $0.date <= now }.sorted { $0.date < $1.date }
        guard !history.isEmpty else { return nil }
        let again = history.filter { $0.grade == .again }.count
        let ratio = Double(again) / Double(history.count)
        var reasons: [String] = []
        if history.last?.grade == .again { reasons.append("直近の評価がAgain") }
        if again >= 2 { reasons.append("期間内のAgain：\(again)回") }
        if history.count >= 3 && ratio >= 0.3 { reasons.append("Againの割合：\(Int((ratio * 100).rounded()))%（\(history.count)回答）") }
        if history.count >= 3 && difficulty >= 8 { reasons.append("FSRS難易度：\(String(format: "%.1f", difficulty))／10") }
        if history.count >= 3, let probability = retrievability, probability < 0.75 {
            reasons.append("現在の推定想起確率：\(Int((probability * 100).rounded()))%")
        }
        guard !reasons.isEmpty else { return nil }
        return Self(reasons: reasons, score: Double(again) + ratio * 3 +
            (history.last?.grade == .again ? 3 : 0) + difficulty / 10 + (1 - (retrievability ?? 1)))
    }
}

struct WeakCardItem: Identifiable {
    var id: UUID { card.cardID }
    let card: NoteItem
    let evidence: WeakCardEvidence
}

// Local practice state has no repository, scheduler, persistence or rating API.
struct WeakPracticeSession: Identifiable {
    let id = UUID()
    let cards: [NoteItem]
    private(set) var index = 0
    private(set) var revealed = false
    enum Phase { case empty, practicing, completed }
    var phase: Phase { cards.isEmpty ? .empty : (index == cards.count ? .completed : .practicing) }
    var completedCount: Int { index }
    var current: NoteItem? { cards.indices.contains(index) ? cards[index] : nil }
    mutating func restart() { index = 0; revealed = false }
    mutating func reveal() { if current != nil { revealed = true } }
    mutating func next() { guard current != nil, revealed else { return }; index += 1; revealed = false }
    mutating func previous() { guard index > 0 else { return }; index -= 1; revealed = false }
}

// Value-only analytics. No scheduler or persistence mutations.
struct MemoryCard: Identifiable {
    var state: String = "review"
    let id: UUID
    let title: String
    let stability: Double
    let difficulty: Double
    let retrievability: Double
}

struct MemoryDistribution: Identifiable {
    let id: String
    let explanation: String
    let unit: String
    let buckets: [Bucket]
    let median: Double?
    let minimum: Double?
    let maximum: Double?
    var count: Int { buckets.reduce(0) { $0 + $1.cards.count } }
    struct Bucket: Identifiable {
        var id: String { label }
        let label: String
        let cards: [MemoryCard]
    }
    static func make(id: String, explanation: String, unit: String, cards: [MemoryCard],
                     edges: [Double], labels: [String], value: (MemoryCard) -> Double) -> Self {
        let valid = cards.filter { value($0).isFinite && value($0) >= edges[0] && value($0) <= edges.last! }
        let sorted = valid.map(value).sorted()
        let middle = sorted.count / 2
        let median = sorted.isEmpty ? nil : (sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle])
        let buckets = labels.indices.map { index in
            Bucket(label: labels[index], cards: valid.filter {
                value($0) >= edges[index] && (value($0) < edges[index + 1]
                    || (index == labels.count - 1 && value($0) == edges[index + 1]))
            })
        }
        return Self(id: id, explanation: explanation, unit: unit, buckets: buckets,
                    median: median, minimum: sorted.first, maximum: sorted.last)
    }
}

struct ObservedRetention {
    let days: Int
    let start: Date
    let end: Date
    let successes: Int
    let trials: Int
    let cardIDs: [UUID]
    var rate: Double? { trials == 0 ? nil : Double(successes) / Double(trials) }
    static func calculate(logs: [StatisticLog], days: Int, now: Date,
                          calendar: Calendar, startHour: Int) -> Self {
        let studyDay = StudyDay(calendar: calendar, startHour: startHour)
        let today = studyDay.interval(containing: now).start
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today)!
        struct Trial: Hashable { let cardID: UUID; let day: Date }
        var seen = Set<Trial>(), successes = 0, ids = Set<UUID>()
        for log in logs.filter({ $0.date >= start && $0.date <= now && $0.beforeState == "review" })
            .sorted(by: { $0.date == $1.date ? $0.sequence < $1.sequence : $0.date < $1.date }) {
            let key = Trial(cardID: log.cardID, day: studyDay.interval(containing: log.date).start)
            if seen.insert(key).inserted {
                if log.grade != .again { successes += 1 }
                ids.insert(log.cardID)
            }
        }
        return Self(days: days, start: start, end: now, successes: successes, trials: seen.count,
                    cardIDs: ids.sorted { $0.uuidString < $1.uuidString })
    }
}

struct MemoryAnalysis {
    let generatedAt: Date
    let distributions: [MemoryDistribution]
    let retention: [ObservedRetention]
    let targets: [Double]
    var matureCardCount: Int {
        distributions.first!.buckets.flatMap(\.cards).filter {
            MatureCards.contains(state: $0.state, stability: $0.stability, suspended: false)
        }.count
    }
    var estimatedRemembered: Double { distributions.last!.buckets.flatMap(\.cards).reduce(0) { $0 + $1.retrievability } }
    static func calculate(cards: [MemoryCard], logs: [StatisticLog], targets: [Double],
                          now: Date, calendar: Calendar, startHour: Int) -> Self {
        Self(generatedAt: now, distributions: [
            .make(id: "記憶の安定度（推定）", explanation: "想起確率が90%まで下がる時間尺度です。将来の保持を保証しません。", unit: "日", cards: cards,
                  edges: [0, 1, 7, 30, 90, .infinity], labels: ["0–1日", "1–7日", "7–30日", "30–90日", "90日以上"], value: { $0.stability }),
            .make(id: "覚えにくさ（推定）", explanation: "FSRSモデルの難易度は1〜10です。主観的な難しさや正答率ではありません。", unit: "／10", cards: cards,
                  edges: [1, 3, 5, 7, 9, 10], labels: ["1–3", "3–5", "5–7", "7–9", "9–10"], value: { $0.difficulty }),
            .make(id: "思い出せる可能性（推定）", explanation: "集計時点のFSRS-6想起確率です。実際に思い出せた割合とは異なります。", unit: "", cards: cards,
                  edges: [0, 0.2, 0.4, 0.6, 0.8, 1], labels: ["0–20%", "20–40%", "40–60%", "60–80%", "80–100%"], value: { $0.retrievability })
        ], retention: [7, 30, 90].map { .calculate(logs: logs, days: $0, now: now, calendar: calendar, startHour: startHour) },
             targets: Array(Set(targets)).sorted())
    }
}


// Shared definition for achievements and FSRS statistics; this is an estimate.
enum MatureCards {
    static let stabilityDays = 21.0
    static func contains(state: String, stability: Double, suspended: Bool) -> Bool {
        !suspended && state == "review" && stability.isFinite && stability >= stabilityDays
    }
}

enum AchievementKind: String, Codable {
    case firstStudyToday, streakAdvanced, dailyGoalReached, matureMilestone
}

struct AchievementRecord: Codable, Equatable, Identifiable {
    let id: String
    let kind: AchievementKind
    let studyDay: String
    let threshold: Int
    let value: Int
    let occurredAt: Date
    let sourceLogID: UUID
    let timeZoneID: String
    let startHour: Int
    var displayedAt: Date?
    var title: String {
        switch kind {
        case .firstStudyToday: return "今日も学習しました"
        case .streakAdvanced: return "\(value)日連続達成"
        case .dailyGoalReached: return "日次目標\(threshold)枚達成"
        case .matureMilestone: return "長期定着（推定）\(threshold)枚"
        }
    }
}

// Value API for CelebrationView. Delivery is explicitly claimed durably before display.
struct AchievementEvent: Identifiable, Equatable {
    let record: AchievementRecord
    var id: String { record.id }
    var kind: AchievementKind { record.kind }
}

struct AchievementProgress {
    static let streakMilestones = [1, 3, 7, 14, 30, 100]
    static let matureMilestones = [10, 50, 100, 500]
    let currentStreak: Int
    let longestStreak: Int
    let studiedToday: Bool
    let uniqueCardsToday: Int

    static func dayKey(_ date: Date, calendar: Calendar, startHour: Int) -> String {
        let start = StudyDay(calendar: calendar, startHour: startHour).interval(containing: date).start
        let parts = calendar.dateComponents([.year, .month, .day], from: start)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func calculate(logs: [(cardID: UUID, date: Date)], now: Date,
                          calendar: Calendar, startHour: Int) -> Self {
        let day = StudyDay(calendar: calendar, startHour: startHour)
        let today = day.interval(containing: now).start
        var days: [Date: Set<UUID>] = [:]
        for log in logs where log.date <= now {
            days[day.interval(containing: log.date).start, default: []].insert(log.cardID)
        }
        func previous(_ date: Date) -> Date {
            day.interval(containing: calendar.date(byAdding: .day, value: -1, to: date)!).start
        }
        var cursor = days[today] == nil ? previous(today) : today
        var current = 0
        while days[cursor] != nil { current += 1; cursor = previous(cursor) }
        var longest = 0, run = 0, last: Date?
        for date in days.keys.sorted() {
            run = last == previous(date) ? run + 1 : 1
            longest = max(longest, run); last = date
        }
        return Self(currentStreak: current, longestStreak: longest, studiedToday: days[today] != nil,
                    uniqueCardsToday: days[today]?.count ?? 0)
    }
}


extension Notification.Name {
    static let studyAchievementEventsAvailable = Notification.Name("studyAchievementEventsAvailable")
}
