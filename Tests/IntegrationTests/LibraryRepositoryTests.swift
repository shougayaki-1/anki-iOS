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

    func testLibraryInlineTreeCountsGroupingSearchAndSavedExpansion() throws {
        let root = UUID(), child = UUID(), grandchild = UUID(), empty = UUID(), other = UUID()
        let note = UUID(), directNote = UUID()
        let decks = [
            DeckItem(id: root, name: "英語", shortName: "英語"),
            DeckItem(id: child, name: "英語 / Final Draft", shortName: "Final Draft", parentID: root),
            DeckItem(id: grandchild, name: "英語 / Final Draft / Lesson4", shortName: "Lesson4", parentID: child),
            DeckItem(id: empty, name: "空", shortName: "空"),
            DeckItem(id: other, name: "国語", shortName: "国語")
        ]
        func card(_ note: UUID, deck: UUID) -> LibraryCard {
            LibraryCard(id: UUID(), noteID: note, deckID: deck, variantKey: "basic:front", isSuspended: false, createdAt: now)
        }
        let direct = card(directNote, deck: root)
        let generated = (0..<3).map { _ in card(note, deck: grandchild) }
        var index = LibraryIndex()
        index.cardsByDeck = [root: [direct], grandchild: generated]
        index.siblingCounts = [directNote: 1, note: 3]; index.cardCount = 4
        let tree = LibraryTreeProjection(decks: decks, index: index, results: index.results(), search: "")
        XCTAssertEqual(Set(tree.rows(expanded: []).compactMap { $0.deck?.id }), [root, empty, other])
        XCTAssertEqual(tree.subtreeCards[root], 4)
        XCTAssertFalse(try XCTUnwrap(tree.rows(expanded: []).first { $0.deck?.id == empty }).expandable)
        let expanded: Set<UUID> = [root, child, grandchild]
        let saved = LibraryTreeProjection.saveExpanded(expanded)
        XCTAssertEqual(LibraryTreeProjection.expandedIDs(saved), expanded)
        let open = tree.rows(expanded: expanded)
        XCTAssertEqual(open.compactMap { $0.note?.id }, [directNote, note])
        XCTAssertEqual(open.first { $0.note?.id == note }?.cardCount, 3)
        XCTAssertEqual(open.first { $0.deck?.id == grandchild }?.depth, 2)
        XCTAssertFalse(tree.rows(expanded: [child, grandchild]).contains { $0.note != nil })
        XCTAssertEqual(tree.rows(expanded: LibraryTreeProjection.expandedIDs(saved)).compactMap { $0.note?.id }, [directNote, note])
        let matches = index.results(matching: [generated[0].id])
        let search = LibraryTreeProjection(decks: decks, index: index, results: matches, search: "Question")
        XCTAssertEqual(search.rows(expanded: []).compactMap { $0.deck?.id }, [root, child, grandchild])
        XCTAssertEqual(search.rows(expanded: []).compactMap { $0.note?.id }, [note])
        XCTAssertEqual(LibraryTreeProjection.expandedIDs(saved), expanded)
        let nameSearch = LibraryTreeProjection(decks: decks, index: index, results: LibraryResults(), search: "Lesson4")
        XCTAssertEqual(nameSearch.rows(expanded: []).compactMap { $0.deck?.id }, [root, child, grandchild])
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

    func testDeckSelectionSearchAndSelectedAncestorsAcrossLargeHierarchy() {
        let root = UUID(), sibling = UUID()
        var items = [DeckItem(id: root, name: "国語", shortName: "国語"),
                     DeckItem(id: sibling, name: "英語", shortName: "英語")]
        var parent = root
        for index in 0..<120 {
            let id = UUID()
            items.append(DeckItem(id: id, name: "unused", shortName: "階層\(index)", parentID: parent))
            parent = id
        }
        let duplicate = UUID()
        items.append(DeckItem(id: duplicate, name: "unused", shortName: "階層119", parentID: sibling))
        let ancestors = DeckTreeBuilder.selectionAncestors(of: parent, in: items)
        XCTAssertEqual(ancestors.count, 120)
        XCTAssertEqual(DeckTreeBuilder.selectionRows(from: items, expanded: ancestors, search: "").count, 122)
        let found = DeckTreeBuilder.selectionRows(from: items, expanded: [], search: " 階層119 ")
        XCTAssertEqual(Set(found.map(\.id)), [parent, duplicate])
        XCTAssertTrue(found.contains { $0.path.hasPrefix("国語 / ") && $0.depth == 120 })
        XCTAssertTrue(found.contains { $0.path == "英語 / 階層119" })
        XCTAssertTrue(DeckTreeBuilder.selectionRows(from: items, expanded: [], search: "存在しない").isEmpty)
        XCTAssertTrue(DeckTreeBuilder.selectionAncestors(of: UUID(), in: items).isEmpty)
        XCTAssertTrue(DeckTreeBuilder.selectionAncestors(of: nil, in: items).isEmpty)
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

    func testDeckContentsDirectAndDescendantMoveKeepsTreeCardsAndDraft() throws {
        let repo = try fixture(), root = try repo.decks()[0].id
        let child = try repo.createDeck(name: "子", parentID: root, now: now)
        let grandchild = try repo.createDeck(name: "孫", parentID: child, now: now)
        let destination = try repo.createDeck(name: "移動先", now: now)
        let first = try repo.createNote(NoteInput(deckID: root, question: "両面", answer: "答え", reverseEnabled: true), now: now)
        _ = try repo.createNote(NoteInput(deckID: root, question: "単面", answer: "答え"), now: now)
        _ = try repo.createNote(NoteInput(deckID: child, question: "子の問題", answer: "答え"), now: now)
        _ = try repo.createNote(NoteInput(deckID: grandchild, question: "孫の問題", answer: "答え"), now: now)
        try repo.saveEditorDraft(key: "edit:\(first.uuidString)",
                                 input: NoteInput(deckID: root, question: "下書きは残す", answer: "答え"), now: now)
        try repo.start(mode: .new, scope: LearningScope(deckID: root), now: now)
        try repo.updateDraft(revealed: true, now: now)
        try repo.grade(.good, now: now.addingTimeInterval(1))
        let beforeLogs = try repo.logs().map(\.id)
        let before = try repo.cards().map { ($0.id, $0.fsrsPayload, $0.dueDate, $0.isSuspended) }
        let originalDecks = try repo.decks().map { ($0.id, $0.parentID) }
        let direct = try repo.previewDeckContents(deckID: root, scope: .direct, action: .move(to: destination))
        XCTAssertEqual(direct.noteCount, 2)
        XCTAssertEqual(direct.cardCount, 3)
        XCTAssertEqual(direct.changedCardCount, 3)
        XCTAssertTrue(direct.includedChildPaths.isEmpty)
        let all = try repo.previewDeckContents(deckID: root, scope: .includingDescendants, action: .move(to: destination))
        XCTAssertEqual(all.noteCount, 4)
        XCTAssertEqual(all.cardCount, 5)
        XCTAssertEqual(all.includedChildPaths.count, 2)
        XCTAssertThrowsError(try repo.previewDeckContents(deckID: root, scope: .includingDescendants, action: .move(to: child)))
        XCTAssertThrowsError(try repo.previewDeckContents(deckID: root, scope: .direct, action: .move(to: root)))

        let result = try repo.applyDeckContents(direct, now: now.addingTimeInterval(1))
        XCTAssertEqual(result.changedNotes, 2)
        XCTAssertEqual(result.changedCards, 3)
        XCTAssertFalse(try repo.notes().contains { $0.deckID == root })
        XCTAssertEqual(try repo.notes().filter { $0.deckID == destination }.count, 2)
        XCTAssertEqual(try repo.notes().filter { $0.deckID == child || $0.deckID == grandchild }.count, 2)
        XCTAssertEqual(try repo.editorDraft(key: "edit:\(first.uuidString)")?.deckID, destination)
        XCTAssertEqual(try repo.editorDraft(key: "edit:\(first.uuidString)")?.question, "下書きは残す")
        XCTAssertEqual(try repo.logs().map(\.id), beforeLogs)
        for (id, payload, due, suspended) in before {
            let actual = try XCTUnwrap(repo.cards().first { $0.id == id })
            XCTAssertEqual(actual.fsrsPayload, payload)
            XCTAssertEqual(actual.dueDate, due)
            XCTAssertEqual(actual.isSuspended, suspended)
        }
        for (id, parentID) in originalDecks {
            let actual = try XCTUnwrap(repo.decks().first { $0.id == id })
            XCTAssertEqual(actual.parentID, parentID)
        }
        let remaining = try repo.previewDeckContents(deckID: root, scope: .includingDescendants, action: .delete)
        XCTAssertEqual(remaining.noteCount, 2)
        XCTAssertEqual(remaining.cardCount, 2)
        _ = try repo.applyDeckContents(remaining, now: now.addingTimeInterval(2))
        XCTAssertEqual(try repo.decks().count, 4)
        XCTAssertEqual(try repo.notes().count, 2)
        XCTAssertEqual(try repo.cards().count, 3)
    }

    func testThousandNoteDeckContentsPreviewMoveAndDeletePreservesDecksAndCardState() throws {
        let repo = try fixture(), root = try repo.decks()[0].id
        let child = try repo.createDeck(name: "子", parentID: root, now: now)
        let destination = try repo.createDeck(name: "移動先", now: now)
        let payload = try JSONEncoder().encode(ReviewScheduler().newCard(now: now))
        var originalCards: Set<UUID> = []
        for index in 0..<1000 {
            let input = NoteInput(deckID: index.isMultiple(of: 2) ? root : child,
                                  question: "Question \(index)", answer: "Answer")
            let content = try JSONEncoder().encode(TextContent(question: input.question, answer: input.answer, explanation: ""))
            let note = Note(input: input, content: content, now: now)
            let card = StudyCard(noteID: note.id, variantKey: "basic:front", payload: payload, now: now)
            repo.context.insert(note); repo.context.insert(card)
            originalCards.insert(card.id)
        }
        try repo.context.save()
        let started = Date()
        let direct = try repo.previewDeckContents(deckID: root, scope: .direct, action: .move(to: destination))
        XCTAssertEqual(direct.noteCount, 500)
        let all = try repo.previewDeckContents(deckID: root, scope: .includingDescendants, action: .move(to: destination))
        XCTAssertEqual(all.noteCount, 1000)
        XCTAssertEqual(all.cardCount, 1000)
        let result = try repo.applyDeckContents(all, now: now)
        XCTAssertEqual(result.changedNotes, 1000)
        XCTAssertEqual(Set(try repo.cards().map(\.id)), originalCards)
        XCTAssertTrue(try repo.cards().allSatisfy { $0.fsrsPayload == payload })
        XCTAssertTrue(try repo.notes().allSatisfy { $0.deckID == destination })
        let deletion = try repo.previewDeckContents(deckID: destination, scope: .direct, action: .delete)
        _ = try repo.applyDeckContents(deletion, now: now)
        XCTAssertTrue(try repo.notes().isEmpty)
        XCTAssertTrue(try repo.cards().isEmpty)
        XCTAssertEqual(Set(try repo.decks().map(\.id)), [root, child, destination])
        XCTAssertEqual(try repo.decks().first { $0.id == child }?.parentID, root)
        print("1000-note deck contents preview/move/delete: \(Date().timeIntervalSince(started))s")
    }

    func testDeckContentsStalePreviewRejectsMembershipAndParentChanges() throws {
        let repo = try fixture(), root = try repo.decks()[0].id
        let child = try repo.createDeck(name: "子", parentID: root, now: now)
        let other = try repo.createDeck(name: "別", now: now)
        _ = try repo.createNote(NoteInput(deckID: root, question: "Q", answer: "A"), now: now)
        let preview = try repo.previewDeckContents(deckID: root, scope: .includingDescendants, action: .move(to: other))
        _ = try repo.createNote(NoteInput(deckID: child, question: "新しいノート", answer: "A"), now: now)
        XCTAssertThrowsError(try repo.applyDeckContents(preview, now: now))
        XCTAssertEqual(try repo.notes().filter { $0.deckID == other }.count, 0)
        let fresh = try repo.previewDeckContents(deckID: root, scope: .includingDescendants, action: .move(to: other))
        try repo.moveDeck(id: child, name: "別の親に移動", parentID: nil, now: now.addingTimeInterval(1))
        XCTAssertThrowsError(try repo.applyDeckContents(fresh, now: now))
        XCTAssertEqual(try repo.notes().filter { $0.deckID == other }.count, 0)
        XCTAssertFalse(try repo.previewDeckContents(deckID: root, scope: .direct, action: .delete).noteIDs.isEmpty)
    }

    func testDeckContentsDeleteRollsBackAndPreservesHistoryAndOtherDecks() throws {
        let repo = try fixture(), root = try repo.decks()[0].id
        let other = try repo.createDeck(name: "別", now: now)
        let doomed = try repo.createNote(NoteInput(deckID: root, question: "削除", answer: "A"), now: now)
        let safe = try repo.createNote(NoteInput(deckID: other, question: "残す", answer: "A"), now: now)
        try repo.saveEditorDraft(key: "edit:\(doomed.uuidString)",
                                 input: NoteInput(deckID: root, question: "保存前", answer: "A"), now: now)
        try repo.start(mode: .new, scope: LearningScope(deckID: root), now: now)
        try repo.updateDraft(revealed: true, now: now)
        try repo.grade(.good, now: now.addingTimeInterval(1))
        let oldLogs = try repo.logs().map(\.id)
        let originalDecks = Set(try repo.decks().map(\.id))
        let preview = try repo.previewDeckContents(deckID: root, scope: .direct, action: .delete)
        XCTAssertEqual(preview.noteCount, 1)
        XCTAssertEqual(preview.cardCount, 1)
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.applyDeckContents(preview, now: now.addingTimeInterval(2)))
        XCTAssertTrue(try repo.notes().contains { $0.id == doomed })
        XCTAssertEqual(try repo.cards().count, 2)
        XCTAssertNotNil(try repo.editorDraft(key: "edit:\(doomed.uuidString)"))
        repo.save = { try $0.save() }

        // A fresh preview is required after a rollback.
        let retry = try repo.previewDeckContents(deckID: root, scope: .direct, action: .delete)
        _ = try repo.applyDeckContents(retry, now: now.addingTimeInterval(3))
        XCTAssertEqual(Set(try repo.decks().map(\.id)), originalDecks)
        XCTAssertEqual(try repo.notes().map(\.id), [safe])
        XCTAssertEqual(try repo.cards().count, 1)
        XCTAssertNil(try repo.editorDraft(key: "edit:\(doomed.uuidString)"))
        XCTAssertEqual(try repo.logs().map(\.id), oldLogs)
        XCTAssertNil(try repo.session()?.undoLogID)
        let empty = try repo.previewDeckContents(deckID: root, scope: .direct, action: .delete)
        XCTAssertEqual(empty.cardCount, 0)
        XCTAssertFalse(empty.canCommit)
        XCTAssertThrowsError(try repo.applyDeckContents(empty, now: now))
        _ = try repo.createNote(NoteInput(deckID: root, question: "再登録", answer: "A"), now: now)
        XCTAssertEqual(try repo.notes().count, 2)
    }

}

