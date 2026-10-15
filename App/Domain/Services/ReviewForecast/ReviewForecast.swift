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
    let answerTimeSamples: Int
    let overdue: Int
    var scheduled: Int { days.reduce(0) { $0 + $1.scheduled } }
    var projectedAnswers: Int { days.reduce(0) { $0 + $1.projectedAnswers } }

    // Shared saved-deadline bucketing: overdue cards join today's bucket.
    static func scheduledIndex(due: Date, days: [ForecastDay]) -> Int? {
        days.firstIndex { due < $0.end }
    }

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
    static func calculate(data: BackupData, deckID: UUID?, days count: Int, now: Date, calendar: Calendar, tagIDs: [UUID] = [], until: Date? = nil, newLimit: Int? = nil) throws -> Self {
        guard (1...90).contains(count), let preferences = data.preferences.first else { throw StudyError.invalidContent }
        let options = try data.options.first.map { try JSONDecoder().decode(StudyOptions.self, from: $0.payload) } ?? StudyOptions()
        let day = StudyDay(calendar: calendar, startHour: preferences.dayStartHour)
        var periods: [ForecastDay] = [], interval = day.interval(containing: now)
        for _ in 0..<count {
            periods.append(ForecastDay(start: interval.start, end: min(interval.end, until ?? interval.end)))
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
        let holds = Dictionary(uniqueKeysWithValues: (options.cardMarks ?? []).compactMap { mark in mark.hiddenUntil.map { (mark.cardID, $0) } })
        var cards: [LiveCard] = []
        let baseScheduler = try ReviewScheduler(parameters: options.fsrsOptimization?.activeParameters)
        let paused = DeckStudyEligibility.pausedIDs(data.decks.map { ($0.id, $0.parentID, $0.isStudyPaused ?? false) })
        for (index, card) in data.cards.enumerated() where !card.isSuspended {
            if index % 64 == 0 { try Task.checkCancellation() }
            guard let note = notes[card.noteID] else { throw StudyError.missingRecord }
            guard !paused.contains(note.deckID) else { continue }
            let path = ancestorMap[note.deckID] ?? [note.deckID]
            let retention = path.compactMap { overrides[$0]?.retention }.first ?? preferences.desiredRetention
            let limits = Dictionary(uniqueKeysWithValues: path.compactMap { id in overrides[id]?.newLimit.map { (id, $0) } })
            let snapshot = try JSONDecoder().decode(SchedulerSnapshot.self, from: card.fsrsPayload)
            let summary = try baseScheduler.summary(snapshot)
            let scoped = (deckID.map { path.contains($0) } ?? true) && Set(tagIDs).isSubset(of: Set(note.tagIDs))
            cards.append(LiveCard(source: card, noteID: card.noteID, scoped: scoped, limits: limits, quotaDecks: path,
                                  scheduler: try ReviewScheduler(desiredRetention: retention, parameters: options.fsrsOptimization?.activeParameters),
                                  snapshot: snapshot, summary: summary))
            if scoped && summary.state != "new" {
                if let bucket = scheduledIndex(due: max(card.dueDate, holds[card.id] ?? card.dueDate), days: periods) { periods[bucket].scheduled += 1 }
            }
        }
        let overdue = cards.filter { $0.scoped && $0.summary.state != "new" && $0.source.dueDate < now }.count
        let noteByCard = Dictionary(uniqueKeysWithValues: data.cards.map { ($0.id, $0.noteID) })
        let pathByCard = Dictionary(uniqueKeysWithValues: data.cards.map { ($0.id, notes[$0.noteID].flatMap { ancestorMap[$0.deckID] } ?? []) })
        let usage = Dictionary(uniqueKeysWithValues: (options.deckNewUsage ?? []).map { ($0.sequence, $0.quotaDeckIDs) })
        let since = calendar.date(byAdding: .day, value: -30, to: now)!
        let duration = data.logs.filter {
            $0.reviewedAt >= since && $0.reviewedAt <= now && (1...1_800_000).contains($0.durationMs) &&
            (deckID == nil || pathByCard[$0.cardID]?.contains(deckID!) == true) &&
            (tagIDs.isEmpty || noteByCard[$0.cardID].flatMap { notes[$0] }.map { Set(tagIDs).isSubset(of: Set($0.tagIDs)) } == true)
        }.map(\.durationMs)
        let median = AnswerTimeEstimate.median(milliseconds: duration, validRange: 1...1_800_000, minimumSamples: 1)
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
                if answeredToday.contains(card.source.id) || reviewAt < (holds[card.source.id] ?? .distantPast) { continue }
                let isShort = card.summary.state == "learning" || card.summary.state == "relearning"
                if options.siblingBuryEnabled && !isShort && usedNotes.contains(card.noteID) { continue }
                if isNew {
                    guard globalUsed < (newLimit ?? preferences.dailyNewLimit),
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
                              dailyGoal: preferences.dailyGoal, medianAnswerSeconds: median, answerTimeSamples: duration.count, overdue: overdue)
    }
}

