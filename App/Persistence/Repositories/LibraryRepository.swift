import Foundation
import SwiftData

extension StudyRepository {
    func tags() throws -> [Tag] {
        try context.fetch(FetchDescriptor<Tag>(sortBy: [SortDescriptor(\.normalizedName)]))
    }
    func options() throws -> StudyOptions {
        guard let row = try context.fetch(FetchDescriptor<ExtraPreferences>()).first else { return StudyOptions() }
        let value = try JSONDecoder().decode(StudyOptions.self, from: row.payload)
        guard Set((value.cardMarks ?? []).map(\.cardID)).count == (value.cardMarks ?? []).count,
              (value.cardMarks ?? []).allSatisfy({ $0.hiddenUntil?.timeIntervalSince1970.isFinite ?? true }),
              (1...2).contains(value.schemaVersion) else { throw StudyError.unsupportedContent }
        return value
    }
    func updateOptions(_ value: StudyOptions) throws {
        try transaction { try writeOptionsInTransaction(value) }
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
            try pauseSessionIfNeeded(now: now)
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
                try pruneCardMarks()
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
        let eligible = try queueScopeNoteIDs(scope)
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
        let next = scoped.filter { !$0.suspended && !$0.isHidden(at: now) && ["learning", "relearning"].contains($0.state) && $0.due > now }.map(\.due).min()
        return HomeSnapshot(scope: selected, counts: counts, globalCounts: global,
                            newSlotsRemaining: max(0, settings.dailyNewLimit - used), nextShortDue: next,
                            hasCards: !all.isEmpty, dayStart: start,
                            nextRefresh: min(end, all.filter { !$0.suspended && !$0.isHidden(at: now) && $0.state != "new" && $0.due > now }.map(\.due).min() ?? end),
                            studyPaused: !scoped.isEmpty && scoped.allSatisfy(\.studyPaused),
                            medianAnswerSeconds: try homeAnswerMedian(cardIDs: Set(scoped.filter { !$0.suspended && !$0.isHidden(at: now) }.map(\.id)), responseMode: options().sessionResponseMode ?? .cardDefault, now: now, day: start))
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
        let prepared = try PreparedTextImport.make(rows, deckID: deckID, kind: kind, tagNames: tagNames)
        return try importPreparedRows(prepared, action: action, resetHistory: resetHistory, source: source, now: now)
    }