extension LibraryRepositoryTests {
    func testLibraryContentBudgetsKeepSearchResultsAndRefetchEvictedDeckOnly() async throws {
        let container = try PersistenceController.makeStudyContainer(inMemory: true)
        let repo = StudyRepository(container: container)
        try repo.initialize(now: now)
        let root = try repo.decks()[0].id
        let child = try repo.createDeck(name: "Child", now: now)
        let other = try repo.createDeck(name: "Other", now: now)
        for deck in [root, child, other] {
            _ = try repo.createNote(NoteInput(deckID: deck, question: "Question \(deck)", answer: "Answer", reverseEnabled: true), now: now)
        }
        let before = try BackupData.capture(repo)
        let reader = LibraryReader(container: container, maximumContentBytes: 3000, maximumCachedDecks: 2, maximumSearchBytes: 400)
        _ = try await reader.contents(revision: 1, deckIDs: [root])
        let firstCount = await reader.contentDecodes
        _ = try await reader.contents(revision: 1, deckIDs: [root])
        let repeated = await reader.contentDecodes
        XCTAssertEqual(firstCount, repeated)
        _ = try await reader.contents(revision: 1, deckIDs: [child])
        _ = try await reader.contents(revision: 1, deckIDs: [other])
        let retained = try await reader.load(revision: 1)
        XCTAssertEqual(retained.notes.values.filter { $0.content != nil }.count, 2)
        XCTAssertEqual(retained.rowContents.count, 4)
        let fetched = await reader.contentDecodes
        _ = try await reader.contents(revision: 1, deckIDs: [root])
        let refetched = await reader.contentDecodes
        XCTAssertEqual(refetched, fetched + 1)
        let found = try await reader.search("Answer", revision: 1, deckIDs: nil)
        XCTAssertEqual(found.cardCount, 6)
        let contentCost = await reader.retainedContentBytes, searchCost = await reader.retainedSearchBytes
        XCTAssertLessThanOrEqual(contentCost, 3000); XCTAssertLessThanOrEqual(searchCost, 400)
        let tiny = LibraryReader(container: container, maximumContentBytes: 1, maximumSearchBytes: 0)
        let uncached = try await tiny.contents(revision: 1, deckIDs: [root])
        XCTAssertEqual(uncached.rowContents.count, 2, "Oversized content must still be returned to the visible caller")
        let empty = try await tiny.load(revision: 1)
        XCTAssertTrue(empty.rowContents.isEmpty)
        let complete = try await tiny.search("Answer", revision: 1, deckIDs: nil)
        XCTAssertEqual(complete.cardCount, 6)
        await reader.clearContents()
        let cleared = try await reader.load(revision: 1)
        XCTAssertEqual(cleared.cardCount, 6)
        XCTAssertTrue(cleared.rowContents.isEmpty); XCTAssertTrue(cleared.notes.values.allSatisfy { $0.content == nil })
        let loaded = try await reader.contents(revision: 1, deckIDs: [root])
        for card in loaded.cardsByDeck[root] ?? [] {
            XCTAssertEqual(loaded.rowContents[card.id]?.question, try loaded.displayed(card).question)
        }
        XCTAssertEqual(try BackupData.capture(repo), before)
    }
    func testImportCountsTenNotesCardsAndDistinctRepeatedUpdates() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        let rows = (1...10).map { ImportRow(line: $0, question: "Q\($0)", answer: "A\($0)") }
        let created = try repo.importRows(rows, deckID: deck, kind: .basic, tagNames: [], action: .skip, source: "test", now: now)
        XCTAssertEqual(created.imported, 10); XCTAssertEqual(created.createdNotes, 10); XCTAssertEqual(created.createdCards, 10)
        XCTAssertEqual(created.updatedNotes, 0); XCTAssertEqual(created.maintainedCards, 0)
        try repo.createNote(NoteInput(deckID: deck, question: "Reverse", answer: "Answer", reverseEnabled: true), now: now)
        let before = Dictionary(uniqueKeysWithValues: try repo.cards().map { ($0.id, $0.fsrsPayload) })
        let repeated = [ImportRow(line: 1, question: "Reverse", answer: "Answer"), ImportRow(line: 2, question: "Reverse", answer: "Answer")]
        let updated = try repo.importRows(repeated, deckID: deck, kind: .basic, tagNames: [], action: .update, source: "test", now: now)
        XCTAssertEqual(updated.imported, 2); XCTAssertEqual(updated.updatedNotes, 1); XCTAssertEqual(updated.maintainedCards, 2)
        XCTAssertEqual(updated.createdNotes, 0); XCTAssertEqual(updated.createdCards, 0)
        XCTAssertEqual(updated.affectedCardIDs.count, 2)
        XCTAssertEqual(updated.destinations.map(\.id), [deck])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try repo.cards().map { ($0.id, $0.fsrsPayload) }), before)
    }
    func testImportCountsClozeGeneratedCardsAndMixedSkipExclusionError() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        let row = ImportRow(line: 1, question: "{{c1::one}} {{c2::two}} {{c1::again}}", answer: "")
        let created = try repo.importRows([row, row], deckID: deck, kind: .cloze, tagNames: [], action: .update, source: "test", now: now)
        XCTAssertEqual(created.imported, 2); XCTAssertEqual(created.createdNotes, 1); XCTAssertEqual(created.createdCards, 2)
        XCTAssertEqual(created.outcome, .complete)
        XCTAssertEqual(created.affectedCardIDs, Set(try repo.cards().map(\.id)))
        XCTAssertEqual(created.destinations.map(\.id), [deck])
        XCTAssertEqual(created.destinations.first?.name, try repo.deckPath(deck))
        XCTAssertEqual(created.updatedNotes, 0); XCTAssertEqual(created.maintainedCards, 0)
        var excluded = ImportRow(line: 3, question: "exclude", answer: "A"); excluded.included = false
        let existing = ImportRow(line: 2, question: row.question, answer: "")
        let invalid = ImportRow(line: 4, question: "not cloze", answer: "")
        let result = try repo.importRows([existing, excluded, invalid], deckID: deck, kind: .cloze, tagNames: [], action: .skip, source: "test", now: now)
        XCTAssertEqual(result.imported, 0); XCTAssertEqual(result.skipped, 2)
        XCTAssertEqual(result.duplicateRows, 1); XCTAssertEqual(result.excludedRows, 1); XCTAssertEqual(result.errors.count, 1)
        XCTAssertEqual(result.createdCards + result.maintainedCards, 0)
        XCTAssertEqual(result.outcome, .empty)
        XCTAssertTrue(result.affectedCardIDs.isEmpty); XCTAssertTrue(result.destinations.isEmpty)
        XCTAssertEqual(try repo.notes().count, 1); XCTAssertEqual(try repo.cards().count, 2)
    }

    func acceptedReport(_ repo: StudyRepository) throws -> OptimizationReport {
        if try repo.logs().isEmpty {
            let scheduler = try ReviewScheduler(), deck = try repo.decks()[0].id
            var training: [StudyCard] = []
            for index in 0..<30 {
                let note = try repo.createNote(NoteInput(deckID: deck, question: "Training \(index)", answer: "A"), now: now.addingTimeInterval(-86400 * 40))
                training.append(try XCTUnwrap(repo.cards().first { $0.noteID == note }))
            }
            try repo.transaction {
                for day in 0..<40 {
                    for (index, card) in training.enumerated() {
                        let date = now.addingTimeInterval(Double(day - 40) * 86400)
                        let before = try repo.snapshot(card)
                        let grade: ReviewGrade = day > 0 && (day + index) % 5 == 0 ? .again : .good
                        let transition = try scheduler.review(before, grade: grade, now: date)
                        let after = try JSONEncoder().encode(transition.after)
                        repo.context.insert(StudyReviewLog(card: card, transition: transition, before: card.fsrsPayload, after: after,
                                                         mode: .mental, durationMs: 1000, wasNew: day == 0, sequence: day * 30 + index + 1))
                        card.fsrsPayload = after; card.dueDate = try scheduler.summary(transition.after).dueDate
                    }
                }
            }
        }
        let reviews = try repo.optimizationReviews(), prepared = try FSRSOptimization.prepare(reviews)
        var parameters = FSRSOptimization.defaults; parameters[2] *= 1.2
        return OptimizationReport(generatedAt: now, digest: try FSRSOptimization.digest(repo.optimizationReviews()),
                                  reviews: reviews.count, days: prepared.days, splitDate: prepared.split, parameters: parameters,
                                  previousParameters: try repo.optimizationState().activeParameters,
                                  standard: OptimizationMetrics(count: 210, logLoss: 0.5, rmse: 0.4),
                                  candidate: OptimizationMetrics(count: 210, logLoss: 0.4, rmse: 0.3),
                                  previous: try repo.optimizationState().activeParameters == nil ? nil : OptimizationMetrics(count: 210, logLoss: 0.5, rmse: 0.4), duration: 1)
    }
    func testOptimizationApplyResetBackupAndUndoKeepAllExistingState() async throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        try repo.createNote(NoteInput(deckID: deck, question: "Optimize", answer: "Answer"), now: now)
        let report = try acceptedReport(repo)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(text: "draft", revealed: true, now: now)
        let reviewedCardID = try XCTUnwrap(repo.session()?.cardID)
        let before = try BackupData.capture(repo)
        try repo.saveOptimizationReport(report); try repo.applyOptimization(now: now)
        let applied = try BackupData.capture(repo)
        XCTAssertEqual(before.cards, applied.cards); XCTAssertEqual(before.logs, applied.logs)
        XCTAssertEqual(before.sessions, applied.sessions); XCTAssertEqual(before.notes, applied.notes)
        XCTAssertEqual(try repo.optimizationState().activeParameters, report.parameters)
        let archive = try BackupArchive.decode(await BackupService.export(repository: repo, now: now, appVersion: "test"))
        let options = try JSONDecoder().decode(StudyOptions.self, from: XCTUnwrap(archive.data.options.first).payload)
        XCTAssertEqual(options.fsrsOptimization, try repo.optimizationState())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("Study.store"))
        let media = MediaStore(root: root.appendingPathComponent("Media"))
        let original = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: location.canonicalStore), mediaStore: media)
        try original.initialize(now: now)
        _ = try BackupService.restore(archive, location: location, mediaStore: media, now: now)
        let reopened = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: location.canonicalStore), mediaStore: media)
        XCTAssertEqual(try reopened.optimizationState(), try repo.optimizationState())
        XCTAssertEqual(try BackupData.capture(reopened).canonical().cards, applied.canonical().cards)
        try reopened.grade(.good, now: now); try reopened.undo(now: now)
        XCTAssertEqual(try BackupData.capture(reopened).canonical().cards.map(\.fsrsPayload), applied.canonical().cards.map(\.fsrsPayload))
        try repo.grade(.good, now: now)
        let card = try XCTUnwrap(repo.cards().first { $0.id == reviewedCardID })
        let summary = try ReviewScheduler().summary(repo.snapshot(card))
        XCTAssertEqual(summary.stability, report.parameters[2], accuracy: 0.000001)
        let log = try XCTUnwrap(repo.logs().last)
        let object = try JSONSerialization.jsonObject(with: log.libraryLog) as! [String: Any]
        let recorded = try XCTUnwrap(object["parameterProfile"] as? [Double])
        for (actual, expected) in zip(recorded, report.parameters) { XCTAssertEqual(actual, expected, accuracy: 1e-12) }
        try repo.undo(now: now)
        XCTAssertEqual(try repo.cards().first { $0.id == reviewedCardID }?.fsrsPayload, before.cards.first { $0.id == reviewedCardID }?.fsrsPayload)
        let state = try BackupData.capture(repo)
        try repo.resetOptimization(now: now)
        let reset = try BackupData.capture(repo)
        XCTAssertEqual(state.cards, reset.cards); XCTAssertEqual(state.logs, reset.logs); XCTAssertEqual(state.sessions, reset.sessions)
        XCTAssertNil(try repo.optimizationState().activeParameters)
        XCTAssertEqual(try repo.optimizationState().changes.count, 2)
        // Old option payloads omit this feature and retain the standard scheduler.
        XCTAssertNil(try JSONDecoder().decode(StudyOptions.self, from: Data(#"{"schemaVersion":2,"siblingBuryEnabled":true}"#.utf8)).fsrsOptimization)
    }
    func testOptimizationRejectsStaleOrWorseAndRollsBackSaveFailure() throws {
        let container = try PersistenceController.makeStudyContainer(inMemory: true)
        var fail = false
        let repo = StudyRepository(container: container, save: { context in
            if fail { throw Failure.save }; try context.save()
        })
        try repo.initialize(now: now)
        let report = try acceptedReport(repo)
        try repo.saveOptimizationReport(report)
        fail = true
        XCTAssertThrowsError(try repo.applyOptimization(now: now))
        XCTAssertNil(try repo.optimizationState().activeParameters)
        XCTAssertTrue(try repo.optimizationState().changes.isEmpty)
        fail = false
        try repo.applyOptimization(now: now)
        fail = true
        XCTAssertThrowsError(try repo.resetOptimization(now: now))
        XCTAssertEqual(try repo.optimizationState().activeParameters, report.parameters)
        fail = false; try repo.resetOptimization(now: now)
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "New", answer: "A"), now: now)
        try repo.start(mode: .new, now: now); try repo.updateDraft(revealed: true, now: now); try repo.grade(.good, now: now)
        XCTAssertThrowsError(try repo.applyOptimization(now: now))
        var bad = FSRSOptimization.defaults; bad[0] = .infinity
        XCTAssertFalse(FSRSOptimization.validParameters(bad))
        let prepared = try FSRSOptimization.prepare(repo.optimizationReviews())
        let worse = OptimizationReport(generatedAt: now, digest: try FSRSOptimization.digest(repo.optimizationReviews()), reviews: try repo.logs().count, days: prepared.days,
                                       splitDate: prepared.split, parameters: report.parameters, previousParameters: nil,
                                       standard: report.standard, candidate: OptimizationMetrics(count: 210, logLoss: 0.6, rmse: 0.5), previous: nil, duration: 1)
        try repo.saveOptimizationReport(worse)
        XCTAssertThrowsError(try repo.applyOptimization(now: now))
        XCTAssertNil(try repo.optimizationState().activeParameters)
    }
}