struct ExamPlanReport: Sendable {
    var total = 0
    var newCards = 0
    var dueCards = 0
    var pausedCards = 0
    var recall: Double?
    var recallSamples = 0
    var recentNewPerDay = 0.0
    var forecast: ReviewForecast?
    var forecastDays = 0
    var scope: LearningScope?
    var notice: String?

    static func calculate(plan: ExamPlan, data: BackupData, homeScope: LearningScope, now: Date, calendar: Calendar) throws -> Self {
        var result = Self()
        guard plan.valid else { throw StudyError.invalidContent }
        let decks = Dictionary(uniqueKeysWithValues: data.decks.map { ($0.id, $0) })
        let tags = Set(data.tags.map(\.id))
        guard plan.scope.deckID.map({ decks[$0] != nil }) ?? true,
              Set(plan.scope.tagIDs).isSubset(of: tags) else {
            result.notice = "対象のデッキまたはタグが削除されています。範囲を編集してください。"
            return result
        }
        func path(_ id: UUID) -> Set<UUID> {
            var ids = Set<UUID>(), next: UUID? = id
            while let id = next, ids.insert(id).inserted { next = decks[id]?.parentID }
            return ids
        }
        let paths = Dictionary(uniqueKeysWithValues: data.decks.map { ($0.id, path($0.id)) })
        var scope = plan.scope
        if let home = homeScope.deckID {
            if let selected = scope.deckID {
                if paths[home]?.contains(selected) == true { scope.deckID = home }
                else if paths[selected]?.contains(home) != true {
                    result.notice = "ホームのデッキフィルターと対象範囲が重なりません。ホームで学習対象を変更してください。"
                    return result
                }
            } else { scope.deckID = home }
        }
        scope.tagIDs = Array(Set(scope.tagIDs).union(homeScope.tagIDs))
        result.scope = scope
        let notes = Dictionary(uniqueKeysWithValues: data.notes.map { ($0.id, $0) })
        let paused = DeckStudyEligibility.pausedIDs(data.decks.map { ($0.id, $0.parentID, $0.isStudyPaused ?? false) })
        let options = try data.options.first.map { try JSONDecoder().decode(StudyOptions.self, from: $0.payload) } ?? StudyOptions()
        let scheduler = try ReviewScheduler(parameters: options.fsrsOptimization?.activeParameters)
        let selectedTags = Set(scope.tagIDs)
        var recallSum = 0.0, selectedIDs = Set<UUID>()
        for (index, card) in data.cards.enumerated() where !card.isSuspended {
            if index % 64 == 0 { try Task.checkCancellation() }
            guard let note = notes[card.noteID], selectedTags.isSubset(of: Set(note.tagIDs)),
                  scope.deckID.map({ paths[note.deckID]?.contains($0) == true }) ?? true else { continue }
            result.total += 1
            if paused.contains(note.deckID) { result.pausedCards += 1; continue }
            selectedIDs.insert(card.id)
            let snapshot = try JSONDecoder().decode(SchedulerSnapshot.self, from: card.fsrsPayload)
            let summary = try scheduler.summary(snapshot)
            if summary.state == "new" { result.newCards += 1 }
            else if card.dueDate <= now { result.dueCards += 1 }
            let prediction = try scheduler.predictionState(snapshot)
            if prediction.canRankReview {
                let value = scheduler.retrievability(prediction, now: now)
                if value.isFinite && (0...1).contains(value) { recallSum += value; result.recallSamples += 1 }
            }
        }
        if result.recallSamples > 0 { result.recall = recallSum / Double(result.recallSamples) }
        let studyDay = StudyDay(calendar: calendar, startHour: data.preferences.first?.dayStartHour ?? 4)
        let today = studyDay.interval(containing: now).start
        let since = calendar.date(byAdding: .day, value: -7, to: today)!
        result.recentNewPerDay = Double(Set(data.logs.filter {
            $0.wasNew && $0.reviewedAt >= since && $0.reviewedAt < today && selectedIDs.contains($0.cardID)
        }.map(\.cardID)).count) / 7
        let remaining = plan.daysRemaining(now: now, calendar: calendar)
        guard plan.isActive, remaining >= 0 else {
            result.notice = plan.isActive ? "試験日は過去です。日付を編集するか計画を終了できます。カードと学習履歴は保持します。" : "この計画は終了しています。学習データは保持しています。"
            return result
        }
        if result.total == 0 { result.notice = "対象カードがありません。範囲とホームのフィルターを確認してください。"; return result }
        if result.total == result.pausedCards { result.notice = "対象デッキは休止中です。デッキ管理で明示的に再開してください。"; return result }
        // Include the exam calendar day, ending at midnight, never at its FSRS due date.
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: plan.date(calendar: calendar)!))!
        var interval = studyDay.interval(containing: now), count = 0
        while interval.start < end && count < 90 {
            count += 1; interval = studyDay.interval(containing: interval.end)
        }
        result.forecastDays = count
        result.forecast = try ReviewForecast.calculate(data: data, deckID: scope.deckID, days: count, now: now, calendar: calendar, tagIDs: scope.tagIDs, until: end)
        return result
    }
}

