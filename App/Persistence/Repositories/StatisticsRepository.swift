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

        let scheduler = try ReviewScheduler()
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
        let scheduler = try ReviewScheduler()
        let retention = try cards().filter { !$0.isSuspended }.compactMap { card -> Double? in
            let snapshot = try snapshot(card)
            guard try scheduler.summary(snapshot).state != "new" else { return nil }
            return try scheduler.retrievability(snapshot, now: now)
        }
        return StudyStatistics.calculate(logs: logs, retrievabilities: retention, now: now,
                                         calendar: calendar, startHour: try settings().dayStartHour)
    }
}