extension LibraryRepositoryTests {
    func testLibraryIndexScopesSearchVariantsAndRefreshesCommittedChanges() async throws {
        let container = try PersistenceController.makeStudyContainer(inMemory: true)
        let repo = StudyRepository(container: container)
        try repo.initialize(now: now)
        let root = try repo.decks()[0].id
        let child = try repo.createDeck(name: "日本語", parentID: root, now: now)
        let other = try repo.createDeck(name: "別", now: now)
        let note = try repo.createNote(NoteInput(deckID: child, question: "東京", answer: "首都", tagNames: ["地理"], reverseEnabled: true), now: now)
        let cloze = try repo.createNote(NoteInput(deckID: root, kind: .cloze, question: "{{c1::赤}} と {{c2::青}}"), now: now)
        let hidden = try repo.createNote(NoteInput(deckID: other, question: "hidden", answer: "A"), now: now)
        let original = try repo.noteItems()
        let reader = LibraryReader(container: container)
        let metadata = try await reader.load(revision: 1)
        XCTAssertEqual(metadata.noteCount, 3); XCTAssertEqual(metadata.cardCount, 5)
        XCTAssertEqual(metadata.siblingCounts[note], 2); XCTAssertEqual(metadata.siblingCounts[cloze], 2)
        XCTAssertTrue(metadata.notes.values.allSatisfy { $0.content == nil })
        let allowed = try repo.descendants(of: root)
        let scoped = try await reader.search("", revision: 1, deckIDs: allowed)
        XCTAssertEqual(scoped.noteCount, 2); XCTAssertEqual(scoped.cardCount, 4)
        let loaded = try await reader.load(revision: 1)
        XCTAssertNil(loaded.notes[hidden]?.content, "Hidden decks must not load content")
        for card in scoped.cardsByDeck.values.joined() {
            let expected = try XCTUnwrap(original.first { $0.cardID == card.id })
            XCTAssertEqual(try loaded.displayed(card).question, expected.content.question)
            XCTAssertEqual(try loaded.displayed(card).answer, expected.content.answer)
        }
        let byTag = try await reader.search("地理", revision: 1, deckIDs: allowed)
        XCTAssertEqual(byTag.cardCount, 2)
        let noMatch = try await reader.search("missing", revision: 1, deckIDs: allowed)
        XCTAssertEqual(noMatch.cardCount, 0)
        let reverse = try await reader.search("首都", revision: 1, deckIDs: [child])
        XCTAssertEqual(reverse.cardCount, 2)
        let selected = Set(original.filter { $0.noteID == note }.map(\.cardID))
        let before = original.filter { $0.noteID == note }.map { ($0.cardID, $0.summary) }
        _ = try repo.applyBulkEdit(repo.previewBulkEdit(cardIDs: selected, action: .move(other)), now: now)
        let afterMove = try await reader.search("地理", revision: 2, deckIDs: [other])
        XCTAssertEqual(afterMove.cardIDs, selected)
        for (id, summary) in before {
            let detail = try XCTUnwrap(repo.noteItems(cardID: id).first)
            XCTAssertEqual(detail.deckID, other)
            XCTAssertEqual(detail.summary, summary)
        }
        try repo.deleteNote(id: note)
        let afterDelete = try await reader.search("地理", revision: 3, deckIDs: nil)
        XCTAssertEqual(afterDelete.cardCount, 0)
        let final = try await reader.load(revision: 3)
        XCTAssertEqual(final.cardCount, 3); XCTAssertEqual(final.noteCount, 2)
    }