// Each scenario starts from the same immutable snapshot and uses the existing engine.
struct ForecastScenario: Identifiable, Sendable {
    var id: Int { newLimit }
    let newLimit: Int
    let title: String
    let forecast: ReviewForecast
    let estimatedMinutes: Double?
    var peakAnswers: Int { forecast.days.map(\.projectedAnswers).max() ?? 0 }

    static func compare(data: BackupData, deckID: UUID?, now: Date, calendar: Calendar,
                        current: ReviewForecast? = nil) throws -> [Self] {
        guard let limit = data.preferences.first?.dailyNewLimit else { throw StudyError.invalidContent }
        var seen = Set<Int>()
        return try [(limit, "現在の設定"), (limit / 2, "半分（切り捨て）"), (0, "新規なし")].compactMap { value, title in
            guard seen.insert(value).inserted else { return nil }
            try Task.checkCancellation()
            let report = try (value == limit ? current : nil) ?? ReviewForecast.calculate(
                data: data, deckID: deckID, days: 7, now: now, calendar: calendar, newLimit: value)
            return Self(newLimit: value, title: title, forecast: report,
                        estimatedMinutes: report.answerTimeSamples >= 5 ? report.medianAnswerSeconds.map { $0 * Double(report.projectedAnswers) / 60 } : nil)
        }
    }
}

// Saved deadlines only: deliberately does not run the future-answer simulation.
extension ReviewForecast {
    static func widgetSchedule(cards: [QueueCard], now: Date, calendar: Calendar, startHour: Int) throws -> WidgetReviewForecast {
        let day = StudyDay(calendar: calendar, startHour: startHour)
        var periods: [ForecastDay] = [], interval = day.interval(containing: now)
        for _ in 0..<7 {
            periods.append(ForecastDay(start: interval.start, end: interval.end))
            interval = day.interval(containing: interval.end)
        }
        var overdue = 0, seen = Set<UUID>()
        for card in cards {
            try Task.checkCancellation()
            guard seen.insert(card.id).inserted, !card.suspended, !card.studyPaused, card.state != "new", !card.isHidden(at: now) else { continue }
            if card.due < periods[0].start { overdue += 1 }
            else if let index = scheduledIndex(due: card.due, days: periods) { periods[index].scheduled += 1 }
        }
        return WidgetReviewForecast(days: periods.map { WidgetForecastDay(date: $0.start, count: $0.scheduled) }, overdue: overdue)
    }
}