    func importPreparedRows(_ prepared: PreparedTextImport, action: DuplicateAction,
                            resetHistory: Bool = false, source: String, now: Date) throws -> ImportResult {
        try transaction {
            try TextImportWriter(context: context).apply(prepared, action: action,
                resetHistory: resetHistory, source: source, now: now, desiredRetention: try settings().desiredRetention)
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
                try pruneCardMarks()
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
        var last: [UUID: (after: SchedulerSnapshot, date: Date)] = [:]
        return try rows.map { row in
            let before = try JSONDecoder().decode(SchedulerSnapshot.self, from: row.fsrsBefore)
            let after = try JSONDecoder().decode(SchedulerSnapshot.self, from: row.fsrsAfter)
            let startsNew = try scheduler.summary(before).state == "new"
            if let previous = last[row.cardID] {
                // A clock reversal cannot be repaired by sorting dates. A missing
                // middle log must not silently turn into a complete training series.
                guard row.reviewedAt >= previous.date,
                      startsNew || before == previous.after else { throw OptimizationError.invalid }
            }
            last[row.cardID] = (after, row.reviewedAt)
            return OptimizationReview(id: row.id, cardID: row.cardID, date: row.reviewedAt, grade: row.grade,
                                      sequence: row.sequence, startsNew: startsNew)
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
    private var contentCosts: [UUID: Int] = [:]
    private var deckRecency: [UUID] = []
    private var searchBytes = 0
    private let maximumContentBytes: Int
    private let maximumCachedDecks: Int
    private let maximumSearchBytes: Int
    #if DEBUG
    private(set) var contentFetches = 0
    private(set) var contentDecodes = 0
    private(set) var rowPreparations = 0
    var retainedContentBytes: Int { contentCosts.values.reduce(0, +) }
    var retainedSearchBytes: Int { searchBytes }
    #endif
    private var scheduleRevision: Int?
    private var scheduleCache: [UUID: LibrarySearchSchedule] = [:]

    init(container: ModelContainer, maximumContentBytes: Int = 8 * 1024 * 1024,
         maximumCachedDecks: Int = 32, maximumSearchBytes: Int = 2 * 1024 * 1024) {
        self.container = container; self.maximumContentBytes = max(0, maximumContentBytes)
        self.maximumCachedDecks = max(0, maximumCachedDecks); self.maximumSearchBytes = max(0, maximumSearchBytes)
    }

    func clearContents() {
        guard !loadedDecks.isEmpty || !searchText.isEmpty else { return }
        guard var index = cached else { return }
        for id in index.notes.keys { index.notes[id]?.content = nil }
        index.rowContents = [:]; cached = index
        loadedDecks = []; contentCosts = [:]; deckRecency = []
        searchText = [:]; searchBytes = 0
    }

    func load(revision: Int) throws -> LibraryIndex {
        let interval = PerformanceProbe.begin("Library.metadata")
        defer { PerformanceProbe.end(interval) }
        if self.revision == revision, let cached { return cached }
        let index = try Self.read(context: ModelContext(container))
        self.revision = revision; cached = index; searchText = [:]; loadedDecks = []
        contentCosts = [:]; deckRecency = []; searchBytes = 0
        return index
    }

    /// Build the hierarchy beside the read cache, rather than grouping every search hit on MainActor.
    func projection(decks: [DeckItem], query: String, revision: Int, deckIDs: Set<UUID>?) throws
        -> (LibraryResults, LibraryTreeProjection) {
        let index = try load(revision: revision)
        let results = query.isEmpty ? index.results(deckIDs: deckIDs)
            : try search(query, revision: revision, deckIDs: deckIDs)
        try Task.checkCancellation()
        let interval = PerformanceProbe.begin("Library.projection")
        defer { PerformanceProbe.end(interval) }
        return (results, LibraryTreeProjection(decks: decks, index: index, results: results, search: query))
    }

    func rows(projection: LibraryTreeProjection, expanded: Set<UUID>) throws -> [LibraryTreeRow] {
        try Task.checkCancellation()
        let interval = PerformanceProbe.begin("Library.rows")
        defer { PerformanceProbe.end(interval) }
        return projection.rows(expanded: expanded)
    }

    func search(_ query: String, revision: Int, deckIDs: Set<UUID>?) throws -> LibraryResults {
        let interval = PerformanceProbe.begin("Library.search")
        defer { PerformanceProbe.end(interval) }
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
                let cost = text.utf8.count * 2 + 128
                if cost <= maximumSearchBytes {
                    if searchBytes + cost > maximumSearchBytes || searchText.count >= 4096 {
                        searchText = [:]; searchBytes = 0
                    }
                    searchText[card.id] = text; searchBytes += cost
                }
            }
            if text.localizedCaseInsensitiveContains(query) { matches.insert(card.id) }
        }
        return index.results(deckIDs: deckIDs, matching: matches)
    }

    func contents(revision: Int, deckIDs: Set<UUID>?) throws -> LibraryIndex {
        let interval = PerformanceProbe.begin("Library.contents")
        defer { PerformanceProbe.end(interval) }
        var index = try load(revision: revision)
        let requestedDecks = (deckIDs ?? Set(index.cardsByDeck.keys)).intersection(index.cardsByDeck.keys)
        for id in requestedDecks.sorted(by: { $0.uuidString < $1.uuidString }) {
            deckRecency.removeAll { $0 == id }; deckRecency.append(id)
        }
        let missing = requestedDecks.subtracting(loadedDecks)
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
        #if DEBUG
        contentFetches += 1
        #endif
        for note in try ModelContext(container).fetch(fetch) {
            try Task.checkCancellation()
            guard index.siblingCounts[note.id] != nil else { continue }
            let projection = try JSONDecoder().decode(Projection.self, from: note.contentPayload)
            guard (1...2).contains(projection.schemaVersion) else { throw StudyError.unsupportedContent }
            var content = TextContent(question: projection.question, answer: projection.answer, explanation: "")
            content.masks = projection.masks
            index.notes[note.id]?.content = content
            #if DEBUG
            contentDecodes += 1
            #endif
        }
        var updatedCosts = contentCosts
        for deck in missing {
            var cost = 0, seen = Set<UUID>()
            for card in index.cardsByDeck[deck] ?? [] {
                try Task.checkCancellation()
                let displayed = try index.displayed(card)
                guard let note = index.notes[card.noteID] else { throw StudyError.missingRecord }
                index.rowContents[card.id] = LibraryRowContent(question: displayed.question, kindTitle: note.kind.title,
                    siblingCount: index.siblingCounts[card.noteID] ?? 1, isSuspended: card.isSuspended)
                cost += displayed.question.utf8.count * 2 + 128
                if seen.insert(card.noteID).inserted, let content = note.content {
                    cost += (content.question.utf8.count + content.answer.utf8.count) * 2 + 256
                    cost += (content.masks ?? []).reduce(0) { $0 + 256 + $1.answer.utf8.count * 2 }
                }
                #if DEBUG
                rowPreparations += 1
                #endif
            }
            updatedCosts[deck] = cost
        }
        try Task.checkCancellation()
        contentCosts = updatedCosts
        loadedDecks.formUnion(missing)
        // Return the full requested value, but keep only bounded deck content in the actor.
        var retained = index
        while contentCosts.values.reduce(0, +) > maximumContentBytes || loadedDecks.count > maximumCachedDecks {
            guard let oldest = deckRecency.first else { break }
            deckRecency.removeFirst(); loadedDecks.remove(oldest); contentCosts.removeValue(forKey: oldest)
            for card in retained.cardsByDeck[oldest] ?? [] {
                retained.notes[card.noteID]?.content = nil; retained.rowContents.removeValue(forKey: card.id)
            }
        }
        cached = retained
        return index
    }

    static func read(context: ModelContext) throws -> LibraryIndex {
        let paths = LibraryIndex.deckPaths(try context.fetch(FetchDescriptor<Deck>()))
        let tags = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Tag>()).map { ($0.id, $0.name) })
        var noteFetch = FetchDescriptor<Note>()
        noteFetch.propertiesToFetch = [\.id, \.deckID, \.type, \.tagIDs]
        var index = LibraryIndex(), deckIDs: [UUID: UUID] = [:]
        for note in try context.fetch(noteFetch) {
            try Task.checkCancellation()
            guard let kind = NoteKind(rawValue: note.type) else { throw StudyError.missingRecord }
            index.notes[note.id] = LibraryNote(kind: kind, content: nil, deckName: paths[note.deckID] ?? "", tagNames: note.tagIDs.compactMap { tags[$0] }.joined(separator: " "))
            deckIDs[note.id] = note.deckID
        }
        var cardFetch = FetchDescriptor<StudyCard>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        cardFetch.propertiesToFetch = [\.id, \.noteID, \.variantKey, \.isSuspended, \.createdAt]
        for card in try context.fetch(cardFetch) {
            try Task.checkCancellation()
            guard let deck = deckIDs[card.noteID] else { throw StudyError.missingRecord }
            index.cardsByDeck[deck, default: []].append(LibraryCard(id: card.id, noteID: card.noteID, deckID: deck, variantKey: card.variantKey, isSuspended: card.isSuspended, createdAt: card.createdAt))
            index.siblingCounts[card.noteID, default: 0] += 1
            index.cardCount += 1
        }
        return index
    }
}