    func testLibraryHiddenPayloadAndUnrelatedFSRSDoNotBlockScopedReadOrDetail() async throws {
        let container = try PersistenceController.makeStudyContainer(inMemory: true)
        let repo = StudyRepository(container: container)
        try repo.initialize(now: now)
        let root = try repo.decks()[0].id
        let other = try repo.createDeck(name: "非表示", now: now)
        let visible = try repo.createNote(NoteInput(deckID: root, question: "Q", answer: "A"), now: now)
        let hidden = try repo.createNote(NoteInput(deckID: other, question: "hidden", answer: "A"), now: now)
        try repo.transaction {
            try repo.notes().first { $0.id == hidden }?.contentPayload = Data("invalid".utf8)
            try repo.cards().first { $0.noteID == hidden }?.fsrsPayload = Data("invalid".utf8)
        }
        let reader = LibraryReader(container: container)
        let scope = try await reader.search("Q", revision: 1, deckIDs: [root])
        XCTAssertEqual(scope.cardCount, 1)
        let cardID = try XCTUnwrap(scope.cardIDs.first)
        let detail = try XCTUnwrap(repo.noteItems(cardID: cardID).first)
        XCTAssertEqual(detail.noteID, visible); XCTAssertEqual(detail.content.question, "Q")
        XCTAssertEqual(try repo.siblingCardCount(noteID: visible), 1)
        XCTAssertFalse(try repo.hasReviewedSibling(noteID: visible))
        do {
            _ = try await reader.search("", revision: 1, deckIDs: [other])
            XCTFail("Requested corrupt content must be reported")
        } catch { }
        // Readers must not repair/delete data or write anything.
        XCTAssertEqual(try repo.notes().count, 2); XCTAssertEqual(try repo.cards().count, 2)
        XCTAssertEqual(try repo.notes().first { $0.id == hidden }?.contentPayload, Data("invalid".utf8))
    }
    func testContextualTagsUseDeckBranchesSharedCountsANDAndKeepUnavailableSelection() {
        let root = UUID(), english = UUID(), japanese = UUID(), unused = UUID()
        let a = UUID(), b = UUID(), shared = UUID(), outside = UUID()
        let decks = [DeckItem(id: root, name: "共通の親"),
                     DeckItem(id: english, name: "共通の親 / 英語", shortName: "英語", parentID: root),
                     DeckItem(id: japanese, name: "共通の親 / 国語", shortName: "国語", parentID: root)]
        let tags = [TagItem(id: a, name: "人物・思想"), TagItem(id: b, name: "英文"),
                    TagItem(id: shared, name: "最重要"), TagItem(id: outside, name: "国語専用"), TagItem(id: unused, name: "未使用")]
        let index = TagFilterIndex(decks: decks, tags: tags, notes: [
            TagFilterNote(deckID: english, tagIDs: [a, b, shared], cards: 3),
            TagFilterNote(deckID: english, tagIDs: [a], cards: 1),
            TagFilterNote(deckID: japanese, tagIDs: [outside, shared], cards: 2)])
        let all = index.summary(scope: LearningScope())
        XCTAssertEqual(all.cards, 6)
        XCTAssertEqual(Set(all.groups.map(\.id)), [english.uuidString, japanese.uuidString, "shared"])
        XCTAssertEqual(all.groups.flatMap(\.tags).filter { $0.id == shared }.count, 1)
        XCTAssertEqual(all.groups.flatMap(\.tags).first { $0.id == shared }?.cards, 5)
        XCTAssertFalse(all.groups.flatMap(\.tags).contains { $0.id == unused })
        let parent = index.summary(scope: LearningScope(deckID: root, tagIDs: [a, b]))
        XCTAssertEqual(parent.cards, 3)
        XCTAssertEqual(parent.groups.flatMap(\.tags).first { $0.id == a }?.cards, 4)
        let scope = LearningScope(deckID: english, tagIDs: [outside])
        let selected = index.summary(scope: scope)
        XCTAssertEqual(selected.cards, 0); XCTAssertEqual(selected.unavailable, [outside])
        XCTAssertFalse(selected.groups.flatMap(\.tags).contains { $0.id == outside })
        XCTAssertEqual(scope.tagIDs, [outside])
        XCTAssertEqual(index.summary(scope: LearningScope(deckID: UUID())).cards, 0)
        let scale = TagFilterIndex(decks: decks, tags: tags, notes: (0..<1000).map { _ in
            TagFilterNote(deckID: english, tagIDs: [a], cards: 3)
        })
        XCTAssertEqual(scale.summary(scope: LearningScope(tagIDs: [a])).cards, 3000)
    }

