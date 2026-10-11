import Foundation

struct ForecastDay: Identifiable, Equatable, Sendable {
    var id: Date { start }
    let start: Date
    let end: Date
    var scheduled = 0
    var newCards = 0
    var reviews = 0
    var minutes: Double?
    var projectedAnswers: Int { newCards + reviews }
}

struct ReviewForecast: Equatable, Sendable {
    let days: [ForecastDay]
    let generatedAt: Date
    let remainingNew: Int
    let dailyGoal: Int?
    let medianAnswerSeconds: Double?
    let overdue: Int
    var scheduled: Int { days.reduce(0) { $0 + $1.scheduled } }
    var projectedAnswers: Int { days.reduce(0) { $0 + $1.projectedAnswers } }

    private struct LiveCard {
        let source: BackupStudyCard
        let noteID: UUID
        let scoped: Bool
        let limits: [UUID: Int]
        let quotaDecks: [UUID]
        let scheduler: ReviewScheduler
        var snapshot: SchedulerSnapshot
        var summary: ScheduleSummary
    }
    static func calculate(data: BackupData, deckID: UUID?, days count: Int, now: Date, calendar: Calendar) throws -> Self {
        guard [7, 30].contains(count), let preferences = data.preferences.first else { throw StudyError.invalidContent }
        let options = try data.options.first.map { try JSONDecoder().decode(StudyOptions.self, from: $0.payload) } ?? StudyOptions()
        let day = StudyDay(calendar: calendar, startHour: preferences.dayStartHour)
        var periods: [ForecastDay] = [], interval = day.interval(containing: now)
        for _ in 0..<count {
            periods.append(ForecastDay(start: interval.start, end: interval.end))
            interval = day.interval(containing: interval.end)
        }
        let notes = Dictionary(uniqueKeysWithValues: data.notes.map { ($0.id, $0) })
        let decks = Dictionary(uniqueKeysWithValues: data.decks.map { ($0.id, $0) })
        if let deckID, decks[deckID] == nil { throw StudyError.missingRecord }
        func ancestors(_ id: UUID) -> [UUID] {
            var result: [UUID] = [], current: UUID? = id
            while let next = current, !result.contains(next) { result.append(next); current = decks[next]?.parentID }
            return result
        }
        let ancestorMap = Dictionary(uniqueKeysWithValues: data.decks.map { ($0.id, ancestors($0.id)) })
        let overrides = Dictionary(uniqueKeysWithValues: (options.deckLearning ?? []).map { ($0.deckID, $0) })
        var cards: [LiveCard] = []
        let baseScheduler = try ReviewScheduler(parameters: options.fsrsOptimization?.activeParameters)
        for (index, card) in data.cards.enumerated() where !card.isSuspended {
            if index % 64 == 0 { try Task.checkCancellation() }
            guard let note = notes[card.noteID] else { throw StudyError.missingRecord }
            let path = ancestorMap[note.deckID] ?? [note.deckID]
            let retention = path.compactMap { overrides[$0]?.retention }.first ?? preferences.desiredRetention
            let limits = Dictionary(uniqueKeysWithValues: path.compactMap { id in overrides[id]?.newLimit.map { (id, $0) } })
            let snapshot = try JSONDecoder().decode(SchedulerSnapshot.self, from: card.fsrsPayload)
            let summary = try baseScheduler.summary(snapshot)
            let scoped = deckID.map { path.contains($0) } ?? true
            cards.append(LiveCard(source: card, noteID: card.noteID, scoped: scoped, limits: limits, quotaDecks: path,
                                  scheduler: try ReviewScheduler(desiredRetention: retention, parameters: options.fsrsOptimization?.activeParameters),
                                  snapshot: snapshot, summary: summary))
            if scoped && summary.state != "new" {
                if let bucket = periods.indices.first(where: { card.dueDate < periods[$0].end }) { periods[bucket].scheduled += 1 }
            }
        }
        let overdue = cards.filter { $0.scoped && $0.summary.state != "new" && $0.source.dueDate < now }.count
        let noteByCard = Dictionary(uniqueKeysWithValues: data.cards.map { ($0.id, $0.noteID) })
        let pathByCard = Dictionary(uniqueKeysWithValues: data.cards.map { ($0.id, notes[$0.noteID].flatMap { ancestorMap[$0.deckID] } ?? []) })
        let usage = Dictionary(uniqueKeysWithValues: (options.deckNewUsage ?? []).map { ($0.sequence, $0.quotaDeckIDs) })
        let since = calendar.date(byAdding: .day, value: -30, to: now)!
        let duration = data.logs.filter {
            $0.reviewedAt >= since && $0.reviewedAt <= now && (1...1_800_000).contains($0.durationMs) &&
            (deckID == nil || pathByCard[$0.cardID]?.contains(deckID!) == true)
        }.map { Double($0.durationMs) / 1000 }.sorted()
        let median: Double? = duration.isEmpty ? nil : (duration[(duration.count - 1) / 2] + duration[duration.count / 2]) / 2
        let freshOrder = cards.indices.sorted {
            cards[$0].source.createdAt == cards[$1].source.createdAt
            ? cards[$0].source.id.uuidString < cards[$1].source.id.uuidString
            : cards[$0].source.createdAt < cards[$1].source.createdAt
        }
        for bucket in periods.indices {
            try Task.checkCancellation()
            let period = periods[bucket], reviewAt = max(now, period.end.addingTimeInterval(-1))
            // Only actual history is used for consumed quotas today; simulation usage resets on each study day.
            let actual = data.logs.filter { $0.reviewedAt >= period.start && $0.reviewedAt < period.end }
            var globalUsed = Set(actual.filter(\.wasNew).map(\.cardID)).count
            var quotaUsed: [UUID: Set<UUID>] = [:]
            for log in actual where log.wasNew {
                for id in usage[log.sequence] ?? pathByCard[log.cardID] ?? [] { quotaUsed[id, default: []].insert(log.cardID) }
            }
            let answeredToday = Set(actual.map(\.cardID))
            var usedNotes = Set(actual.compactMap { noteByCard[$0.cardID] })
            let due = cards.indices.filter { cards[$0].summary.state != "new" && cards[$0].summary.dueDate <= reviewAt }.sorted {
                cards[$0].summary.dueDate == cards[$1].summary.dueDate
                ? cards[$0].source.id.uuidString < cards[$1].source.id.uuidString
                : cards[$0].summary.dueDate < cards[$1].summary.dueDate
            }
            let order = due + freshOrder.filter { cards[$0].summary.state == "new" }
            for (offset, index) in order.enumerated() {
                if offset % 64 == 0 { try Task.checkCancellation() }
                let card = cards[index], isNew = card.summary.state == "new"
                if answeredToday.contains(card.source.id) { continue }
                let isShort = card.summary.state == "learning" || card.summary.state == "relearning"
                if options.siblingBuryEnabled && !isShort && usedNotes.contains(card.noteID) { continue }
                if isNew {
                    guard globalUsed < preferences.dailyNewLimit,
                          card.limits.allSatisfy({ quotaUsed[$0.key, default: []].count < $0.value }) else { continue }
                    globalUsed += 1
                    for id in card.quotaDecks { quotaUsed[id, default: []].insert(card.source.id) }
                    if card.scoped { periods[bucket].newCards += 1 }
                } else if card.scoped { periods[bucket].reviews += 1 }
                usedNotes.insert(card.noteID)
                let transition = try card.scheduler.review(card.snapshot, grade: .good, now: reviewAt)
                cards[index].snapshot = transition.after
                cards[index].summary = try card.scheduler.summary(transition.after)
            }
            periods[bucket].minutes = median.map { $0 * Double(periods[bucket].projectedAnswers) / 60 }
        }
        return ReviewForecast(days: periods, generatedAt: now,
                              remainingNew: cards.filter { $0.scoped && $0.summary.state == "new" }.count,
                              dailyGoal: preferences.dailyGoal, medianAnswerSeconds: median, overdue: overdue)
    }
}