// This reader owns its ModelContext. Only identifier/count DTOs leave the actor;
// note content, FSRS payloads and review logs are never needed for tag selection.
actor TagFilterReader {
    let container: ModelContainer
    init(container: ModelContainer) { self.container = container }
    func load() throws -> TagFilterIndex {
        let context = ModelContext(container)
        let deckRows = try context.fetch(FetchDescriptor<Deck>())
        let paths = LibraryIndex.deckPaths(deckRows)
        let decks = deckRows.map { DeckItem(id: $0.id, name: paths[$0.id] ?? $0.name, shortName: $0.name, parentID: $0.parentID) }
        let tags = try context.fetch(FetchDescriptor<Tag>()).map { TagItem(id: $0.id, name: $0.name) }
        var cardFetch = FetchDescriptor<StudyCard>()
        cardFetch.propertiesToFetch = [\.noteID]
        var counts: [UUID: Int] = [:]
        for card in try context.fetch(cardFetch) {
            try Task.checkCancellation()
            counts[card.noteID, default: 0] += 1
        }
        var noteFetch = FetchDescriptor<Note>()
        noteFetch.propertiesToFetch = [\.id, \.deckID, \.tagIDs]
        let notes = try context.fetch(noteFetch).map { TagFilterNote(deckID: $0.deckID, tagIDs: Set($0.tagIDs), cards: counts[$0.id] ?? 0) }
        return TagFilterIndex(decks: decks, tags: tags, notes: notes)
    }
}

