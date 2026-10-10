import XCTest
import SwiftData
@testable import AnkiIOS

@MainActor
final class LibraryRepositoryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    enum Failure: Error { case save }
    func fixture() throws -> StudyRepository {
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true))
        try repo.initialize(now: now); return repo
    }

    func testHintOnlyEditOfLegacyContentPreservesActiveSession() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        var input = NoteInput(deckID: deck, question: "Legacy Q", answer: "Legacy A")
        let id = try repo.createNote(input, now: now)
        try repo.transaction {
            let note = try XCTUnwrap(repo.notes().first)
            note.contentPayload = Data(#"{"schemaVersion":1,"question":"Legacy Q","answer":"Legacy A","explanation":""}"#.utf8)
        }
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(mode: .typing, text: "keep legacy draft", now: now)
        let card = try XCTUnwrap(repo.cards().first), payload = card.fsrsPayload, due = card.dueDate
        let active = try repo.session()?.activeSince
        input.hint = "new hint"
        try repo.updateNote(id: id, input: input, now: now.addingTimeInterval(10))
        XCTAssertEqual(try repo.session()?.activeSince, active)
        XCTAssertEqual(try repo.session()?.typedDraft, "keep legacy draft")
        XCTAssertEqual(try repo.cards().first?.fsrsPayload, payload)
        XCTAssertEqual(try repo.cards().first?.dueDate, due)
        XCTAssertEqual(try repo.noteItems().first?.content.hint, "new hint")
    }
    func testHintEditsDraftsAndImportsPreserveScheduleAndNewSlots() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        var input = NoteInput(deckID: deck, question: "Q", answer: "A", hint: "first", reverseEnabled: true)
        let note = try repo.createNote(input, now: now)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(revealed: true, now: now)
        try repo.grade(.good, now: now.addingTimeInterval(1))
        try repo.updateDraft(mode: .typing, text: "keep draft", now: now.addingTimeInterval(2))
        let cards = try repo.cards().map { ($0.id, $0.fsrsPayload, $0.dueDate, $0.updatedAt) }
        let logs = try repo.logs().map(\.id), counts = try repo.counts(now: now)
        let session = try XCTUnwrap(repo.session())
        let activeSince = session.activeSince, elapsed = session.elapsedMs, undo = session.undoLogID
        input.hint = "updated\nsecond line"
        try repo.saveEditorDraft(key: "edit:\(note)", input: input, now: now)
        XCTAssertEqual(try repo.editorDraft(key: "edit:\(note)")?.hint, input.hint)
        try repo.updateNote(id: note, input: input, now: now.addingTimeInterval(3))
        XCTAssertEqual(try repo.session()?.typedDraft, "keep draft")
        XCTAssertEqual(try repo.session()?.activeSince, activeSince)
        XCTAssertEqual(try repo.session()?.elapsedMs, elapsed)
        XCTAssertEqual(try repo.session()?.undoLogID, undo)
        XCTAssertEqual(try repo.noteItems().first { $0.variantKey == "basic:front" }?.content.hint, input.hint)
        XCTAssertNil(try repo.noteItems().first { $0.variantKey == "basic:reverse" }?.content.hint)
        for value in [String?.none, "replacement", ""] {
            var row = ImportRow(line: 1, question: "Q", answer: "A"); row.hint = value
            _ = try repo.importRows([row], deckID: deck, kind: .basic, tagNames: [], action: .update, source: "csv", now: now)
            XCTAssertEqual(try repo.noteItems().first?.sourceContent.hint, value ?? input.hint)
            XCTAssertEqual(try repo.noteItems().first?.sourceContent.reverseEnabled, true)
            XCTAssertEqual(try repo.logs().map(\.id), logs)
            XCTAssertEqual(try repo.counts(now: now), counts)
            for (id, payload, due, updated) in cards {
                let actual = try XCTUnwrap(repo.cards().first { $0.id == id })
                XCTAssertEqual(actual.fsrsPayload, payload); XCTAssertEqual(actual.dueDate, due)
                XCTAssertEqual(actual.updatedAt, updated)
            }
        }
        input.hint = nil
        try repo.updateNote(id: note, input: input, now: now)
        XCTAssertNil(try repo.noteItems().first?.sourceContent.hint)
    }
    func testHomeFilterPersistsSeparatelyFromSessionAndGlobalProgress() async throws {
        let container = try PersistenceController.makeStudyContainer(inMemory: true)
        let repo = StudyRepository(container: container)
        try repo.initialize(now: now)
        let root = try repo.decks()[0].id
        let child = try repo.createDeck(name: "子", parentID: root, now: now)
        let other = try repo.createDeck(name: "別", now: now)
        try repo.createNote(NoteInput(deckID: child, question: "Q", answer: "A", tagNames: ["A", "B"]), now: now)
        try repo.createNote(NoteInput(deckID: other, question: "Other", answer: "A"), now: now)
        let tags = try repo.tags().map(\.id)
        let original = LearningScope(deckID: root, tagIDs: tags)
        try repo.applyHomeScope(original)
        try repo.start(mode: .new, scope: original, now: now)
        try repo.updateDraft(revealed: true, now: now); try repo.grade(.again, now: now)
        try repo.updateDraft(mode: .typing, text: "keep", revealed: true, now: now)
        let before = try XCTUnwrap(repo.session())
        let undo = before.undoLogID, touched = before.touchedCardIDs
        try repo.applyHomeScope(LearningScope(deckID: other))
        let reopened = StudyRepository(container: container)
        XCTAssertEqual(try reopened.homeScope().deckID, other)
        XCTAssertEqual(try reopened.scope(), try reopened.normalizedScope(original))
        XCTAssertEqual(try reopened.session()?.typedDraft, "keep")
        XCTAssertEqual(try reopened.session()?.undoLogID, undo)
        XCTAssertEqual(try reopened.session()?.touchedCardIDs, touched)
        XCTAssertEqual(try reopened.scopedCounts(scope: LearningScope(deckID: other), now: now).learnedToday, 1)
        var settings = try reopened.settings(); settings.dailyNewLimit = 1
        try reopened.updateSettings(settings)
        XCTAssertEqual(try reopened.scopedCounts(scope: LearningScope(deckID: other), now: now).newRemaining, 0)
        try reopened.resume(now: now.addingTimeInterval(61))
        XCTAssertEqual(try reopened.presentation(now: now.addingTimeInterval(61))?.card?.deckID, child)
        let backup = try BackupArchive.decode(await BackupService.export(repository: reopened, now: now, appVersion: "28"))
        XCTAssertEqual(try JSONDecoder().decode(StudyOptions.self, from: backup.data.options[0].payload).homeScope?.deckID, other)
    }
    func testHomeFilterSaveFailureAndInvalidReferences() throws {
        let repo = try fixture(), root = try repo.decks()[0].id
        try repo.applyHomeScope(LearningScope(deckID: root))
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.applyHomeScope(LearningScope()))
        XCTAssertEqual(try repo.homeScope().deckID, root)
        repo.save = { try $0.save() }
        try repo.applyHomeScope(LearningScope(deckID: UUID(), tagIDs: [UUID()]))
        XCTAssertEqual(try repo.homeScope(), LearningScope())
        try repo.applyHomeScope(LearningScope(deckID: root))
        try repo.deleteDeck(id: root, moveNotesTo: nil, now: now)
        XCTAssertEqual(try repo.homeScope(), LearningScope())
    }

    func testBulkMetadataExpandsSiblingsPreservesFSRSHistoryAndDraftText() async throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        let destination = try repo.createDeck(name: "移動先", parentID: deck, now: now)
        let note = try repo.createNote(NoteInput(deckID: deck, question: "Bulk Q", answer: "Bulk A", tagNames: ["Old"], reverseEnabled: true), now: now)
        try repo.start(mode: .new, now: now); try repo.updateDraft(revealed: true, now: now); try repo.grade(.easy, now: now)
        let originalCards = try repo.cards().map { ($0.id, $0.fsrsPayload, $0.dueDate) }, logs = try repo.logs().map(\.id)
        let selected = Set([try XCTUnwrap(repo.cards().first?.id)])
        try repo.saveEditorDraft(key: "edit:\(note.uuidString)", input: NoteInput(deckID: deck, question: "未保存の本文", answer: "下書き", tagNames: ["Old", "Draft only"]), now: now)
        let move = try repo.previewBulkEdit(cardIDs: selected, action: .move(destination))
        XCTAssertEqual(move.selectedCount, 1); XCTAssertEqual(move.cards.count, 2); XCTAssertEqual(move.changedNotes.count, 1)
        _ = try repo.applyBulkEdit(move, now: now.addingTimeInterval(1))
        _ = try repo.applyBulkEdit(repo.previewBulkEdit(cardIDs: selected, action: .addTags([" 日本 ", "日本", "old", "NEW", "new"])), now: now.addingTimeInterval(2))
        let old = try XCTUnwrap(repo.tags().first { $0.name == "Old" }?.id)
        _ = try repo.applyBulkEdit(repo.previewBulkEdit(cardIDs: selected, action: .removeTags([old])), now: now.addingTimeInterval(3))
        let actual = try XCTUnwrap(repo.notes().first { $0.id == note })
        XCTAssertEqual(actual.deckID, destination); XCTAssertEqual(actual.tagIDs.count, 2)
        let draft = try XCTUnwrap(repo.editorDraft(key: "edit:\(note.uuidString)"))
        XCTAssertEqual(draft.deckID, destination); XCTAssertEqual(draft.question, "未保存の本文")
        XCTAssertTrue(draft.tagNames.contains("Draft only")); XCTAssertFalse(draft.tagNames.contains("Old"))
        XCTAssertEqual(try repo.logs().map(\.id), logs)
        for (id, payload, due) in originalCards {
            let card = try XCTUnwrap(repo.cards().first { $0.id == id })
            XCTAssertEqual(card.fsrsPayload, payload); XCTAssertEqual(card.dueDate, due)
        }
        let backup = try BackupArchive.decode(await BackupService.export(repository: repo, now: now, appVersion: "bulk"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("Study.store"))
        _ = try BackupService.restore(backup, location: location, mediaStore: MediaStore(root: root.appendingPathComponent("Media")), now: now)
        let reopened = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: location.canonicalStore))
        XCTAssertEqual(try reopened.notes().first?.tagIDs, actual.tagIDs)
        XCTAssertEqual(Set(try reopened.cards().map(\.id)), Set(originalCards.map { $0.0 }))
        XCTAssertEqual(try reopened.logs().map(\.id), logs)
    }
    func testBulkSuspensionChangesOnlySelectedCardAndNoopDoesNotSave() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        try repo.createNote(NoteInput(deckID: deck, question: "Q", answer: "A", reverseEnabled: true), now: now)
        let selected = Set([try XCTUnwrap(repo.cards().first?.id)])
        let preview = try repo.previewBulkEdit(cardIDs: selected, action: .suspended(true))
        XCTAssertEqual(preview.cards.count, 2); XCTAssertEqual(preview.changedCount, 1)
        _ = try repo.applyBulkEdit(preview, now: now)
        XCTAssertEqual(try repo.cards().filter(\.isSuspended).count, 1)
        let noop = try repo.previewBulkEdit(cardIDs: selected, action: .suspended(true))
        repo.save = { _ in throw Failure.save }
        XCTAssertEqual(try repo.applyBulkEdit(noop, now: now).changedCards, 0)
        repo.save = { try $0.save() }
        _ = try repo.applyBulkEdit(repo.previewBulkEdit(cardIDs: selected, action: .suspended(false)), now: now)
        XCTAssertFalse(try repo.cards().contains(where: \.isSuspended))
    }
    func testBulkEmptyMissingStaleContentDraftAndNewSiblingRejectWithoutPartialSuccess() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        let note = try repo.createNote(NoteInput(deckID: deck, question: "Q", answer: "A"), now: now)
        let selected = Set([try XCTUnwrap(repo.cards().first?.id)])
        XCTAssertThrowsError(try repo.previewBulkEdit(cardIDs: [], action: .deleteNotes))
        XCTAssertThrowsError(try repo.previewBulkEdit(cardIDs: selected.union([UUID()]), action: .deleteNotes))
        XCTAssertThrowsError(try repo.previewBulkEdit(cardIDs: selected, action: .move(UUID())))
        XCTAssertThrowsError(try repo.previewBulkEdit(cardIDs: selected, action: .addTags([])))
        XCTAssertThrowsError(try repo.previewBulkEdit(cardIDs: selected, action: .removeTags([UUID()])))
        let stale = try repo.previewBulkEdit(cardIDs: selected, action: .deleteNotes)
        try repo.saveEditorDraft(key: "edit:\(note.uuidString)", input: NoteInput(deckID: deck, question: "下書き"), now: now)
        XCTAssertThrowsError(try repo.applyBulkEdit(stale, now: now))
        let beforeEdit = try repo.previewBulkEdit(cardIDs: selected, action: .deleteNotes)
        try repo.updateNote(id: note, input: NoteInput(deckID: deck, question: "変更後", answer: "A", reverseEnabled: true), resetHistory: false, now: now)
        XCTAssertThrowsError(try repo.applyBulkEdit(beforeEdit, now: now))
        XCTAssertEqual(try repo.cards().count, 2); XCTAssertEqual(try repo.notes().count, 1)
    }
    func testBulkSaveFailureRollsBackMoveTagsSuspendAndDelete() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        let destination = try repo.createDeck(name: "別", now: now)
        let note = try repo.createNote(NoteInput(deckID: deck, question: "Q", answer: "A", tagNames: ["Keep"], reverseEnabled: true), now: now)
        try repo.start(mode: .new, now: now); try repo.updateDraft(revealed: true, now: now); try repo.grade(.good, now: now)
        try repo.saveEditorDraft(key: "edit:\(note.uuidString)", input: NoteInput(deckID: deck, question: "下書き"), now: now)
        let selected = Set(try repo.cards().map(\.id))
        let keptTag = try XCTUnwrap(repo.tags().first?.id)
        for action in [BulkEditAction.move(destination), .addTags(["新タグ"]), .removeTags([keptTag]), .suspended(true), .deleteNotes] {
            let before = try BackupData.capture(repo).canonical()
            let preview = try repo.previewBulkEdit(cardIDs: selected, action: action)
            repo.save = { _ in throw Failure.save }
            XCTAssertThrowsError(try repo.applyBulkEdit(preview, now: now.addingTimeInterval(1)))
            repo.save = { try $0.save() }
            XCTAssertEqual(try BackupData.capture(repo).canonical(), before)
        }
    }
    func testBulkDeleteKeepsHistoryAndClearsOnlyAffectedSessionAndEditorReferences() async throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        let note = try repo.createNote(NoteInput(deckID: deck, question: "Q", answer: "A", reverseEnabled: true), now: now)
        try repo.start(mode: .new, now: now); try repo.updateDraft(revealed: true, now: now); try repo.grade(.again, now: now)
        let log = try XCTUnwrap(repo.logs().first), selected = Set([log.cardID])
        try repo.saveEditorDraft(key: "edit:\(note.uuidString)", input: NoteInput(deckID: deck, question: "下書き"), now: now)
        try repo.saveEditorDraft(key: "new", input: NoteInput(deckID: deck, question: "維持する下書き"), now: now)
        _ = try repo.applyBulkEdit(repo.previewBulkEdit(cardIDs: selected, action: .deleteNotes), now: now)
        XCTAssertTrue(try repo.notes().isEmpty); XCTAssertTrue(try repo.cards().isEmpty)
        XCTAssertEqual(try repo.logs().map(\.id), [log.id])
        XCTAssertNil(try repo.session()?.cardID); XCTAssertNil(try repo.session()?.undoLogID)
        XCTAssertNil(try repo.editorDraft(key: "edit:\(note.uuidString)")); XCTAssertNotNil(try repo.editorDraft(key: "new"))
        _ = try BackupArchive.decode(await BackupService.export(repository: repo, now: now, appVersion: "bulk-delete"))
    }

    func testDeckManagerTreeFollowsRealParentIDsAndUpdatesAfterMoves() throws {
        let repo = try fixture(), myDeck = try repo.decks()[0].id
        let english = try repo.createDeck(name: "英語", now: now)
        let finalDraft = try repo.createDeck(name: "Final Draft", parentID: english, now: now)
        let lesson = try repo.createDeck(name: "Lesson4", parentID: finalDraft, now: now)
        let otherEnglish = try repo.createDeck(name: "英語", now: now)
        let anotherLesson = try repo.createDeck(name: "Lesson4", parentID: otherEnglish, now: now)

        func snapshot() throws -> [DeckItem] {
            try repo.decks().map {
                DeckItem(id: $0.id, name: try repo.deckPath($0.id),
                         shortName: $0.name, parentID: $0.parentID)
            }
        }
        let items = try snapshot()
        XCTAssertEqual(items.first { $0.id == lesson }?.name, "英語 / Final Draft / Lesson4")
        XCTAssertEqual(items.first { $0.id == lesson }?.shortName, "Lesson4")
        let roots = DeckTreeBuilder.roots(from: items)
        XCTAssertEqual(Set(roots.map(\.id)), Set([myDeck, english, otherEnglish]))
        XCTAssertTrue(roots.first { $0.id == myDeck }?.children.isEmpty == true)
        XCTAssertEqual(roots.first { $0.id == english }?.children.first?.id, finalDraft)
        XCTAssertEqual(roots.first { $0.id == english }?.children.first?.children.first?.id, lesson)
        XCTAssertEqual(roots.first { $0.id == otherEnglish }?.children.first?.id, anotherLesson)
        XCTAssertEqual(DeckTreeBuilder.visibleRows(roots: roots, expanded: []).count, 3)
        let expanded = DeckTreeBuilder.visibleRows(roots: roots, expanded: [english, finalDraft])
        XCTAssertEqual(Set(expanded.map(\.id)), Set([myDeck, english, otherEnglish, finalDraft, lesson]))
        XCTAssertEqual(expanded.first { $0.id == lesson }?.depth, 2)
        XCTAssertEqual(expanded.first { $0.id == lesson }?.name, "Lesson4")
        XCTAssertEqual(expanded.first { $0.id == lesson }?.path, "英語 / Final Draft / Lesson4")

        try repo.moveDeck(id: finalDraft, name: "変更後", parentID: otherEnglish, now: now)
        let moved = DeckTreeBuilder.roots(from: try snapshot())
        XCTAssertTrue(moved.first { $0.id == english }?.children.isEmpty == true)
        XCTAssertTrue(moved.first { $0.id == otherEnglish }?.children.contains(where: { $0.id == finalDraft }) == true)
        XCTAssertEqual(moved.first { $0.id == otherEnglish }?.children
            .first(where: { $0.id == finalDraft })?.children.first?.id, lesson)
        XCTAssertEqual(try repo.deckPath(lesson), "英語 / 変更後 / Lesson4")
    }

    func testDeepDeckTreeKeepsEveryLevelAndSameNamedDeckIdentity() {
        var items: [DeckItem] = [], parent: UUID?
        for depth in 0..<12 {
            let id = UUID()
            items.append(DeckItem(id: id, name: "Level \(depth)", shortName: "Same", parentID: parent))
            parent = id
        }
        let roots = DeckTreeBuilder.roots(from: items)
        let rows = DeckTreeBuilder.visibleRows(roots: roots, expanded: Set(items.map(\.id)))
        XCTAssertEqual(rows.map(\.depth), Array(0..<12))
        XCTAssertEqual(rows.map(\.id), items.map(\.id))
        XCTAssertEqual(rows.last?.path.components(separatedBy: " / ").count, 12)
    }

    func testDeckTreeInvalidLegacyParentsStillDisplayOnce() {
        let missing = UUID(), cycleA = UUID(), cycleB = UUID()
        let input = [
            DeckItem(id: missing, name: "orphan", shortName: "orphan", parentID: UUID()),
            DeckItem(id: cycleA, name: "A", shortName: "A", parentID: cycleB),
            DeckItem(id: cycleB, name: "B", shortName: "B", parentID: cycleA)
        ]
        let roots = DeckTreeBuilder.roots(from: input)
        let rows = DeckTreeBuilder.visibleRows(roots: roots, expanded: [cycleA, cycleB, missing])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(Set(rows.map(\.id)), Set([missing, cycleA, cycleB]))
    }

    func testHierarchyScopeAndCyclePreventionPreserveCardIDs() throws {
        let repo = try fixture()
        let root = try repo.decks()[0].id
        let child = try repo.createDeck(name: "子", parentID: root, now: now)
        let other = try repo.createDeck(name: "別", now: now)
        let note = try repo.createNote(NoteInput(deckID: child, question: "Q", answer: "A", tagNames: ["Language", "language", " 東京 "]), now: now)
        let cardID = try XCTUnwrap(repo.cards().first?.id)
        XCTAssertEqual(try repo.tags().count, 2)
        let tagID = try XCTUnwrap(repo.tags().first?.id)
        XCTAssertEqual(try repo.scopedQueueCards(LearningScope(deckID: root, tagIDs: [tagID])).map(\.id), [cardID])
        XCTAssertTrue(try repo.scopedQueueCards(LearningScope(deckID: other)).isEmpty)
        XCTAssertThrowsError(try repo.moveDeck(id: root, name: "root", parentID: child, now: now))
        try repo.moveDeck(id: child, name: "移動", parentID: other, now: now)
        XCTAssertEqual(try repo.cards().first?.id, cardID)
        XCTAssertTrue(try repo.scopedQueueCards(LearningScope(deckID: root)).isEmpty)
        try repo.deleteDeck(id: other, moveNotesTo: root, now: now)
        XCTAssertEqual(try repo.notes().first(where: { $0.id == note })?.deckID, root)
        XCTAssertEqual(try repo.cards().first?.id, cardID)
    }

    func testImportSkipsDuplicatesWithinBatchAndKeepsHistory() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        let rows = [ImportRow(line: 1, question: "Q", answer: "A"),
                    ImportRow(line: 2, question: " Q ", answer: " A "),
                    ImportRow(line: 3, question: "bad", answer: "")]
        let result = try repo.importRows(rows, deckID: deck, kind: .basic, tagNames: ["tag"], action: .skip, source: "csv", now: now)
        XCTAssertEqual(result.imported, 1); XCTAssertEqual(result.skipped, 1); XCTAssertEqual(result.errors.count, 1)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(revealed: true, now: now)
        try repo.grade(.easy, now: now)
        let payload = try repo.cards()[0].fsrsPayload
        let again = try repo.importRows([rows[0]], deckID: deck, kind: .basic, tagNames: [], action: .skip, source: "csv", now: now)
        XCTAssertEqual(again.skipped, 1)
        XCTAssertEqual(try repo.logs().count, 1)
        XCTAssertEqual(try repo.cards()[0].fsrsPayload, payload)
        let update = try repo.importRows([rows[0]], deckID: deck, kind: .basic, tagNames: ["updated"], action: .update, source: "paste", now: now)
        XCTAssertEqual(update.imported, 1)
        XCTAssertEqual(try repo.cards()[0].fsrsPayload, payload)
        XCTAssertEqual(try repo.logs().count, 1)
    }

    func testFailedImportLeavesNoNotesCardsTagsOrBatch() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.importRows([ImportRow(line: 1, question: "Q", answer: "A")], deckID: deck,
                                                kind: .written, tagNames: ["newTag"], action: .add, source: "csv", now: now))
        XCTAssertTrue(try repo.notes().isEmpty)
        XCTAssertTrue(try repo.cards().isEmpty)
        XCTAssertTrue(try repo.tags().isEmpty)
        XCTAssertTrue(try repo.context.fetch(FetchDescriptor<ImportBatch>()).isEmpty)
    }

    func testSiblingBuryDoesNotModifyFSRSAndShortLearningIsExempt() throws {
        let noteID = UUID(), first = UUID(), sibling = UUID(), short = UUID()
        let cards = [QueueCard(id: first, state: "review", due: now, createdAt: now, suspended: false, noteID: noteID),
                     QueueCard(id: sibling, state: "new", due: now, createdAt: now, suspended: false, noteID: noteID),
                     QueueCard(id: short, state: "learning", due: now, createdAt: now, suspended: false, noteID: noteID)]
        let logs = [QueueLog(cardID: first, reviewedAt: now, wasNew: false, noteID: noteID)]
        let builder = ReviewQueueBuilder(shuffled: { $0 })
        let result = builder.queue(cards: cards, logs: logs, settings: StudySettings(), mode: .mixed,
                                   touched: [], reviewStreak: 0, now: now)
        XCTAssertFalse(result.contains(sibling)); XCTAssertTrue(result.contains(short)); XCTAssertTrue(result.contains(first))
        var disabled = StudySettings(); disabled.siblingBuryEnabled = false
        XCTAssertTrue(builder.queue(cards: cards, logs: logs, settings: disabled, mode: .mixed,
                                    touched: [], reviewStreak: 0, now: now).contains(sibling))
        XCTAssertEqual(cards[1].state, "new"); XCTAssertEqual(cards[1].due, now)
    }

    func testMigrationFromPhase1DiskStorePreservesEveryExistingRecord() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Study.store")
        let expected = try writeV1(url)
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: url))
        try repo.initialize(now: now)
        XCTAssertEqual(try repo.cards()[0].id, expected.id)
        XCTAssertEqual(try repo.cards()[0].fsrsPayload, expected.payload)
        XCTAssertEqual(try repo.logs().count, 1)
        XCTAssertEqual(try repo.session()?.typedDraft, "restorable")
        XCTAssertEqual(try repo.noteItems()[0].content.question, "Q")
        try repo.updateOptions(StudyOptions())
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "new", answer: "answer", tagNames: ["tag"]), now: now)
        XCTAssertEqual(try repo.tags().count, 1)
    }
    private func writeV1(_ url: URL) throws -> (id: UUID, payload: Data) {
        let schema = Schema(versionedSchema: StudySchema.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration("Study", schema: schema, url: url, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let deck = Deck(name: "old", now: now)
        let input = NoteInput(deckID: deck.id, question: "Q", answer: "A")
        let note = Note(input: input, content: try JSONEncoder().encode(TextContent(question: "Q", answer: "A", explanation: "")), now: now)
        let scheduler = try ReviewScheduler(), snapshot = try scheduler.newCard(now: now)
        let before = try JSONEncoder().encode(snapshot)
        let card = StudyCard(noteID: note.id, variantKey: "basic:front", payload: before, now: now)
        let transition = try scheduler.review(snapshot, grade: .good, now: now)
        let after = try JSONEncoder().encode(transition.after)
        let log = StudyReviewLog(card: card, transition: transition, before: before, after: after, mode: .mental, durationMs: 1000, wasNew: true, sequence: 1)
        card.fsrsPayload = after; card.dueDate = try scheduler.summary(transition.after).dueDate
        let draft = SessionDraft(mode: .new, now: now); draft.typedDraft = "restorable"
        context.insert(deck); context.insert(note); context.insert(card); context.insert(log)
        context.insert(draft); context.insert(StudyPreferences()); try context.save()
        return (card.id, after)
    }
}
