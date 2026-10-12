import Foundation
import SwiftData

extension StudyRepository {
    func previewTextReplacement(_ request: ReplacementRequest) throws -> ReplacementPreview {
        try Self.makeReplacementPreview(context: context, request: request)
    }

    nonisolated static func makeReplacementPreview(context: ModelContext, request: ReplacementRequest) throws -> ReplacementPreview {
        guard !request.find.isEmpty, !request.fields.isEmpty else { throw ReplacementError.invalid }
        let allCards = try context.fetch(FetchDescriptor<StudyCard>()), allNotes = try context.fetch(FetchDescriptor<Note>())
        let selected: [StudyCard], included: Set<UUID>?
        switch request.scope {
        case .cards(let ids):
            selected = allCards.filter { ids.contains($0.id) }; included = nil
            guard selected.count == ids.count else { throw ReplacementError.stale }
        case .deck(let id, let children):
            let decks = try context.fetch(FetchDescriptor<Deck>())
            guard decks.contains(where: { $0.id == id }) else { throw ReplacementError.stale }
            var deckIDs: Set<UUID> = [id]
            if children {
                var previous = -1
                while previous != deckIDs.count {
                    previous = deckIDs.count
                    for deck in decks where deck.parentID.map({ deckIDs.contains($0) }) == true { deckIDs.insert(deck.id) }
                }
            }
            included = deckIDs
            let noteIDs = Set(allNotes.filter { included!.contains($0.deckID) }.map(\.id))
            selected = allCards.filter { noteIDs.contains($0.noteID) }
        }
        let ids = Set(selected.map(\.noteID))
        let affected = allNotes.filter { ids.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
        guard affected.count == ids.count else { throw ReplacementError.stale }
        let related = allCards.filter { ids.contains($0.noteID) }
        let variants = Dictionary(grouping: related, by: \.noteID)
        let editKeys = Set(ids.map { "edit:\($0.uuidString)" })
        let draftKeys = Set(try context.fetch(FetchDescriptor<EditorDraft>()).map(\.key)).intersection(editKeys)
        let keys: Set<String> = ["schemaVersion", "question", "answer", "explanation", "hint", "reverseEnabled", "imageID", "masks", "hideAllMasks", "speechOverrides", "speechQuestion", "speechAnswer", "questionAudioID", "answerAudioID", "questionLayout", "answerLayout"]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var rows: [ReplacementPreview.Row] = []
        for note in affected {
            try Task.checkCancellation()
            guard let object = try JSONSerialization.jsonObject(with: note.contentPayload) as? [String: Any],
                  let content = try? JSONDecoder().decode(TextContent.self, from: note.contentPayload) else {
                rows.append(.init(id: note.id, title: "未対応の内容", changes: [], cardCount: variants[note.id]?.count ?? 0, payload: nil, skipReason: "未対応の本文形式")); continue
            }
            var changed = content, changes: [ReplacementPreview.Row.Change] = []
            for field in ReplacementField.allCases where request.fields.contains(field) {
                let before = field.value(in: content), result = request.replacing(before)
                if result.count > 0, result.text != before {
                    field.set(result.text, in: &changed)
                    changes.append(.init(field: field, before: before, after: result.text, count: result.count))
                }
            }
            guard !changes.isEmpty else { continue }
            var reason: String?
            let kind = NoteKind(rawValue: note.type)
            if !(1...2).contains(content.schemaVersion) || !Set(object.keys).isSubset(of: keys) { reason = "未対応の本文・テンプレート形式" }
            else if kind == .cloze { reason = "穴埋めノートは初期版の対象外" }
            else if kind != .basic && kind != .written { reason = "テキストノートのみ対象" }
            else if draftKeys.contains("edit:\(note.id.uuidString)") { reason = "保存前の編集下書きがあります" }
            else if ReplacementField.allCases.contains(where: { field in
                let before = field.value(in: content), after = field.value(in: changed)
                return before.contains("{{") || before.contains("}}") || after.contains("{{") || after.contains("}}")
            }) { reason = "穴埋め・テンプレート構文を含む変更" }
            else if changed.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || changed.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reason = "問題または解答が空になります" }
            else if (try? CardGeneration.variants(kind: kind!, content: changed))?.sorted() != variants[note.id]?.map(\.variantKey).sorted() { reason = "生成カードの構成が一致しません" }
            rows.append(.init(id: note.id, title: content.question, changes: changes, cardCount: variants[note.id]?.count ?? 0,
                              payload: reason == nil ? try encoder.encode(changed) : nil, skipReason: reason))
        }
        return ReplacementPreview(request: request,
            notes: affected.map { .init(id: $0.id, deckID: $0.deckID, type: $0.type, mode: $0.defaultResponseMode, content: $0.contentPayload, tags: $0.tagIDs, updated: $0.updatedAt) },
            cards: related.map { .init(id: $0.id, noteID: $0.noteID, variant: $0.variantKey) }.sorted { $0.id.uuidString < $1.id.uuidString },
            rows: rows, draftKeys: draftKeys, deckMembership: included)
    }

