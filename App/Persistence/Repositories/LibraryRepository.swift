import Foundation
import SwiftData

extension StudyRepository {
    func tags() throws -> [Tag] {
        try context.fetch(FetchDescriptor<Tag>(sortBy: [SortDescriptor(\.normalizedName)]))
    }
    func options() throws -> StudyOptions {
        guard let row = try context.fetch(FetchDescriptor<ExtraPreferences>()).first else { return StudyOptions() }
        let value = try JSONDecoder().decode(StudyOptions.self, from: row.payload)
        guard (1...2).contains(value.schemaVersion) else { throw StudyError.unsupportedContent }
        return value
    }
    func updateOptions(_ value: StudyOptions) throws {
        let payload = try JSONEncoder().encode(value)
        try transaction {
            if let row = try context.fetch(FetchDescriptor<ExtraPreferences>()).first { row.payload = payload }
            else { context.insert(try ExtraPreferences(options: value)) }
        }
    }
    // Home preferences never mutate the active session's SessionScope.
    func normalizedScope(_ value: LearningScope) throws -> LearningScope {
        guard value.schemaVersion == 1 else { throw StudyError.unsupportedContent }
        let deckIDs = Set(try decks().map(\.id)), tagIDs = Set(try tags().map(\.id))
        var result = value
        if let id = result.deckID, !deckIDs.contains(id) { result.deckID = nil }
        result.tagIDs = Array(Set(result.tagIDs).intersection(tagIDs)).sorted { $0.uuidString < $1.uuidString }
        return result
    }
    func homeScope() throws -> LearningScope {
        try normalizedScope(options().homeScope ?? LearningScope())
    }
    func applyHomeScope(_ value: LearningScope) throws {
        var saved = try options()
        saved.homeScope = try normalizedScope(value)
        try updateOptions(saved)
    }
    func scope() throws -> LearningScope {
        guard let row = try context.fetch(FetchDescriptor<SessionScope>()).first else { return LearningScope() }
        return try JSONDecoder().decode(LearningScope.self, from: row.payload)
    }
    func setScopeInTransaction(_ scope: LearningScope) throws {
        if let row = try context.fetch(FetchDescriptor<SessionScope>()).first {
            row.payload = try JSONEncoder().encode(scope)
        } else { context.insert(try SessionScope(scope: scope)) }
    }
    func descendants(of id: UUID) throws -> Set<UUID> {
        let all = try decks()
        var result: Set<UUID> = [id]
        var changed = true
        while changed {
            let previous = result.count
            for deck in all where deck.parentID.map({ result.contains($0) }) == true { result.insert(deck.id) }
            changed = result.count != previous
        }
        return result
    }
    func deckPath(_ id: UUID) throws -> String {
        let all = try decks()
        var names: [String] = [], current: UUID? = id, seen: Set<UUID> = []
        while let value = current, !seen.contains(value), let deck = all.first(where: { $0.id == value }) {
            names.insert(deck.name, at: 0); seen.insert(value); current = deck.parentID
        }
        return names.joined(separator: " / ")
    }
    func moveDeck(id: UUID, name: String, parentID: UUID?, learning: DeckLearningOverride? = nil, now: Date) throws {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw StudyError.invalidContent }
        if let parentID {
            guard try decks().contains(where: { $0.id == parentID }) else { throw StudyError.missingRecord }
            guard try !descendants(of: id).contains(parentID) else { throw LibraryError.cycle }
        }
        try transaction {
            guard let deck = try decks().first(where: { $0.id == id }) else { throw StudyError.missingRecord }
            if let learning {
                guard learning.deckID == id else { throw StudyError.invalidContent }
                try setDeckLearningInTransaction(learning)
            }
            deck.name = normalized; deck.parentID = parentID; deck.updatedAt = now
        }
    }
    // Caller confirms deletion and chooses either moving content or deleting it.
    func deleteDeck(id: UUID, moveNotesTo: UUID?, now: Date) throws {
        let deleted = try descendants(of: id)
        if let destination = moveNotesTo {
            guard !deleted.contains(destination), try decks().contains(where: { $0.id == destination }) else {
                throw LibraryError.invalidDestination
            }
        }
        try transaction {
            let affected = try notes().filter { deleted.contains($0.deckID) }
            if let destination = moveNotesTo {
                for note in affected { note.deckID = destination; note.updatedAt = now }
            } else {
                let ids = Set(affected.map(\.id))
                let removed = try cards().filter { ids.contains($0.noteID) }
                if let draft = try session(), removed.contains(where: { $0.id == draft.cardID }) {
                    draft.cardID = nil; try clearOrderingDraft(); draft.typedDraft = ""; draft.answerRevealed = false; draft.activeSince = nil
                }
                if let draft = try session(), let logID = draft.undoLogID,
                   try logs().contains(where: { $0.id == logID }) {
                    // Clear an undo referring to deleted content, without deleting the history itself.
                    if let log = try logs().first(where: { $0.id == logID }), removed.contains(where: { $0.id == log.cardID }) {
                        draft.undoLogID = nil
                    }
                }
                for card in removed { context.delete(card) }
                for note in affected {
                    try removeEditorDraftInTransaction(key: "edit:\(note.id.uuidString)")
                    context.delete(note)
                }
            }
            var selected = try scope()
            if let selectedID = selected.deckID, deleted.contains(selectedID) {
                selected.deckID = moveNotesTo
                try setScopeInTransaction(selected)
            }
            var saved = try options()
            saved.deckLearning?.removeAll { deleted.contains($0.deckID) }
            try writeOptionsInTransaction(saved)
            for deck in try decks().filter({ deleted.contains($0.id) }) { context.delete(deck) }
            if try decks().isEmpty { context.insert(Deck(name: "マイデッキ", now: now)) }
        }
    }
    func tagIDs(for names: [String]) throws -> [UUID] {
        var known = try tags()
        var ids: [UUID] = []
        for name in names {
            let clean = ImportParser.normalized(name)
            if clean.isEmpty { continue }
            let normalized = clean.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            let tag: Tag
            if let existing = known.first(where: { $0.normalizedName == normalized }) { tag = existing }
            else {
                tag = Tag(name: clean, normalizedName: normalized); context.insert(tag); known.append(tag)
            }
            if !ids.contains(tag.id) { ids.append(tag.id) }
        }
        return ids
    }
    func scopedQueueCards(_ scope: LearningScope, cards: [QueueCard]? = nil) throws -> [QueueCard] {
        let decks = try scope.deckID.map { try descendants(of: $0) }
        let eligible = Set(try notes().filter { note in
            (decks == nil || decks!.contains(note.deckID)) && Set(scope.tagIDs).isSubset(of: Set(note.tagIDs))
        }.map(\.id))
        return try (cards ?? queueCards()).filter { $0.noteID.map { eligible.contains($0) } ?? false }
    }
    // Only an explicit ordering override restricts candidates. Use displayed answers
    // so reverse cards follow the same eligibility rules as the study UI.
    func responseEligibleCards(_ cards: [QueueCard], mode: SessionResponseMode) throws -> [QueueCard] {
        guard mode == .ordering else { return cards }
        let candidates = Set(cards.map(\.id))
        let noteMap = Dictionary(uniqueKeysWithValues: try notes().map { ($0.id, $0) })
        var contentMap: [UUID: TextContent] = [:]
        var eligible: Set<UUID> = []
        for card in try self.cards() where candidates.contains(card.id) {
            guard let note = noteMap[card.noteID], let kind = NoteKind(rawValue: note.type) else { throw StudyError.missingRecord }
            let content: TextContent
            if let cached = contentMap[note.id] { content = cached }
            else {
                content = try JSONDecoder().decode(TextContent.self, from: note.contentPayload)
                guard (1...2).contains(content.schemaVersion) else { throw StudyError.unsupportedContent }
                contentMap[note.id] = content
            }
            let displayed = try CardGeneration.displayed(kind: kind, content: content, variant: card.variantKey)
            if OrderingAnswer.reason(kind: kind, answer: displayed.answer) == nil { eligible.insert(card.id) }
        }
        return cards.filter { eligible.contains($0.id) }
    }
    func scopedCounts(scope: LearningScope, now: Date) throws -> HomeCounts {
        var result = try ReviewQueueBuilder(calendar: calendar).counts(cards: scopedQueueCards(scope), logs: queueLogs(), settings: settings(), now: now)
        let global = try counts(now: now)
        result.learnedToday = global.learnedToday; result.answerCount = global.answerCount
        return result
    }
    // One timestamp, one card snapshot and only today's logs. No displayed content,
    // full historical statistics, writes, or notification work in the polling path.
    func homeSnapshot(now: Date, cards: [QueueCard]? = nil, logs: [QueueLog]? = nil) throws -> HomeSnapshot {
        let selected = try homeScope(), settings = try settings()
        let day = StudyDay(calendar: calendar, startHour: settings.dayStartHour).interval(containing: now)
        let start = day.start, end = day.end
        let all = try cards ?? queueCards()
        let scoped = try responseEligibleCards(scopedQueueCards(selected, cards: all), mode: options().sessionResponseMode ?? .cardDefault)
        let today = try logs ?? todayQueueLogs(cards: all, settings: settings, now: now)
        let builder = ReviewQueueBuilder(calendar: calendar)
        let global = builder.counts(cards: all, logs: today, settings: settings, now: now)
        var counts = builder.counts(cards: scoped, logs: today, settings: settings, now: now)
        counts.learnedToday = global.learnedToday; counts.answerCount = global.answerCount
        let used = Set(today.filter(\.wasNew).map(\.cardID)).count
        let next = scoped.filter { !$0.suspended && ["learning", "relearning"].contains($0.state) && $0.due > now }.map(\.due).min()
        return HomeSnapshot(scope: selected, counts: counts, globalCounts: global,
                            newSlotsRemaining: max(0, settings.dailyNewLimit - used), nextShortDue: next,
                            hasCards: !all.isEmpty, dayStart: start,
                            nextRefresh: min(end, all.filter { !$0.suspended && $0.state != "new" && $0.due > now }.map(\.due).min() ?? end))
    }
    func duplicate(of input: NoteInput) throws -> Note? {
        let question = ImportParser.normalized(input.question), answer = ImportParser.normalized(input.answer)
        for note in try notes() where note.deckID == input.deckID && note.type == input.kind.rawValue {
            let content = try JSONDecoder().decode(TextContent.self, from: note.contentPayload)
            if ImportParser.normalized(content.question) == question && ImportParser.normalized(content.answer) == answer { return note }
        }
        return nil
    }

    // Validate rows first; publish content and batch counts in one save. A save failure
    // rolls back every inserted Note/Card/Tag and reports no successful import.
    func importRows(_ rows: [ImportRow], deckID: UUID, kind: NoteKind, tagNames: [String],
                    action: DuplicateAction, resetHistory: Bool = false, source: String, now: Date) throws -> ImportResult {
        var valid: [(ImportRow, NoteInput, Data)] = [], errors: [String] = []
        let initialNoteIDs = Set(try notes().map(\.id))
        var createdNoteIDs = Set<UUID>(), updatedNoteIDs = Set<UUID>(), createdCardIDs = Set<UUID>(), maintainedCardIDs = Set<UUID>()
        let excluded = rows.filter { !$0.included }.count
        var duplicates = 0, skipped = 0
        for row in rows {
            if !row.included { skipped += 1; continue }
            let requestedMode = row.responseMode ?? .mental
            let effectiveMode: ResponseMode = requestedMode == .ordering && OrderingAnswer.reason(kind: kind, answer: row.answer) != nil ? .mental : requestedMode
            let input = NoteInput(deckID: deckID, kind: kind, question: row.question, answer: row.answer,
                                  explanation: row.explanation, hint: row.hint, responseMode: effectiveMode, tagNames: tagNames, questionLayout: row.questionLayout, answerLayout: row.answerLayout)
            do { valid.append((row, input, try validate(input))) }
            catch { errors.append("\(row.line)行: \(error.localizedDescription)") }
        }
        let scheduler = try ReviewScheduler(desiredRetention: settings().desiredRetention)
        let fresh = try JSONEncoder().encode(scheduler.newCard(now: now))
        return try transaction {
            var imported = 0
            for (row, input, content) in valid {
                if let existing = try duplicate(of: input) {
                    if action == .skip { skipped += 1; duplicates += 1; continue }
                    if action == .update {
                        var merged = try JSONDecoder().decode(TextContent.self, from: existing.contentPayload)
                        merged.question = input.question; merged.answer = input.answer
                        merged.explanation = input.explanation
                        if let hint = input.hint { merged.hint = hint }
                        if let value = input.questionLayout { merged.questionLayout = value }
                        if let value = input.answerLayout { merged.answerLayout = value }
                        existing.contentPayload = try JSONEncoder().encode(merged); existing.updatedAt = now
                        if row.responseMode != nil { existing.defaultResponseMode = input.responseMode.rawValue }
                        existing.tagIDs = try tagIDs(for: tagNames)
                        let existingCards = try cards().filter { $0.noteID == existing.id }
                        if initialNoteIDs.contains(existing.id) {
                            updatedNoteIDs.insert(existing.id); maintainedCardIDs.formUnion(existingCards.map(\.id))
                        }
                        if resetHistory {
                            for card in existingCards {
                                card.fsrsPayload = fresh; card.dueDate = now; card.updatedAt = now
                            }
                        }
                        imported += 1; continue
                    }
                }
                let note = Note(input: input, content: content, now: now)
                note.tagIDs = try tagIDs(for: tagNames); context.insert(note); createdNoteIDs.insert(note.id)
                let value = try JSONDecoder().decode(TextContent.self, from: content)
                for key in try CardGeneration.variants(kind: kind, content: value) {
                    let card = StudyCard(noteID: note.id, variantKey: key, payload: fresh, now: now)
                    context.insert(card); createdCardIDs.insert(card.id)
                }
                imported += 1
            }
            context.insert(ImportBatch(source: source, now: now, success: imported, skipped: skipped, errors: errors))
            return ImportResult(imported: imported, skipped: skipped, errors: errors, createdNotes: createdNoteIDs.count,
                                updatedNotes: updatedNoteIDs.count, createdCards: createdCardIDs.count, maintainedCards: maintainedCardIDs.count,
                                duplicateRows: duplicates, excludedRows: excluded)
        }
    }
}


