import Foundation
import SwiftData

extension StudyRepository {
    func clearOrderingDraft() throws {
        for record in try context.fetch(FetchDescriptor<OrderingDraftRecord>()) { context.delete(record) }
    }
    func orderingDraft(for item: NoteItem) throws -> OrderingDraft? {
        guard let problem = try? OrderingAnswer(kind: item.kind, answer: item.content.answer),
              let record = try context.fetch(FetchDescriptor<OrderingDraftRecord>()).first,
              let state = try? JSONDecoder().decode(OrderingDraft.self, from: record.payload),
              state.isValid(for: problem, cardID: item.cardID) else { return nil }
        return state
    }
    // Called only within a write transaction, never while rendering/polling.
    func prepareOrderingDraft(_ draft: SessionDraft) throws {
        guard draft.answerMode == ResponseMode.ordering.rawValue, let id = draft.cardID,
              let item = try noteItems(cardID: id).first,
              let problem = try? OrderingAnswer(kind: item.kind, answer: item.content.answer) else { return }
        if try orderingDraft(for: item) == nil {
            try clearOrderingDraft()
            var state = OrderingDraft(cardID: id, problem: problem)
            state.answerShown = draft.answerRevealed
            context.insert(OrderingDraftRecord(payload: try JSONEncoder().encode(state)))
        }
    }
    func markOrderingAnswerShown() throws {
        guard let record = try context.fetch(FetchDescriptor<OrderingDraftRecord>()).first,
              var state = try? JSONDecoder().decode(OrderingDraft.self, from: record.payload) else { return }
        state.answerShown = true
        record.payload = try JSONEncoder().encode(state)
    }
    func updateOrdering(_ action: OrderingAction, now: Date) throws {
        try transaction {
            guard let draft = try session(), draft.answerMode == ResponseMode.ordering.rawValue,
                  !draft.answerRevealed, let id = draft.cardID,
                  let item = try noteItems(cardID: id).first else { throw StudyError.noSession }
            try prepareOrderingDraft(draft)
            guard let record = try context.fetch(FetchDescriptor<OrderingDraftRecord>()).first,
                  var state = try orderingDraft(for: item) else { throw OrderingError.invalidDraft }
            let problem = try OrderingAnswer(kind: item.kind, answer: item.content.answer)
            try state.apply(action, problem: problem)
            if state.result == .correct { draft.answerRevealed = true }
            record.payload = try JSONEncoder().encode(state)
            draft.updatedAt = now
        }
    }
}
