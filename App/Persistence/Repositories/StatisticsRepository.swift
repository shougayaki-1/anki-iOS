import Foundation
import SwiftData

// The report uses its own SwiftData context on a background actor. Review
// transactions must never wait for a full-history scan, FSRS decoding or chart
// aggregation. No model objects cross the actor boundary.
actor StatisticsReader {
    private let container: ModelContainer
    private struct DeckLink { let id: UUID; let parentID: UUID? }
    private struct PreparedCard {
        let id: UUID
        let title: String
        let stability: Double
        let difficulty: Double
        let deckID: UUID?
        let tagIDs: [UUID]
        let isSuspended: Bool
        let dueDate: Date
        let state: ReviewScheduler.PredictionState
    }
    private struct Material {
        let logs: [StatisticLog]
        let cards: [PreparedCard]
        let decks: [DeckLink]
        let parameters: [Double]?
        let targets: [UUID: Double]
        let cost: Int
    }
    private var cached: (revision: Int, material: Material)?
    private struct HistoryEntry {
        let calendar: Calendar
        let startHour: Int
        let day: Date
        let scope: LearningScope
        let evaluatedAt: Date
        let nextFutureLog: Date?
        let report: StudyStatistics
    }
    private var histories: [HistoryEntry] = []
    private var expiry: Task<Void, Never>?
    private var cacheGeneration = 0
    private let maximumCacheCost: Int
    private let cacheLifetime: Duration
    #if DEBUG
    private(set) var materialReads = 0
    private(set) var fsrsDecodes = 0
    private(set) var historyAggregations = 0
    var cachedHistoryCount: Int { histories.count }
    var cachedCost: Int { (cached?.material.cost ?? 0) + histories.count * 65536 }
    #endif

    init(container: ModelContainer, maximumCacheCost: Int = 16 * 1024 * 1024, cacheLifetime: Duration = .seconds(60)) {
        self.container = container
        self.maximumCacheCost = maximumCacheCost
        self.cacheLifetime = cacheLifetime
    }

    func clearCache() {
        cached = nil; histories = []; expiry?.cancel(); expiry = nil
        cacheGeneration += 1
    }

    // Unversioned callers deliberately bypass caching: they cannot prove that
    // edits or restore have not happened since their previous read.
    func load(now: Date, calendar: Calendar, startHour: Int, scope: LearningScope,
              revision: Int? = nil) throws -> StudyStatistics {
        let interval = PerformanceProbe.begin("Statistics.load")
        defer { PerformanceProbe.end(interval) }
        try Task.checkCancellation()
        let material: Material
        if let revision, let saved = cached, saved.revision == revision { material = saved.material }
        else {
            clearCache()
            material = try readMaterial()
            try Task.checkCancellation()
            if let revision, material.cost <= maximumCacheCost {
                cached = (revision, material)
                let generation = cacheGeneration
                let lifetime = cacheLifetime
                expiry = Task { [weak self] in
                    do { try await Task.sleep(for: lifetime) } catch { return }
                    await self?.expire(generation: generation)
                }
            }
        }
        // This is only a filter expansion. It does not change the deck model
        // or the folder-tree UI owned by issue #40.
        let deckIDs: Set<UUID>? = scope.deckID.map { root in
            var selected: Set<UUID> = [root]
            var frontier: Set<UUID> = [root]
            while !frontier.isEmpty {
                let children = Set(material.decks.compactMap { deck -> UUID? in
                    guard let parentID = deck.parentID, frontier.contains(parentID),
                          !selected.contains(deck.id) else { return nil }
                    return deck.id
                })
                selected.formUnion(children)
                frontier = children
            }
            return selected
        }

        let scheduler = try ReviewScheduler(parameters: material.parameters)
        let states = try material.cards.map { card -> StatisticCardState in
            try Task.checkCancellation()
            return StatisticCardState(deckID: card.deckID, tagIDs: card.tagIDs,
                                      isSuspended: card.isSuspended, isNew: card.state.isNew,
                                      dueDate: card.dueDate,
                                      retrievability: card.state.isNew || card.isSuspended
                                        ? nil : scheduler.retrievability(card.state, now: now))
        }
        let day = StudyDay(calendar: calendar, startHour: startHour).interval(containing: now).start
        var normalized = scope
        normalized.tagIDs = Array(Set(scope.tagIDs)).sorted { $0.uuidString < $1.uuidString }
        let history: StudyStatistics
        if let index = histories.firstIndex(where: {
            $0.calendar == calendar && $0.startHour == startHour && $0.day == day && $0.scope == normalized
                && now >= $0.evaluatedAt && ($0.nextFutureLog.map { now < $0 } ?? true)
        }) {
            let entry = histories.remove(at: index)
            histories.append(entry)
            history = entry.report
        } else {
            history = StudyStatistics.calculate(logs: material.logs, retrievabilities: [], now: now,
                                                calendar: calendar, startHour: startHour,
                                                selectedDeckIDs: deckIDs, selectedTagIDs: Set(scope.tagIDs))
            #if DEBUG
            historyAggregations += 1
            #endif
            if cached != nil, material.cost + 65536 <= maximumCacheCost {
                // Four compact historical reports at most. Time-dependent card
                // metrics never enter this cache; future logs bound its validity.
                while histories.count >= 4 || material.cost + (histories.count + 1) * 65536 > maximumCacheCost {
                    histories.removeFirst()
                }
                histories.append(HistoryEntry(calendar: calendar, startHour: startHour, day: day, scope: normalized,
                                               evaluatedAt: now, nextFutureLog: material.logs.filter { $0.date > now }.map(\.date).min(),
                                               report: history))
            }
        }
        var report = history.updatingCurrentCards(states, now: now, selectedDeckIDs: deckIDs,
                                                  selectedTagIDs: Set(scope.tagIDs))
        func included(_ deckID: UUID?, _ tags: [UUID]) -> Bool {
            (deckIDs == nil || deckID.map { deckIDs!.contains($0) } == true)
                && Set(scope.tagIDs).isSubset(of: Set(tags))
        }
        let memoryCards = zip(material.cards, states).compactMap { card, state -> MemoryCard? in
            guard included(card.deckID, card.tagIDs), !card.isSuspended, !card.state.isNew,
                  let probability = state.retrievability else { return nil }
            return MemoryCard(id: card.id, title: card.title, stability: card.stability,
                              difficulty: card.difficulty, retrievability: probability)
        }
        let scopedLogs = material.logs.filter { included($0.deckID, $0.tagIDs) }
        let targetDecks = Set(material.cards.filter { included($0.deckID, $0.tagIDs) && !$0.isSuspended }.compactMap(\.deckID))
        report.memory = MemoryAnalysis.calculate(cards: memoryCards, logs: scopedLogs,
            targets: targetDecks.compactMap { material.targets[$0] }, now: now,
            calendar: calendar, startHour: startHour)
        try Task.checkCancellation()
        return report
    }

    private func expire(generation: Int) {
        if cacheGeneration == generation { clearCache() }
    }

    private func readMaterial() throws -> Material {
        try Task.checkCancellation()
        let context = ModelContext(container)
        let notes = try context.fetch(FetchDescriptor<Note>())
        let cards = try context.fetch(FetchDescriptor<StudyCard>())
        let decks = try context.fetch(FetchDescriptor<Deck>())
        let logRows = try context.fetch(FetchDescriptor<StudyReviewLog>())

        let paused = DeckStudyEligibility.pausedIDs(decks.map { ($0.id, $0.parentID, $0.isStudyPaused) })
        let notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        let noteIDByCardID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0.noteID) })

        let baseScheduler = try ReviewScheduler()
        let logs = try logRows.compactMap { row -> StatisticLog? in
            try Task.checkCancellation()
            guard let grade = ReviewGrade(rawValue: row.grade) else { return nil }
            let note = noteIDByCardID[row.cardID].flatMap { notesByID[$0] }
            return StatisticLog(cardID: row.cardID, date: row.reviewedAt, grade: grade,
                                durationMs: row.durationMs,
                                beforeState: try baseScheduler.summary(JSONDecoder().decode(SchedulerSnapshot.self, from: row.fsrsBefore)).state,
                                sequence: row.sequence, wasNew: row.wasNew,
                                deckID: note?.deckID, tagIDs: note?.tagIDs ?? [])
        }
        // Preserve the existing contract: an invalid persisted grade is a
        // data error, not an answer that is silently excluded.
        guard logs.count == logRows.count else { throw StudyError.unsupportedContent }

        let extra = try context.fetch(FetchDescriptor<ExtraPreferences>()).first
        let options = try extra.map { try JSONDecoder().decode(StudyOptions.self, from: $0.payload) }
        let optimization = options?.fsrsOptimization
        let globalTarget = try context.fetch(FetchDescriptor<StudyPreferences>()).first?.desiredRetention ?? 0.9
        let parents = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, $0.parentID) })
        let overrides = options?.deckLearning ?? []
        let targets = Dictionary(uniqueKeysWithValues: decks.map { deck in
            var cursor: UUID? = deck.id, seen = Set<UUID>(), target = globalTarget
            while let id = cursor, seen.insert(id).inserted {
                if let value = overrides.first(where: { $0.deckID == id })?.retention { target = value; break }
                cursor = parents[id] ?? nil
            }
            return (deck.id, target)
        })
        let scheduler = try ReviewScheduler(parameters: optimization?.activeParameters)
        var cost = logs.reduce(0) { $0 + 256 + $1.tagIDs.count * 16 }
        let prepared: [PreparedCard] = try cards.map { card in
            try Task.checkCancellation()
            let note = notesByID[card.noteID]
            let snapshot = try JSONDecoder().decode(SchedulerSnapshot.self, from: card.fsrsPayload)
            let state = try scheduler.predictionState(snapshot)
            cost += 512 + card.fsrsPayload.count + (note?.tagIDs.count ?? 0) * 16
            let summary = try scheduler.summary(snapshot)
            let title = try note.map { try JSONDecoder().decode(TextContent.self, from: $0.contentPayload).question } ?? "カード"
            cost += title.utf8.count
            return PreparedCard(id: card.id, title: title, stability: summary.stability, difficulty: summary.difficulty, deckID: note?.deckID, tagIDs: note?.tagIDs ?? [],
                                isSuspended: card.isSuspended || note.map { paused.contains($0.deckID) } == true, dueDate: card.dueDate, state: state)
        }
        #if DEBUG
        materialReads += 1
        fsrsDecodes += cards.count
        #endif
        cost += decks.count * 64
        return Material(logs: logs, cards: prepared,
                        decks: decks.map { DeckLink(id: $0.id, parentID: $0.parentID) },
                        parameters: optimization?.activeParameters, targets: targets, cost: cost)
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
        let eligible = Set(try queueCards().filter { !$0.suspended }.map(\.id))
        let retention = try cards().filter { eligible.contains($0.id) }.compactMap { card -> Double? in
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
        let scopedIDs = Set(try scopedQueueCards(normalized).filter { !$0.suspended }.map(\.id))
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
            guard card.hiddenUntil.map({ now >= $0 }) ?? true else { return false }
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