    func testTagFilterReaderCountsGeneratedCardsWithoutReadingFSRSOrChangingSession() async throws {
        let container = try PersistenceController.makeStudyContainer(inMemory: true)
        let repo = StudyRepository(container: container)
        try repo.initialize(now: now)
        let root = try repo.decks()[0].id
        let child = try repo.createDeck(name: "子", parentID: root, now: now)
        try repo.createNote(NoteInput(deckID: child, kind: .cloze, question: "{{c1::一}} {{c2::二}} {{c3::三}}", tagNames: ["日本語"]), now: now)
        try repo.start(mode: .new, now: now)
        let draft = try repo.session()?.cardID, payloads = try repo.cards().map(\.fsrsPayload)
        let loaded = try await TagFilterReader(container: container).load()
        let summary = loaded.summary(scope: LearningScope(deckID: root))
        XCTAssertEqual(summary.cards, 3)
        XCTAssertEqual(summary.groups.flatMap(\.tags).first?.cards, 3)
        XCTAssertEqual(try repo.session()?.cardID, draft)
        XCTAssertEqual(try repo.cards().map(\.fsrsPayload), payloads)
        XCTAssertEqual(try repo.logs().count, 0)
        try repo.transaction { for card in try repo.cards() { card.fsrsPayload = Data("invalid".utf8) } }
        let withoutFSRS = try await TagFilterReader(container: container).load()
        XCTAssertEqual(withoutFSRS.summary(scope: LearningScope()).cards, 3)
    }

}


