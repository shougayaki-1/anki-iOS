import Foundation
import SwiftData

// The report uses its own SwiftData context on a background actor. Review
// transactions must never wait for a full-history scan, FSRS decoding or chart
// aggregation. No model objects cross the actor boundary.
actor StatisticsReader {
    private let container: ModelContainer

    init(container: ModelContainer) { self.container = container }

    func load(now: Date, calendar: Calendar, startHour: Int, scope: LearningScope) throws -> StudyStatistics {
        try Task.checkCancellation()
        let context = ModelContext(container)
        let notes = try context.fetch(FetchDescriptor<Note>())
        let cards = try context.fetch(FetchDescriptor<StudyCard>())
        let decks = try context.fetch(FetchDescriptor<Deck>())
        let logRows = try context.fetch(FetchDescriptor<StudyReviewLog>())

        let notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        let noteIDByCardID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0.noteID) })

        // This is only a filter expansion. It does not change the deck model
        // or the folder-tree UI owned by issue #40.
        let deckIDs: Set<UUID>? = scope.deckID.map { root in
            var selected: Set<UUID> = [root]
            var frontier: Set<UUID> = [root]
            while !frontier.isEmpty {
                let children = Set(decks.compactMap { deck -> UUID? in
                    guard let parentID = deck.parentID, frontier.contains(parentID),
                          !selected.contains(deck.id) else { return nil }
                    return deck.id
                })
                selected.formUnion(children)
                frontier = children
            }
            return selected
        }

        let logs = try logRows.compactMap { row -> StatisticLog? in
            try Task.checkCancellation()
            guard let grade = ReviewGrade(rawValue: row.grade) else { return nil }
            let note = noteIDByCardID[row.cardID].flatMap { notesByID[$0] }
            return StatisticLog(cardID: row.cardID, date: row.reviewedAt, grade: grade,
                                durationMs: row.durationMs, wasNew: row.wasNew,
                                deckID: note?.deckID, tagIDs: note?.tagIDs ?? [])
        }
        // Preserve the existing contract: an invalid persisted grade is a
        // data error, not an answer that is silently excluded.
        guard logs.count == logRows.count else { throw StudyError.unsupportedContent }

        let extra = try context.fetch(FetchDescriptor<ExtraPreferences>()).first
        let optimization = try extra.flatMap { try JSONDecoder().decode(StudyOptions.self, from: $0.payload).fsrsOptimization }
        let scheduler = try ReviewScheduler(parameters: optimization?.activeParameters)
        let retentionStates: [StatisticCardState] = try cards.map { card in
            try Task.checkCancellation()
            let note = notesByID[card.noteID]
            let snapshot = try JSONDecoder().decode(SchedulerSnapshot.self, from: card.fsrsPayload)
            let summary = try scheduler.summary(snapshot)
            let prediction = summary.state == "new" || card.isSuspended
                ? nil : try scheduler.retrievability(snapshot, now: now)
            return StatisticCardState(deckID: note?.deckID, tagIDs: note?.tagIDs ?? [],
                                      isSuspended: card.isSuspended, isNew: summary.state == "new",
                                      dueDate: card.dueDate, retrievability: prediction)
        }

        return StudyStatistics.calculate(logs: logs, retrievabilities: [], now: now,
                                         calendar: calendar, startHour: startHour,
                                         cards: retentionStates, selectedDeckIDs: deckIDs,
                                         selectedTagIDs: Set(scope.tagIDs))
    }
}

// Retained for direct repository-level consumers and legacy tests. The UI
// deliberately uses StatisticsReader instead, off the MainActor.
extension StudyRepository {
    func statistics(now: Date) throws -> StudyStatistics {
        let logs = try logs().map {
            guard let grade = ReviewGrade(rawValue: $0.grade) else { throw StudyError.unsupportedContent }
            return StatisticLog(cardID: $0.cardID, date: $0.reviewedAt, grade: grade,
                                durationMs: $0.durationMs, wasNew: $0.wasNew)
        }
        let scheduler = try ReviewScheduler(parameters: optimizationState().activeParameters)
        let retention = try cards().filter { !$0.isSuspended }.compactMap { card -> Double? in
            let snapshot = try snapshot(card)
            guard try scheduler.summary(snapshot).state != "new" else { return nil }
            return try scheduler.retrievability(snapshot, now: now)
        }
        return StudyStatistics.calculate(logs: logs, retrievabilities: retention, now: now,
                                         calendar: calendar, startHour: try settings().dayStartHour)
    }
}

