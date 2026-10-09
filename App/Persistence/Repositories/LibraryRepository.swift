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
    func moveDeck(id: UUID, name: String, parentID: UUID?, now: Date) throws {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw StudyError.invalidContent }
        if let parentID {
            guard try decks().contains(where: { $0.id == parentID }) else { throw StudyError.missingRecord }
            guard try !descendants(of: id).contains(parentID) else { throw LibraryError.cycle }
        }
        try transaction {
            guard let deck = try decks().first(where: { $0.id == id }) else { throw StudyError.missingRecord }
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
                    draft.cardID = nil; draft.typedDraft = ""; draft.answerRevealed = false; draft.activeSince = nil
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
    func scopedQueueCards(_ scope: LearningScope) throws -> [QueueCard] {
        let decks = try scope.deckID.map { try descendants(of: $0) }
        let eligible = Set(try notes().filter { note in
            (decks == nil || decks!.contains(note.deckID)) && Set(scope.tagIDs).isSubset(of: Set(note.tagIDs))
        }.map(\.id))
        return try queueCards().filter { $0.noteID.map { eligible.contains($0) } ?? false }
    }
    func scopedCounts(scope: LearningScope, now: Date) throws -> HomeCounts {
        try ReviewQueueBuilder(calendar: calendar).counts(cards: scopedQueueCards(scope), logs: queueLogs(), settings: settings(), now: now)
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
        var skipped = 0
        for row in rows {
            if !row.included { skipped += 1; continue }
            let input = NoteInput(deckID: deckID, kind: kind, question: row.question, answer: row.answer,
                                  explanation: row.explanation, tagNames: tagNames)
            do { valid.append((row, input, try validate(input))) }
            catch { errors.append("\(row.line)行: \(error.localizedDescription)") }
        }
        let scheduler = try ReviewScheduler(desiredRetention: settings().desiredRetention)
        let fresh = try JSONEncoder().encode(scheduler.newCard(now: now))
        return try transaction {
            var imported = 0
            for (_, input, content) in valid {
                if let existing = try duplicate(of: input) {
                    if action == .skip { skipped += 1; continue }
                    if action == .update {
                        existing.contentPayload = content; existing.updatedAt = now
                        existing.tagIDs = try tagIDs(for: tagNames)
                        if resetHistory {
                            for card in try cards().filter({ $0.noteID == existing.id }) {
                                card.fsrsPayload = fresh; card.dueDate = now; card.updatedAt = now
                            }
                        }
                        imported += 1; continue
                    }
                }
                let note = Note(input: input, content: content, now: now)
                note.tagIDs = try tagIDs(for: tagNames); context.insert(note)
                let value = try JSONDecoder().decode(TextContent.self, from: content)
                for key in try CardGeneration.variants(kind: kind, content: value) {
                    context.insert(StudyCard(noteID: note.id, variantKey: key, payload: fresh, now: now))
                }
                imported += 1
            }
            context.insert(ImportBatch(source: source, now: now, success: imported, skipped: skipped, errors: errors))
            return ImportResult(imported: imported, skipped: skipped, errors: errors)
        }
    }
}