extension StudyRepository {
    func previewBulkEdit(cardIDs: Set<UUID>, action: BulkEditAction) throws -> BulkEditPreview {
        guard !cardIDs.isEmpty else { throw BulkEditError.emptySelection }
        let allCards = try cards(), selected = allCards.filter { cardIDs.contains($0.id) }
        guard selected.count == cardIDs.count else { throw BulkEditError.staleSelection }
        let ids = Set(selected.map(\.noteID)), related = allCards.filter { ids.contains($0.noteID) }
        let affected = try notes().filter { ids.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
        guard affected.count == ids.count else { throw BulkEditError.staleSelection }
        let known = try tags(), deckMap = Dictionary(uniqueKeysWithValues: try decks().map { ($0.id, $0.name) })
        var changedNotes = Set<UUID>(), changedCards = Set<UUID>(), detail = ""
        let normalizedAction: BulkEditAction
        switch action {
        case .move(let destination):
            guard deckMap[destination] != nil else { throw LibraryError.invalidDestination }
            normalizedAction = action; detail = "移動先: \(try deckPath(destination))"
            changedNotes = Set(affected.filter { $0.deckID != destination }.map(\.id))
        case .addTags(let names):
            let clean = Array(Set(names.map(ImportParser.normalized).filter { !$0.isEmpty })).sorted()
            guard !clean.isEmpty, clean.count <= 100, clean.allSatisfy({ $0.count <= 100 }) else { throw BulkEditError.invalidTags }
            normalizedAction = .addTags(clean); detail = "追加タグ: \(clean.joined(separator: "、"))"
            for note in affected {
                let present = Set(known.filter { note.tagIDs.contains($0.id) }.map { Self.bulkTagKey($0.name) })
                if clean.contains(where: { !present.contains(Self.bulkTagKey($0)) }) { changedNotes.insert(note.id) }
            }
        case .removeTags(let tagIDs):
            guard !tagIDs.isEmpty, tagIDs.isSubset(of: Set(known.map(\.id))) else { throw BulkEditError.invalidTags }
            normalizedAction = action
            detail = "除去タグ: \(known.filter { tagIDs.contains($0.id) }.map(\.name).joined(separator: "、"))"
            changedNotes = Set(affected.filter { !tagIDs.isDisjoint(with: $0.tagIDs) }.map(\.id))
        case .suspended(let value):
            normalizedAction = action; detail = "選択したカードだけを変更します。兄弟カードは変更しません。"
            changedCards = Set(selected.filter { $0.isSuspended != value }.map(\.id))
        case .deleteNotes:
            normalizedAction = action; detail = "対象ノートと兄弟カード、関連する編集下書きを削除します。過去の回答履歴は残ります。"
            changedNotes = ids
        }
        if case .suspended = normalizedAction {} else {
            changedCards = Set(related.filter { changedNotes.contains($0.noteID) }.map(\.id))
        }
        let noteStates = affected.map { BulkEditPreview.NoteState(id: $0.id, deckID: $0.deckID, content: $0.contentPayload, type: $0.type, responseMode: $0.defaultResponseMode, tags: $0.tagIDs, updated: $0.updatedAt) }
        let cardStates = related.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            BulkEditPreview.CardState(id: $0.id, noteID: $0.noteID, fsrs: $0.fsrsPayload, due: $0.dueDate, updated: $0.updatedAt, suspended: $0.isSuspended)
        }
        let keys = Set(ids.map { "edit:\($0.uuidString)" })
        let drafts = try context.fetch(FetchDescriptor<EditorDraft>()).filter { keys.contains($0.key) }.sorted { $0.key < $1.key }.map {
            BulkEditPreview.DraftState(key: $0.key, payload: $0.payload, updated: $0.updatedAt)
        }
        let counts = Dictionary(grouping: related, by: \.noteID).mapValues(\.count)
        let paths = try Dictionary(uniqueKeysWithValues: Set(affected.map(\.deckID)).map { ($0, try deckPath($0)) })
        let rows = try affected.map { note in
            BulkEditPreview.Row(id: note.id, question: try JSONDecoder().decode(TextContent.self, from: note.contentPayload).question,
                                deck: paths[note.deckID] ?? "", cardCount: counts[note.id] ?? 0)
        }
        return BulkEditPreview(selection: cardIDs, action: normalizedAction, notes: noteStates, cards: cardStates, drafts: drafts,
                               rows: rows, changedNotes: changedNotes, changedCards: changedCards, detail: detail)
    }
    private static func bulkTagKey(_ name: String) -> String {
        ImportParser.normalized(name).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    func applyBulkEdit(_ preview: BulkEditPreview, now: Date) throws -> BulkEditResult {
        let current = try previewBulkEdit(cardIDs: preview.selection, action: preview.action)
        guard current.notes == preview.notes, current.cards == preview.cards, current.drafts == preview.drafts,
              current.detail == preview.detail, current.rows == preview.rows, current.changedNotes == preview.changedNotes,
              current.changedCards == preview.changedCards else { throw BulkEditError.staleSelection }
        if current.changedCount == 0 { return BulkEditResult(changedNotes: 0, changedCards: 0) }
        let noteIDs = current.changedNotes, cardIDs = current.changedCards
        return try transaction {
            let affected = try notes().filter { noteIDs.contains($0.id) }
            let cards = try cards().filter { cardIDs.contains($0.id) }
            let draftKeys = Set(current.drafts.map(\.key))
            let drafts = try context.fetch(FetchDescriptor<EditorDraft>()).filter { draftKeys.contains($0.key) }
            var added: [UUID] = [], removedNames = Set<String>()
            if case .addTags(let names) = current.action { added = try tagIDs(for: names) }
            if case .removeTags(let ids) = current.action { removedNames = Set(try tags().filter { ids.contains($0.id) }.map { Self.bulkTagKey($0.name) }) }
            for note in affected {
                switch current.action {
                case .move(let id): note.deckID = id
                case .addTags: note.tagIDs = Array(Set(note.tagIDs + added)).sorted { $0.uuidString < $1.uuidString }
                case .removeTags(let ids): note.tagIDs.removeAll { ids.contains($0) }
                case .deleteNotes: context.delete(note)
                case .suspended: break
                }
                if current.action != .deleteNotes { note.updatedAt = now }
            }
            for card in cards {
                switch current.action {
                case .suspended(let value): card.isSuspended = value; card.updatedAt = now
                case .deleteNotes: context.delete(card)
                default: break // Metadata is on Note; FSRS and Card identities are untouched.
                }
            }
            for draft in drafts {
                guard let noteID = UUID(uuidString: String(draft.key.dropFirst(5))), noteIDs.contains(noteID) else { continue }
                if current.action == .deleteNotes { context.delete(draft); continue }
                var input = try JSONDecoder().decode(NoteInput.self, from: draft.payload)
                switch current.action {
                case .move(let id): input.deckID = id
                case .addTags(let names):
                    var keys = Set(input.tagNames.map(Self.bulkTagKey))
                    for name in names where keys.insert(Self.bulkTagKey(name)).inserted { input.tagNames.append(name) }
                case .removeTags: input.tagNames.removeAll { removedNames.contains(Self.bulkTagKey($0)) }
                default: break
                }
                draft.payload = try JSONEncoder().encode(input); draft.updatedAt = now
            }
            if case .deleteNotes = current.action {
                if let draft = try session() {
                    if let id = draft.cardID, cardIDs.contains(id) {
                        draft.cardID = nil; try clearOrderingDraft(); draft.typedDraft = ""; draft.answerRevealed = false; draft.activeSince = nil; draft.elapsedMs = 0
                    }
                    if let undo = draft.undoLogID, try logs().contains(where: { $0.id == undo && cardIDs.contains($0.cardID) }) { draft.undoLogID = nil }
                    draft.touchedCardIDs.removeAll { cardIDs.contains($0) }
                }
            } else if case .suspended(true) = current.action, let draft = try session(), let id = draft.cardID, cardIDs.contains(id) {
                draft.cardID = nil; try clearOrderingDraft(); draft.typedDraft = ""; draft.answerRevealed = false; draft.activeSince = nil; draft.elapsedMs = 0
            }
            return BulkEditResult(changedNotes: noteIDs.count, changedCards: cardIDs.count)
        }
    }
}


extension StudyRepository {
    /// Captures membership, the full deck hierarchy and all affected Note/Card/Draft
    /// states. The caller must show these counts and explicitly confirm before applying.
    func previewDeckContents(deckID: UUID, scope: DeckContentsScope, action: DeckContentsAction) throws -> DeckContentsPreview {
        let allDecks = try decks()
        guard allDecks.contains(where: { $0.id == deckID }) else { throw StudyError.missingRecord }
        let descendants = try descendants(of: deckID)
        let included: Set<UUID> = scope == .direct ? [deckID] : descendants

        let bulkAction: BulkEditAction
        var destinationPath: String?
        switch action {
        case .move(to: let destination):
            // Moving direct notes into a child is permitted; moving all descendants
            // into their own subtree is not, to avoid surprising mixed membership.
            guard destination != deckID,
                  allDecks.contains(where: { $0.id == destination }),
                  !(scope == .includingDescendants && descendants.contains(destination))
            else { throw LibraryError.invalidDestination }
            destinationPath = try deckPath(destination)
            bulkAction = .move(destination)
        case .delete:
            bulkAction = .deleteNotes
        }

        let matchingNotes = try notes().filter { included.contains($0.deckID) }
        let noteIDs = Set(matchingNotes.map(\.id))
        let cardIDs = Set(try cards().filter { noteIDs.contains($0.noteID) }.map(\.id))
        // Bulk edits operate on notes via their cards. Refuse structurally broken
        // data instead of silently leaving zero-card notes behind.
        let bulk = cardIDs.isEmpty ? nil : try previewBulkEdit(cardIDs: cardIDs, action: bulkAction)
        guard noteIDs.isEmpty || Set(bulk?.notes.map(\.id) ?? []) == noteIDs
        else { throw BulkEditError.staleSelection }

        let hierarchy = allDecks.map {
            DeckContentsPreview.DeckState(id: $0.id, name: $0.name, parentID: $0.parentID,
                                          sortOrder: $0.sortOrder, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let childPaths = try allDecks.filter { included.contains($0.id) && $0.id != deckID }
            .map { try deckPath($0.id) }.sorted()

        return DeckContentsPreview(sourceID: deckID, scope: scope, action: action,
                                   hierarchy: hierarchy, sourcePath: try deckPath(deckID),
                                   destinationPath: destinationPath, includedChildPaths: childPaths,
                                   noteIDs: noteIDs, cardIDs: cardIDs, bulk: bulk)
    }

    /// Never applies an old preview when membership, hierarchy, destination, content,
    /// scheduling, or editor drafts changed. applyBulkEdit performs a second snapshot
    /// comparison and the entire mutation inside its rollback-on-save-failure transaction.
    func applyDeckContents(_ preview: DeckContentsPreview, now: Date) throws -> BulkEditResult {
        let current = try previewDeckContents(deckID: preview.sourceID, scope: preview.scope, action: preview.action)
        guard current.hierarchy == preview.hierarchy,
              current.sourcePath == preview.sourcePath,
              current.destinationPath == preview.destinationPath,
              current.includedChildPaths == preview.includedChildPaths,
              current.noteIDs == preview.noteIDs, current.cardIDs == preview.cardIDs
        else { throw BulkEditError.staleSelection }

        guard let initial = preview.bulk, let latest = current.bulk else { throw BulkEditError.emptySelection }
        guard initial.selection == latest.selection, initial.action == latest.action,
              initial.notes == latest.notes, initial.cards == latest.cards,
              initial.drafts == latest.drafts, initial.rows == latest.rows,
              initial.detail == latest.detail, initial.changedNotes == latest.changedNotes,
              initial.changedCards == latest.changedCards
        else { throw BulkEditError.staleSelection }
        guard latest.changedNotes.count > 0 else { throw BulkEditError.emptySelection }
        return try applyBulkEdit(initial, now: now)
    }
}

extension StudyRepository {
    func targetedDeckPath(_ id: UUID) throws -> String {
        var names: [String] = [], current: UUID? = id, seen: Set<UUID> = []
        while let value = current, seen.insert(value).inserted {
            var fetch = FetchDescriptor<Deck>(predicate: #Predicate { $0.id == value })
            fetch.fetchLimit = 1
            guard let row = try context.fetch(fetch).first else { break }
            names.insert(row.name, at: 0)
            current = row.parentID
        }
        return names.joined(separator: " / ")
    }
    func deckAncestorMap() throws -> [UUID: [UUID]] {
        let rows = try decks()
        let parents = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.parentID) })
        return Dictionary(uniqueKeysWithValues: rows.map { row in
            var result: [UUID] = [], current: UUID? = row.id, seen: Set<UUID> = []
            while let id = current, seen.insert(id).inserted {
                result.append(id); current = parents[id] ?? nil
            }
            return (row.id, result)
        })
    }
    func deckAncestors(_ id: UUID) throws -> [UUID] {
        let rows = try decks()
        var result: [UUID] = [], current: UUID? = id
        while let next = current, !result.contains(next) {
            result.append(next)
            current = rows.first { $0.id == next }?.parentID
        }
        return result
    }
    func deckRetention(_ id: UUID) throws -> Double {
        let saved = try options().deckLearning ?? []
        for ancestor in try deckAncestors(id) {
            if let value = saved.first(where: { $0.deckID == ancestor })?.retention { return value }
        }
        return try settings().desiredRetention
    }
    func deckLimits(_ id: UUID) throws -> [UUID: Int] {
        let ancestors = try deckAncestors(id)
        return Dictionary(uniqueKeysWithValues: (try options().deckLearning ?? []).compactMap {
            guard ancestors.contains($0.deckID), let limit = $0.newLimit else { return nil }
            return ($0.deckID, limit)
        })
    }
    func saveDeckLearning(_ value: DeckLearningOverride) throws {
        try transaction { try setDeckLearningInTransaction(value) }
    }
    private func setDeckLearningInTransaction(_ value: DeckLearningOverride) throws {
        guard value.isValid, try decks().contains(where: { $0.id == value.deckID }) else { throw StudyError.invalidContent }
        var saved = try options()
        var rows = saved.deckLearning ?? []
        rows.removeAll { $0.deckID == value.deckID }
        if value.newLimit != nil || value.retention != nil { rows.append(value) }
        saved.deckLearning = rows
        try writeOptionsInTransaction(saved)
    }
    func quotaMap() throws -> (usage: [Int: [UUID]], cards: [UUID: [UUID]]) {
        let ancestors = try deckAncestorMap()
        let noteDecks = Dictionary(uniqueKeysWithValues: try notes().map { ($0.id, $0.deckID) })
        let cards = try Dictionary(uniqueKeysWithValues: self.cards().map {
            ($0.id, noteDecks[$0.noteID].flatMap { ancestors[$0] } ?? [])
        })
        let usage = Dictionary(uniqueKeysWithValues: (try options().deckNewUsage ?? []).map { ($0.sequence, $0.quotaDeckIDs) })
        return (usage, cards)
    }
    func writeOptionsInTransaction(_ saved: StudyOptions) throws {
        if let row = try context.fetch(FetchDescriptor<ExtraPreferences>()).first { row.payload = try JSONEncoder().encode(saved) }
        else { context.insert(try ExtraPreferences(options: saved)) }
    }
}

extension StudyRepository {
    func optimizationState() throws -> FSRSOptimizationState {
        let state = try options().fsrsOptimization ?? FSRSOptimizationState()
        guard state.valid else { throw OptimizationError.invalid }
        return state
    }
    func optimizationReviews() throws -> [OptimizationReview] {
        guard try context.fetchCount(FetchDescriptor<StudyReviewLog>()) <= 10000 else { throw OptimizationError.tooLarge }
        let rows = try logs()
        let scheduler = try ReviewScheduler()
        return try rows.map { row in
            let before = try JSONDecoder().decode(SchedulerSnapshot.self, from: row.fsrsBefore)
            return OptimizationReview(id: row.id, cardID: row.cardID, date: row.reviewedAt, grade: row.grade,
                                      sequence: row.sequence, startsNew: try scheduler.summary(before).state == "new")
        }
    }
    func saveOptimizationReport(_ report: OptimizationReport) throws {
        guard report.valid else { throw OptimizationError.invalid }
        try transaction {
            var options = try options(), state = try optimizationState()
            let reviews = try optimizationReviews(), prepared = try FSRSOptimization.prepare(reviews)
            guard try FSRSOptimization.digest(reviews) == report.digest,
                  state.activeParameters == report.previousParameters,
                  report.reviews == reviews.count, report.days == prepared.days, report.splitDate == prepared.split,
                  report.standard.count == prepared.events.filter({ prepared.eligible.contains($0.id) && $0.date > prepared.split }).count
            else { throw OptimizationError.stale }
            state.report = report; options.fsrsOptimization = state
            try persistOptimizationOptions(options)
        }
    }
    func applyOptimization(now: Date) throws {
        try transaction {
            var options = try options(), state = try optimizationState()
            guard let report = state.report, report.valid, report.accepted else { throw OptimizationError.invalid }
            let reviews = try optimizationReviews(), prepared = try FSRSOptimization.prepare(reviews)
            guard try FSRSOptimization.digest(reviews) == report.digest,
                  state.activeParameters == report.previousParameters,
                  report.reviews == reviews.count, report.days == prepared.days, report.splitDate == prepared.split,
                  report.standard.count == prepared.events.filter({ prepared.eligible.contains($0.id) && $0.date > prepared.split }).count
            else { throw OptimizationError.stale }
            state.changes.append(FSRSParameterChange(date: now, method: report.method, before: state.activeParameters, after: report.parameters))
            state.changes = Array(state.changes.suffix(20)); state.activeParameters = report.parameters
            options.fsrsOptimization = state; try persistOptimizationOptions(options)
        }
    }
    func resetOptimization(now: Date) throws {
        try transaction {
            var options = try options(), state = try optimizationState()
            guard state.activeParameters != nil else { return }
            state.changes.append(FSRSParameterChange(date: now, method: OptimizationReport.method, before: state.activeParameters, after: nil))
            state.changes = Array(state.changes.suffix(20)); state.activeParameters = nil
            options.fsrsOptimization = state; try persistOptimizationOptions(options)
        }
    }
    private func persistOptimizationOptions(_ options: StudyOptions) throws {
        if let row = try context.fetch(FetchDescriptor<ExtraPreferences>()).first {
            row.payload = try JSONEncoder().encode(options)
        } else { context.insert(try ExtraPreferences(options: options)) }
    }
}

/// The separate read context keeps projection decoding and search off the UI actor.
actor LibraryReader {
    private let container: ModelContainer
    private var revision: Int?
    private var cached: LibraryIndex?
    private var searchText: [UUID: String] = [:]
    private var loadedDecks = Set<UUID>()

    init(container: ModelContainer) { self.container = container }

    func load(revision: Int) throws -> LibraryIndex {
        if self.revision == revision, let cached { return cached }
        let index = try Self.read(context: ModelContext(container))
        self.revision = revision; cached = index; searchText = [:]; loadedDecks = []
        return index
    }

    func search(_ query: String, revision: Int, deckIDs: Set<UUID>?) throws -> LibraryResults {
        let index = try contents(revision: revision, deckIDs: deckIDs)
        let scope = index.results(deckIDs: deckIDs)
        guard !query.isEmpty else { return scope }
        var matches = Set<UUID>()
        for card in scope.cardsByDeck.values.joined() {
            try Task.checkCancellation()
            let text: String
            if let cached = searchText[card.id] { text = cached }
            else {
                let displayed = try index.displayed(card)
                guard let note = index.notes[card.noteID] else { throw StudyError.missingRecord }
                text = "\(displayed.question) \(displayed.answer) \(note.deckName) \(note.tagNames)"
                searchText[card.id] = text
            }
            if text.localizedCaseInsensitiveContains(query) { matches.insert(card.id) }
        }
        return index.results(deckIDs: deckIDs, matching: matches)
    }

    func contents(revision: Int, deckIDs: Set<UUID>?) throws -> LibraryIndex {
        var index = try load(revision: revision)
        let missing = (deckIDs ?? Set(index.cardsByDeck.keys)).subtracting(loadedDecks)
        guard !missing.isEmpty else { return index }
        let requested = Array(missing)
        var fetch = FetchDescriptor<Note>(predicate: #Predicate { requested.contains($0.deckID) })
        fetch.propertiesToFetch = [\.id, \.contentPayload]
        struct Projection: Decodable {
            let schemaVersion: Int
            let question: String
            let answer: String
            let masks: [ImageMask]?
        }
        // Read only requested decks, once per revision. No detail or FSRS decoding.
        for note in try ModelContext(container).fetch(fetch) {
            try Task.checkCancellation()
            guard index.siblingCounts[note.id] != nil else { continue }
            let projection = try JSONDecoder().decode(Projection.self, from: note.contentPayload)
            guard (1...2).contains(projection.schemaVersion) else { throw StudyError.unsupportedContent }
            var content = TextContent(question: projection.question, answer: projection.answer, explanation: "")
            content.masks = projection.masks
            index.notes[note.id]?.content = content
        }
        cached = index; loadedDecks.formUnion(missing)
        return index
    }

    static func read(context: ModelContext) throws -> LibraryIndex {
        let paths = LibraryIndex.deckPaths(try context.fetch(FetchDescriptor<Deck>()))
        let tags = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Tag>()).map { ($0.id, $0.name) })
        var noteFetch = FetchDescriptor<Note>()
        noteFetch.propertiesToFetch = [\.id, \.deckID, \.type, \.tagIDs]
        var index = LibraryIndex(), deckIDs: [UUID: UUID] = [:]
        for note in try context.fetch(noteFetch) {
            guard let kind = NoteKind(rawValue: note.type) else { throw StudyError.missingRecord }
            index.notes[note.id] = LibraryNote(kind: kind, content: nil, deckName: paths[note.deckID] ?? "", tagNames: note.tagIDs.compactMap { tags[$0] }.joined(separator: " "))
            deckIDs[note.id] = note.deckID
        }
        var cardFetch = FetchDescriptor<StudyCard>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        cardFetch.propertiesToFetch = [\.id, \.noteID, \.variantKey, \.isSuspended, \.createdAt]
        for card in try context.fetch(cardFetch) {
            guard let deck = deckIDs[card.noteID] else { throw StudyError.missingRecord }
            index.cardsByDeck[deck, default: []].append(LibraryCard(id: card.id, noteID: card.noteID, deckID: deck, variantKey: card.variantKey, isSuspended: card.isSuspended, createdAt: card.createdAt))
            index.siblingCounts[card.noteID, default: 0] += 1
            index.cardCount += 1
        }
        return index
    }
}