extension StudyRepository {
    func savedTypedAnswerModels() throws -> [SavedTypedAnswer] {
        try context.fetch(FetchDescriptor<SavedTypedAnswer>(sortBy: [SortDescriptor(\.reviewedAt, order: .reverse)]))
    }
    func savedTypedAnswers(now: Date) throws -> [TypedAnswerRecord] {
        try pruneTypedAnswers(now: now)
        return try savedTypedAnswerModels().map { try JSONDecoder().decode(TypedAnswerRecord.self, from: $0.payload) }
    }
    func pruneTypedAnswersInTransaction(now: Date) throws {
        guard let policy = try options().typedAnswerPolicy else { return }
        let days = policy.retentionDays
        guard TypedAnswerPolicy.supportedDays.contains(days) else { throw StudyError.invalidContent }
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        let expired = try context.fetch(FetchDescriptor<SavedTypedAnswer>(predicate: #Predicate { $0.reviewedAt < cutoff }))
        for row in expired { context.delete(row) }
    }
    func pruneTypedAnswers(now: Date) throws {
        guard let policy = try options().typedAnswerPolicy else { return }
        let days = policy.retentionDays
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        let count = try context.fetchCount(FetchDescriptor<SavedTypedAnswer>(predicate: #Predicate { $0.reviewedAt < cutoff }))
        if count > 0 { try transaction { try pruneTypedAnswersInTransaction(now: now) } }
    }
    func updateTypedAnswerPolicy(_ policy: TypedAnswerPolicy, now: Date) throws {
        guard TypedAnswerPolicy.supportedDays.contains(policy.retentionDays) else { throw StudyError.invalidContent }
        try transaction {
            var value = try options(); value.typedAnswerPolicy = policy
            if let row = try context.fetch(FetchDescriptor<ExtraPreferences>()).first { row.payload = try JSONEncoder().encode(value) }
            else { context.insert(try ExtraPreferences(options: value)) }
            try pruneTypedAnswersInTransaction(now: now)
        }
    }
    func deleteTypedAnswers(ids: Set<UUID>? = nil) throws {
        try transaction {
            for row in try savedTypedAnswerModels() where ids == nil || ids!.contains(row.id) { context.delete(row) }
        }
    }
    func weakCards(scope: LearningScope, days: Int?, now: Date) throws -> [WeakCardItem] {
        guard days == nil || [7, 30, 90].contains(days!) else { throw StudyError.invalidContent }
        let normalized = try normalizedScope(scope)
        let scopedIDs = Set(try scopedQueueCards(normalized).map(\.id))
        let startHour = try settings().dayStartHour
        let day = StudyDay(calendar: calendar, startHour: startHour).interval(containing: now)
        let start = days.flatMap { calendar.date(byAdding: .day, value: 1 - $0, to: day.start) }
        let rows = try logs()
        let grouped = Dictionary(grouping: rows.filter { $0.reviewedAt <= now && (start == nil || $0.reviewedAt >= start!) }, by: \.cardID)
        let states = Dictionary(uniqueKeysWithValues: try cards().map { ($0.id, $0) })
        let scheduler = try ReviewScheduler()
        return try noteItems().filter { scopedIDs.contains($0.cardID) && !$0.isSuspended && $0.summary.state != "new" }.compactMap { item in
            guard let state = states[item.cardID] else { return nil }
            let history = try (grouped[item.cardID] ?? []).map { row -> StatisticLog in
                guard let grade = ReviewGrade(rawValue: row.grade) else { throw StudyError.unsupportedContent }
                return StatisticLog(cardID: row.cardID, date: row.reviewedAt, grade: grade, durationMs: row.durationMs)
            }
            let probability = try scheduler.retrievability(snapshot(state), now: now)
            guard let evidence = WeakCardEvidence.evaluate(logs: history, difficulty: item.summary.difficulty,
                                                           retrievability: probability, now: now) else { return nil }
            return WeakCardItem(card: item, evidence: evidence)
        }.sorted { $0.evidence.score == $1.evidence.score ? $0.id.uuidString < $1.id.uuidString : $0.evidence.score > $1.evidence.score }
    }

    func weakPractice(scope: LearningScope, days: Int?, now: Date) throws -> WeakPracticeSession {
        let candidates = try weakCards(scope: scope, days: days, now: now)
        let settings = try settings()
        let day = StudyDay(calendar: calendar, startHour: settings.dayStartHour).interval(containing: now)
        let cardNotes = Dictionary(uniqueKeysWithValues: try cards().map { ($0.id, $0.noteID) })
        let today = try logs().filter { $0.reviewedAt >= day.start && $0.reviewedAt < day.end }
        var seen = Set<UUID>()
        let selected = candidates.filter { item in
            let card = item.card
            guard settings.siblingBuryEnabled, !["learning", "relearning"].contains(card.summary.state) else { return true }
            guard !seen.contains(card.noteID), !today.contains(where: {
                $0.cardID != card.cardID && cardNotes[$0.cardID] == card.noteID
            }) else { return false }
            seen.insert(card.noteID)
            return true
        }.map(\.card)
        guard !selected.isEmpty else { throw StudyError.noAvailableCards }
        return WeakPracticeSession(cards: selected)
    }
}