extension StudyRepository {
    func cardMark(_ id: UUID) throws -> CardMark? {
        try options().cardMarks?.first { $0.cardID == id }
    }
    func setFlags(cardIDs: Set<UUID>, flag: CardFlag?) throws {
        try transaction {
            let existing = Set(try cards().map(\.id))
            guard cardIDs.isSubset(of: existing) else { throw StudyError.missingRecord }
            var saved = try options()
            var marks = saved.cardMarks ?? []
            for id in cardIDs {
                if let index = marks.firstIndex(where: { $0.cardID == id }) { marks[index].flag = flag }
                else if flag != nil { marks.append(CardMark(cardID: id, flag: flag)) }
            }
            saved.cardMarks = marks.filter { existing.contains($0.cardID) && ($0.flag != nil || $0.hiddenUntil != nil) }
            try writeOptionsInTransaction(saved)
        }
    }
    func hideToday(cardID: UUID, now: Date) throws {
        try transaction {
            guard try card(cardID) != nil else { throw StudyError.missingRecord }
            var saved = try options(), marks = saved.cardMarks ?? []
            let end = StudyDay(calendar: calendar, startHour: try settings().dayStartHour).interval(containing: now).end
            if let index = marks.firstIndex(where: { $0.cardID == cardID }) { marks[index].hiddenUntil = end }
            else { marks.append(CardMark(cardID: cardID, hiddenUntil: end)) }
            saved.cardMarks = marks
            try writeOptionsInTransaction(saved)
            if let draft = try session(), draft.cardID == cardID { try selectNext(draft: draft, now: now) }
        }
    }
    func showToday(cardID: UUID) throws {
        try transaction {
            var saved = try options()
            saved.cardMarks = saved.cardMarks?.compactMap { mark in
                var mark = mark
                if mark.cardID == cardID { mark.hiddenUntil = nil }
                return mark.flag == nil && mark.hiddenUntil == nil ? nil : mark
            }
            try writeOptionsInTransaction(saved)
        }
    }
    func pruneCardMarks() throws {
        var saved = try options()
        let ids = Set(try cards().map(\.id))
        saved.cardMarks = saved.cardMarks?.filter { ids.contains($0.cardID) }
        try writeOptionsInTransaction(saved)
    }
}


extension StudyRepository {
    // Metadata is captured inside the same transaction; a thrown save never yields a receipt.
    func importDestinations(noteIDs: Set<UUID>) throws -> [ImportDestination] {
        let ids = Set(try notes().filter { noteIDs.contains($0.id) }.map(\.deckID))
        return try ids.map { ImportDestination(id: $0, name: try deckPath($0)) }
            .sorted { $0.name < $1.name }
    }
}


extension StudyRepository {
    func saveLibrarySearch(_ value: LibrarySearchPreferences) throws {
        try transaction {
            var saved = try options()
            guard saved.librarySearch != value else { return }
            saved.librarySearch = value
            try writeOptionsInTransaction(saved)
        }
    }
}