extension LibraryRepositoryTests {
    func testOperationCompletionUsesReceiptCountsAndKeepsWarningsSeparate() {
        let target = UUID()
        var completion = LibraryOperationCompletion(operation: "移動", notes: 2, cards: 5,
            targetName: "移動先", destinationID: target)
        XCTAssertTrue(completion.isSuccess)
        XCTAssertEqual(completion.destinationID, target)
        XCTAssertTrue(completion.summary.contains("2ノート・5枚"))
        XCTAssertTrue(completion.summary.contains("移動先"))
        completion.warning = "画面更新に失敗"
        XCTAssertFalse(completion.isSuccess)
        XCTAssertTrue(completion.hasChanges)
        XCTAssertTrue(completion.title.contains("保存しました"))
        let zero = LibraryOperationCompletion(operation: "削除", notes: 0, cards: 0,
            targetName: "元デッキ", destinationID: nil)
        XCTAssertFalse(zero.hasChanges)
        XCTAssertFalse(zero.isSuccess)
        XCTAssertEqual(zero.title, "変更対象はありません")
        XCTAssertNil(zero.destinationID)
    }
}

extension LibraryRepositoryTests {
    func testCardMarksPreserveSchedulerAndLogsAndNextStudyDay() throws {
        let repo = try fixture()
        let note = try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "Marked", answer: "A"), now: now)
        let card = try XCTUnwrap(repo.cards().first)
        let before = BackupStudyCard(card)
        try repo.start(mode: .new, now: now)
        try repo.setFlags(cardIDs: [card.id], flag: .blue)
        try repo.hideToday(cardID: card.id, now: now)
        XCTAssertEqual(try repo.noteItems(cardID: card.id).first?.flag, .blue)
        XCTAssertEqual(try repo.cards().map(BackupStudyCard.init), [before])
        XCTAssertTrue(try repo.logs().isEmpty)
        XCTAssertNil(try repo.session()?.cardID)
        XCTAssertEqual(try repo.homeSnapshot(now: now).counts.newRemaining, 0)
        let end = try XCTUnwrap(repo.cardMark(card.id)?.hiddenUntil)
        XCTAssertEqual(try repo.homeSnapshot(now: end).counts.newRemaining, 1)
        try repo.setSuspended(cardID: card.id, value: true, now: now)
        XCTAssertEqual(try repo.homeSnapshot(now: end).counts.newRemaining, 0)
        try repo.setSuspended(cardID: card.id, value: false, now: now)
        try repo.showToday(cardID: card.id)
        XCTAssertEqual(try repo.homeSnapshot(now: now).counts.newRemaining, 1)
        try repo.setFlags(cardIDs: [card.id], flag: nil)
        XCTAssertNil(try repo.cardMark(card.id))
        try repo.setFlags(cardIDs: [card.id], flag: .red)
        try repo.deleteNote(id: note)
        XCTAssertTrue(try repo.options().cardMarks?.isEmpty == true)
    }
    func testCardMarksRollbackAndUndoRetainIndependentHold() throws {
        let repo = try fixture()
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "Held", answer: "A"), now: now)
        let card = try XCTUnwrap(repo.cards().first)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(revealed: true, now: now)
        let before = BackupStudyCard(card)
        try repo.grade(.good, now: now)
        try repo.setFlags(cardIDs: [card.id], flag: .yellow)
        try repo.hideToday(cardID: card.id, now: now)
        try repo.undo(now: now)
        XCTAssertEqual(BackupStudyCard(card), before)
        XCTAssertTrue(try repo.logs().isEmpty)
        XCTAssertNil(try repo.session()?.cardID)
        XCTAssertEqual(try repo.cardMark(card.id)?.flag, .yellow)
        let saved = try repo.options()
        let failing = StudyRepository(container: repo.context.container, save: { _ in throw Failure.save })
        XCTAssertThrowsError(try failing.setFlags(cardIDs: [card.id], flag: .red))
        XCTAssertEqual(try failing.options(), saved)
        XCTAssertThrowsError(try failing.hideToday(cardID: card.id, now: now.addingTimeInterval(86400)))
        XCTAssertEqual(try failing.options(), saved)
    }
    func testCardMarksLegacyOptionsAndInvalidMetadata() throws {
        let legacy = try JSONDecoder().decode(StudyOptions.self, from: JSONEncoder().encode(StudyOptions()))
        XCTAssertNil(legacy.cardMarks)
        let repo = try fixture()
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "Q", answer: "A"), now: now)
        let id = try XCTUnwrap(repo.cards().first?.id)
        var saved = try repo.options()
        saved.cardMarks = [CardMark(cardID: id, flag: .red), CardMark(cardID: id, flag: .blue)]
        try repo.updateOptions(saved)
        XCTAssertThrowsError(try repo.options())
        XCTAssertThrowsError(try repo.queueCards())
    }
}