    /// All checks precede mutation. One save or rollback; scheduling and logs are untouched.
    func applyTextReplacement(_ preview: ReplacementPreview, now: Date, cancelled: () -> Bool = { false }) throws -> BulkEditResult {
        try Self.commitTextReplacement(context: context, preview: preview, now: now, save: save, cancelled: cancelled)
    }

    nonisolated static func commitTextReplacement(context: ModelContext, preview: ReplacementPreview, now: Date,
        save: (ModelContext) throws -> Void = { try $0.save() }, cancelled: () -> Bool = { Task.isCancelled }) throws -> BulkEditResult {
        guard !cancelled() else { throw ReplacementError.cancelled }
        let current = try makeReplacementPreview(context: context, request: preview.request)
        guard current == preview else { throw ReplacementError.stale }
        guard !current.changedRows.isEmpty else { throw ReplacementError.empty }
        let changes = Dictionary(uniqueKeysWithValues: current.changedRows.map { ($0.id, $0.payload!) })
        do {
            for note in try context.fetch(FetchDescriptor<Note>()) {
                guard let payload = changes[note.id] else { continue }
                guard !cancelled() else { throw ReplacementError.cancelled }
                note.contentPayload = payload; note.updatedAt = now
            }
            // Any active answer refers to the old wording; reset it without grading.
            if let draft = try context.fetch(FetchDescriptor<SessionDraft>()).first, let id = draft.cardID,
               let card = current.cards.first(where: { $0.id == id && changes[$0.noteID] != nil }) {
                for row in try context.fetch(FetchDescriptor<OrderingDraftRecord>()) { context.delete(row) }
                draft.typedDraft = ""; draft.answerRevealed = false
                draft.activeSince = now; draft.elapsedMs = 0; draft.undoLogID = nil; draft.updatedAt = now
                if draft.answerMode == ResponseMode.ordering.rawValue,
                   let note = current.notes.first(where: { $0.id == card.noteID }), let kind = NoteKind(rawValue: note.type),
                   let data = changes[card.noteID] {
                    let content = try JSONDecoder().decode(TextContent.self, from: data)
                    let displayed = try CardGeneration.displayed(kind: kind, content: content, variant: card.variant)
                    if let problem = try? OrderingAnswer(kind: kind, answer: displayed.answer) {
                        context.insert(OrderingDraftRecord(payload: try JSONEncoder().encode(OrderingDraft(cardID: id, problem: problem))))
                    }
                }
            }
            guard !cancelled() else { throw ReplacementError.cancelled }
            try save(context)
            return BulkEditResult(changedNotes: changes.count, changedCards: current.changedCards)
        } catch {
            context.rollback()
            throw error
        }
    }
}

actor TextReplacementReader {
    let container: ModelContainer
    init(container: ModelContainer) { self.container = container }
    func textReplacementPreview(_ request: ReplacementRequest) throws -> ReplacementPreview {
        try StudyRepository.makeReplacementPreview(context: ModelContext(container), request: request)
    }
    func apply(_ preview: ReplacementPreview, now: Date) throws -> BulkEditResult {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return try StudyRepository.commitTextReplacement(context: context, preview: preview, now: now)
    }
}