extension LibraryReader {
    // Revision-scoped snapshots are decoded only for schedule filters. No payload
    // is decoded on each text keystroke; this cache is bounded by the current store.
    func advancedSearch(_ conditions: LibrarySearchConditions, revision: Int, now: Date,
                        calendar: Calendar = .current, dayStartHour: Int) throws -> LibraryResults {
        let context = ModelContext(container)
        var allowed: Set<UUID>?
        if let deck = conditions.deckID {
            let rows = try context.fetch(FetchDescriptor<Deck>())
            var ids: Set<UUID> = rows.contains(where: { $0.id == deck }) ? [deck] : []
            if conditions.descendants {
                var pending = Array(ids)
                while let parent = pending.popLast() {
                    for child in rows where child.parentID == parent && ids.insert(child.id).inserted { pending.append(child.id) }
                }
            }
            allowed = ids
        }
        let base = try search(conditions.text, revision: revision, deckIDs: allowed)
        var matches = base.cardIDs
        if !conditions.tags.isEmpty {
            var fetch = FetchDescriptor<Note>()
            fetch.propertiesToFetch = [\.id, \.tagIDs]
            let selected = Set(conditions.tags)
            let notes = Set(try context.fetch(fetch).filter {
                conditions.anyTag ? !selected.isDisjoint(with: $0.tagIDs) : selected.isSubset(of: Set($0.tagIDs))
            }.map(\.id))
            matches = Set(base.cardsByDeck.values.joined().filter { notes.contains($0.noteID) }.map(\.id))
        }
        if conditions.againToday || conditions.reviewedDays > 0 {
            let start = StudyDay(calendar: calendar, startHour: dayStartHour).interval(containing: now).start
            let recent = calendar.date(byAdding: .day, value: -(max(1, conditions.reviewedDays) - 1), to: start)!
            let earliest = conditions.againToday ? min(start, recent) : recent
            var fetch = FetchDescriptor<StudyReviewLog>(predicate: #Predicate { $0.reviewedAt >= earliest && $0.reviewedAt <= now })
            fetch.propertiesToFetch = [\.cardID, \.reviewedAt, \.grade]
            let logs = try context.fetch(fetch)
            if conditions.againToday {
                matches.formIntersection(logs.filter { $0.reviewedAt >= start && $0.grade == ReviewGrade.again.rawValue }.map(\.cardID))
            }
            if conditions.reviewedDays > 0 { matches.formIntersection(logs.filter { $0.reviewedAt >= recent }.map(\.cardID)) }
        }
        if conditions.requiresSchedule || conditions.dueOnly || conditions.state == .suspended {
            let preferences = try context.fetch(FetchDescriptor<ExtraPreferences>()).first
            let options = try preferences.map { try JSONDecoder().decode(StudyOptions.self, from: $0.payload) }
            let scheduler = try ReviewScheduler(parameters: options?.fsrsOptimization?.activeParameters)
            let states = try scheduleRows(revision: revision)
            matches = Set(matches.filter { id in
                guard let row = states[id] else { return false }
                if conditions.dueOnly && (row.suspended || row.due > now || row.summary == nil || row.summary?.state == "new") { return false }
                if conditions.state == .suspended && !row.suspended { return false }
                if conditions.requiresSchedule {
                    let summary = row.summary
                    let missing = summary == nil || summary?.lastReview == nil
                    if conditions.missingFSRS && !missing { return false }
                    if conditions.state != .all && conditions.state != .suspended && summary?.state != conditions.state.rawValue { return false }
                    if conditions.minimumLapses > 0 && (summary == nil || summary!.lapses < conditions.minimumLapses) { return false }
                    if conditions.minimumDifficulty > 0 && (missing || summary!.difficulty < conditions.minimumDifficulty) { return false }
                    if conditions.maximumRecall < 1 {
                        guard !missing, let snapshot = row.snapshot,
                              let recall = try? scheduler.retrievability(snapshot, now: now), recall <= conditions.maximumRecall else { return false }
                    }
                }
                return true
            })
        }
        if let flag = conditions.flag {
            let options = try context.fetch(FetchDescriptor<ExtraPreferences>()).first
            let marks = try options.map { try JSONDecoder().decode(StudyOptions.self, from: $0.payload).cardMarks ?? [] } ?? []
            matches.formIntersection(marks.filter { $0.flag == flag }.map(\.cardID))
        }
        var result = try load(revision: revision).results(deckIDs: allowed, matching: matches)
        if conditions.oldestFirst { for id in result.cardsByDeck.keys { result.cardsByDeck[id]?.reverse() } }
        return result
    }
    private func scheduleRows(revision: Int) throws -> [UUID: LibrarySearchSchedule] {
        if scheduleRevision == revision { return scheduleCache }
        let scheduler = try ReviewScheduler()
        var fetch = FetchDescriptor<StudyCard>()
        fetch.propertiesToFetch = [\.id, \.fsrsPayload, \.dueDate, \.isSuspended]
        var rows: [UUID: LibrarySearchSchedule] = [:]
        for card in try ModelContext(container).fetch(fetch) {
            try Task.checkCancellation()
            let snapshot = try? JSONDecoder().decode(SchedulerSnapshot.self, from: card.fsrsPayload)
            rows[card.id] = LibrarySearchSchedule(snapshot: snapshot, summary: snapshot.flatMap { try? scheduler.summary($0) }, due: card.dueDate, suspended: card.isSuspended)
        }
        scheduleCache = rows; scheduleRevision = revision
        return rows
    }
}
private struct LibrarySearchSchedule {
    let snapshot: SchedulerSnapshot?
    let summary: ScheduleSummary?
    let due: Date
    let suspended: Bool
}


// Created and used entirely on the detached worker. No managed models cross
// the boundary. The synchronous API uses this same writer for parity.
private struct TextImportWriter {
    let context: ModelContext
    func apply(_ prepared: PreparedTextImport, action: DuplicateAction,
               resetHistory: Bool, source: String, now: Date, desiredRetention: Double) throws -> ImportResult {
        let interval = PerformanceProbe.begin("Import.CSV")
        defer { PerformanceProbe.end(interval) }
        try Task.checkCancellation()
        let deckID = prepared.deckID, kind = prepared.kind, tagNames = prepared.tagNames
        // Recheck the destination after asynchronous preparation, before any mutation.
        guard try context.fetch(FetchDescriptor<Deck>()).contains(where: { $0.id == deckID }) else { throw StudyError.missingRecord }
        let valid = prepared.rows, errors = prepared.errors, excluded = prepared.excluded
        let type = kind.rawValue
        let initialNotes = try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.deckID == deckID && $0.type == type }))
        let initialNoteIDs = Set(initialNotes.map(\.id))
        var createdNoteIDs = Set<UUID>(), updatedNoteIDs = Set<UUID>(), createdCardIDs = Set<UUID>(), maintainedCardIDs = Set<UUID>()
        var duplicates = 0, skipped = excluded
        let scheduler = try ReviewScheduler(desiredRetention: desiredRetention)
        let fresh = try JSONEncoder().encode(scheduler.newCard(now: now))
        return try {
            var imported = 0
            var duplicatesByText: [[String]: Note] = [:]
            for note in initialNotes where !valid.isEmpty && note.deckID == deckID && note.type == kind.rawValue {
                let content = try JSONDecoder().decode(TextContent.self, from: note.contentPayload)
                let key = [ImportParser.normalized(content.question), ImportParser.normalized(content.answer)]
                if duplicatesByText[key] == nil { duplicatesByText[key] = note }
            }
            var importTagIDs: [UUID]?
            func tagsForImport() throws -> [UUID] {
                if let importTagIDs { return importTagIDs }
                let ids = try tagIDs(for: tagNames); importTagIDs = ids; return ids
            }
            for row in valid {
                let input = row.input, content = row.content
                try Task.checkCancellation()
                let key = row.duplicateKey
                if let existing = duplicatesByText[key] {
                    if action == .skip { skipped += 1; duplicates += 1; continue }
                    if action == .update {
                        var merged = try JSONDecoder().decode(TextContent.self, from: existing.contentPayload)
                        merged.question = input.question; merged.answer = input.answer
                        merged.explanation = input.explanation
                        if let hint = input.hint { merged.hint = hint }
                        if let value = input.questionLayout { merged.questionLayout = value }
                        if let value = input.answerLayout { merged.answerLayout = value }
                        existing.contentPayload = try JSONEncoder().encode(merged); existing.updatedAt = now
                        if row.updatesMode { existing.defaultResponseMode = input.responseMode.rawValue }
                        existing.tagIDs = try tagsForImport()
                        let noteID = existing.id
                        let existingCards = try context.fetch(FetchDescriptor<StudyCard>(predicate: #Predicate { $0.noteID == noteID }))
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
                note.tagIDs = try tagsForImport(); context.insert(note); createdNoteIDs.insert(note.id)
                if duplicatesByText[key] == nil { duplicatesByText[key] = note }
                for key in row.variants {
                    let card = StudyCard(noteID: note.id, variantKey: key, payload: fresh, now: now)
                    context.insert(card); createdCardIDs.insert(card.id)
                }
                imported += 1
            }
            context.insert(ImportBatch(source: source, now: now, success: imported, skipped: skipped, errors: errors))
            return ImportResult(affectedCardIDs: createdCardIDs.union(maintainedCardIDs),
                                    destinations: imported > 0 ? [ImportDestination(id: deckID, name: try destinationPath(deckID))] : [],
                                    imported: imported, skipped: skipped, errors: errors, createdNotes: createdNoteIDs.count,
                                updatedNotes: updatedNoteIDs.count, createdCards: createdCardIDs.count, maintainedCards: maintainedCardIDs.count,
                                duplicateRows: duplicates, excludedRows: excluded)
        }()
    }
    private func tagIDs(for names: [String]) throws -> [UUID] {
        var known = try context.fetch(FetchDescriptor<Tag>(sortBy: [SortDescriptor(\.normalizedName)]))
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
    private func destinationPath(_ id: UUID) throws -> String {
        let all = try context.fetch(FetchDescriptor<Deck>())
        var names: [String] = [], current: UUID? = id, seen: Set<UUID> = []
        while let value = current, !seen.contains(value), let deck = all.first(where: { $0.id == value }) {
            names.insert(deck.name, at: 0); seen.insert(value); current = deck.parentID
        }
        return names.joined(separator: " / ")
    }
}

extension StudyRepository {
    // Preserve unsaved edits and serialize other repository mutations while the
    // independent context commits. A single save remains the commit boundary.
    func importPreparedRowsInBackground(_ prepared: PreparedTextImport, action: DuplicateAction,
        resetHistory: Bool = false, source: String, now: Date,
        save: @escaping @Sendable (ModelContext) throws -> Void = { try $0.save() }) async throws -> ImportResult {
        guard !importCommitWorking, !context.hasChanges else { throw ImportCommitError.busy }
        let retention = try settings().desiredRetention
        importCommitWorking = true
        defer { importCommitWorking = false }
        let container = context.container
        let worker = Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            do {
                let result = try TextImportWriter(context: context).apply(prepared, action: action,
                    resetHistory: resetHistory, source: source, now: now, desiredRetention: retention)
                try Task.checkCancellation()
                try save(context)
                return result
            } catch {
                context.rollback()
                throw error
            }
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        // A fresh context avoids stale registered models after updates. Reset
        // projections before the existing Store reload, even if reload fails.
        refreshAfterImportCommit()
        return result
    }
}

enum ImportCommitError: LocalizedError {
    case busy
    var errorDescription: String? { "保存処理中、または未保存の変更があります。保存後に再試行してください。" }
}

extension StudyRepository {
    func saveExamPlan(_ plan: ExamPlan) throws {
        guard plan.valid else { throw StudyError.invalidContent }
        var saved = try options()
        var plans = saved.examPlans ?? []
        plans.removeAll { $0.id == plan.id }
        plans.append(plan)
        saved.examPlans = plans
        try updateOptions(saved)
    }
}