extension LibraryRepositoryTests {
    func testManualHoldForecastMovesAvailabilityWithoutChangingDue() throws {
        let repo = try fixture()
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "Forecast", answer: "A"), now: now)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(revealed: true, now: now)
        try repo.grade(.again, now: now)
        let card = try XCTUnwrap(repo.cards().first)
        let due = card.dueDate, payload = card.fsrsPayload
        try repo.hideToday(cardID: card.id, now: now)
        let data = try BackupData.capture(repo)
        let forecast = try ReviewForecast.calculate(data: data, deckID: nil, days: 7, now: now, calendar: repo.calendar)
        XCTAssertEqual(forecast.days[0].scheduled, 0)
        XCTAssertEqual(forecast.days[0].reviews, 0)
        XCTAssertEqual(forecast.days[1].scheduled, 1)
        XCTAssertGreaterThan(forecast.days[1].reviews, 0)
        XCTAssertEqual(card.dueDate, due)
        XCTAssertEqual(card.fsrsPayload, payload)
        XCTAssertEqual(try repo.logs().count, 1)
    }
}

extension LibraryRepositoryTests {
    func testTextReplacementFieldsSiblingCardsAndHistoryPreserved() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        var input = NoteInput(deckID: deck, question: "Alpha alpha", answer: "ALPHA", explanation: "alpha", hint: "alpha")
        input.reverseEnabled = true
        let noteID = try repo.createNote(input, now: now)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(revealed: true, now: now)
        try repo.grade(.good, now: now.addingTimeInterval(1))
        let original = try repo.cards().map { ($0.id, $0.fsrsPayload, $0.dueDate, $0.updatedAt, $0.variantKey) }
        let logs = try repo.logs().map { ($0.id, $0.fsrsBefore, $0.fsrsAfter) }
        let preview = try repo.previewTextReplacement(.init(scope: .cards([original[0].0]), find: "alpha", replacement: "Beta", fields: Set(ReplacementField.allCases)))
        XCTAssertEqual(preview.changedRows.count, 1); XCTAssertEqual(preview.changedCards, 2); XCTAssertEqual(preview.occurrences, 5)
        let result = try repo.applyTextReplacement(preview, now: now.addingTimeInterval(2))
        XCTAssertEqual(result.changedNotes, 1)
        let content = try JSONDecoder().decode(TextContent.self, from: XCTUnwrap(repo.notes().first { $0.id == noteID }).contentPayload)
        XCTAssertEqual(content.question, "Beta Beta"); XCTAssertEqual(content.answer, "Beta"); XCTAssertEqual(content.explanation, "Beta"); XCTAssertEqual(content.hint, "Beta")
        for state in original {
            let card = try XCTUnwrap(repo.cards().first { $0.id == state.0 })
            XCTAssertEqual(card.fsrsPayload, state.1); XCTAssertEqual(card.dueDate, state.2)
            XCTAssertEqual(card.updatedAt, state.3); XCTAssertEqual(card.variantKey, state.4)
        }
        for state in logs {
            let log = try XCTUnwrap(repo.logs().first { $0.id == state.0 })
            XCTAssertEqual(log.fsrsBefore, state.1); XCTAssertEqual(log.fsrsAfter, state.2)
        }
    }

    func testTextReplacementRejectsStaleSelectionCancellationAndSaveFailure() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        _ = try repo.createNote(NoteInput(deckID: deck, question: "old", answer: "A"), now: now)
        _ = try repo.createNote(NoteInput(deckID: deck, question: "old", answer: "B"), now: now)
        let request = ReplacementRequest(scope: .deck(deck, descendants: true), find: "old", replacement: "new", fields: [.question])
        let first = try repo.previewTextReplacement(request)
        var calls = 0
        XCTAssertThrowsError(try repo.applyTextReplacement(first, now: now) { calls += 1; return calls >= 3 }) { error in
            guard case ReplacementError.cancelled = error else { return XCTFail("Expected cancelled, got \(error)") }
        }
        XCTAssertEqual(try repo.previewTextReplacement(request), first)
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.applyTextReplacement(first, now: now)) { error in
            guard case Failure.save = error else { return XCTFail("Expected save failure, got \(error)") }
        }
        XCTAssertEqual(try repo.previewTextReplacement(request), first)
        repo.save = { try $0.save() }
        _ = try repo.createNote(NoteInput(deckID: deck, question: "old", answer: "C"), now: now)
        XCTAssertThrowsError(try repo.applyTextReplacement(first, now: now))
        let second = try repo.previewTextReplacement(request)
        let note = try XCTUnwrap(repo.notes().first)
        try repo.transaction { note.updatedAt = now.addingTimeInterval(1) }
        XCTAssertThrowsError(try repo.applyTextReplacement(second, now: now))
        let third = try repo.previewTextReplacement(request)
        try repo.deleteNote(id: note.id)
        XCTAssertThrowsError(try repo.applyTextReplacement(third, now: now))
    }

    func testTextReplacementSkipsClozeTemplatesDraftsAndInvalidBodies() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        _ = try repo.createNote(NoteInput(deckID: deck, kind: .cloze, question: "{{c1::old}}", answer: ""), now: now)
        let draftID = try repo.createNote(NoteInput(deckID: deck, question: "old draft", answer: "A"), now: now)
        try repo.saveEditorDraft(key: "edit:\(draftID.uuidString)", input: NoteInput(deckID: deck, question: "draft", answer: "A"), now: now)
        _ = try repo.createNote(NoteInput(deckID: deck, question: "old {{Field}}", answer: "A"), now: now)
        let futureID = try repo.createNote(NoteInput(deckID: deck, question: "old", answer: "A"), now: now)
        try repo.transaction {
            let note = try XCTUnwrap(repo.notes().first { $0.id == futureID })
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: note.contentPayload) as? [String: Any])
            object["futureField"] = "preserve"
            note.contentPayload = try JSONSerialization.data(withJSONObject: object)
        }
        let request = ReplacementRequest(scope: .deck(deck, descendants: false), find: "old", replacement: "new", fields: [.question])
        let preview = try repo.previewTextReplacement(request)
        XCTAssertEqual(preview.skipped, 4); XCTAssertTrue(preview.changedRows.isEmpty)
        XCTAssertThrowsError(try repo.applyTextReplacement(preview, now: now))
        let invalid = try repo.previewTextReplacement(.init(scope: .cards(Set(repo.cards().filter { $0.noteID == futureID }.map(\.id))), find: "old", replacement: "", fields: [.question]))
        XCTAssertTrue(invalid.changedRows.isEmpty)
    }

    func testTextReplacementDeckDescendantsAndMatchingSemantics() throws {
        let repo = try fixture(), root = try repo.decks()[0].id
        let child = Deck(name: "child", now: now)
        try repo.transaction { child.parentID = root; repo.context.insert(child) }
        _ = try repo.createNote(NoteInput(deckID: root, question: "Word", answer: "Word Word"), now: now)
        _ = try repo.createNote(NoteInput(deckID: child.id, question: "word", answer: "Word"), now: now)
        let direct = try repo.previewTextReplacement(.init(scope: .deck(root, descendants: false), find: "Word", replacement: "Next", fields: [.question], caseSensitive: true, wholeField: true))
        XCTAssertEqual(direct.changedRows.count, 1)
        let children = try repo.previewTextReplacement(.init(scope: .deck(root, descendants: true), find: "word", replacement: "Next", fields: [.question], wholeField: true))
        XCTAssertEqual(children.changedRows.count, 2)
        XCTAssertEqual(ReplacementRequest(scope: .cards([]), find: "aa", replacement: "$1\\", fields: [.question]).replacing("aaaa").text, "$1\\$1\\")
        let noMatch = try repo.previewTextReplacement(.init(scope: .deck(root, descendants: true), find: "none", replacement: "Next", fields: [.question]))
        XCTAssertTrue(noMatch.changedRows.isEmpty)
        XCTAssertThrowsError(try repo.applyTextReplacement(noMatch, now: now))
    }

    func testTextReplacement3000CardsAndActiveAnswerReset() throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        let payload = try JSONEncoder().encode(ReviewScheduler().newCard(now: now))
        try repo.transaction {
            for index in 0..<3000 {
                let input = NoteInput(deckID: deck, question: "old \(index)", answer: "Answer")
                let note = Note(input: input, content: try JSONEncoder().encode(TextContent(question: input.question, answer: input.answer, explanation: "")), now: now)
                repo.context.insert(note); repo.context.insert(StudyCard(noteID: note.id, variantKey: "basic:front", payload: payload, now: now))
            }
        }
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(mode: .typing, text: "old answer", revealed: true, now: now)
        let start = Date()
        let preview = try repo.previewTextReplacement(.init(scope: .deck(deck, descendants: true), find: "old", replacement: "new", fields: [.question]))
        let previewSeconds = Date().timeIntervalSince(start), saveStart = Date()
        let result = try repo.applyTextReplacement(preview, now: now.addingTimeInterval(1))
        let saveSeconds = Date().timeIntervalSince(saveStart)
        print("TextReplacement 3000 cards: preview=\(previewSeconds)s apply=\(saveSeconds)s")
        XCTAssertEqual(result.changedNotes, 3000); XCTAssertEqual(result.changedCards, 3000)
        XCTAssertEqual(preview.occurrences, 3000)
        XCTAssertEqual(try repo.session()?.typedDraft, ""); XCTAssertEqual(try repo.session()?.answerRevealed, false)
        XCTAssertEqual(try repo.cards().count, 3000); XCTAssertTrue(try repo.logs().isEmpty)
        XCTAssertTrue(try repo.notes().allSatisfy { (try? JSONDecoder().decode(TextContent.self, from: $0.contentPayload).question.hasPrefix("new")) == true })
    }
}


extension LibraryRepositoryTests {
    func testTextReplacementActorSaveRefreshesMainContextAndOrderingDraft() async throws {
        let repo = try fixture(), deck = try repo.decks()[0].id
        let id = try repo.createNote(NoteInput(deckID: deck, question: "old", answer: "abc def", responseMode: .ordering), now: now)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(revealed: true, now: now)
        let reader = TextReplacementReader(container: repo.context.container)
        let preview = try await reader.textReplacementPreview(.init(scope: .deck(deck, descendants: true), find: "abc", replacement: "xyz", fields: [.answer]))
        let result = try await reader.apply(preview, now: now)
        XCTAssertEqual(result.changedNotes, 1)
        let fresh = StudyRepository(container: repo.context.container)
        let content = try JSONDecoder().decode(TextContent.self, from: XCTUnwrap(fresh.notes().first { $0.id == id }).contentPayload)
        XCTAssertEqual(content.answer, "xyz def")
        let item = try XCTUnwrap(fresh.noteItems().first)
        XCTAssertNotNil(try fresh.orderingDraft(for: item))
        XCTAssertEqual(try fresh.session()?.answerRevealed, false)
        XCTAssertEqual(try fresh.cards().map(\.id), try repo.cards().map(\.id))
        XCTAssertTrue(try fresh.logs().isEmpty)
        XCTAssertThrowsError(try fresh.applyTextReplacement(preview, now: now))
    }
}
