import XCTest
import SwiftData
@testable import AnkiIOS

@MainActor
final class ScaleRepositoryTests: XCTestCase {
    func testThousandNotesThreeThousandCardsTenThousandLogsAndBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Study.store")
        let container = try PersistenceController.makeStudyContainer(storeURL: url)
        let repo = StudyRepository(container: container, mediaStore: MediaStore(root: root.appendingPathComponent("Media")))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try repo.initialize(now: now)
        let deck = try repo.decks()[0].id, scheduler = try ReviewScheduler()
        let before = try JSONEncoder().encode(scheduler.newCard(now: now))
        let transition = try scheduler.review(scheduler.newCard(now: now), grade: .easy, now: now)
        let after = try JSONEncoder().encode(transition.after)
        let due = try scheduler.summary(transition.after).dueDate
        var cards: [StudyCard] = []
        let creationStart = Date()
        try repo.transaction {
            for index in 0..<1000 {
                let input = NoteInput(deckID: deck, kind: .cloze, question: "Note \(index) {{c1::one}} {{c2::two}} {{c3::three}}", answer: "")
                let payload = try JSONEncoder().encode(TextContent(question: input.question, answer: "", explanation: ""))
                let note = Note(input: input, content: payload, now: now)
                repo.context.insert(note)
                for variant in 1...3 {
                    let card = StudyCard(noteID: note.id, variantKey: "cloze:\(variant)", payload: after, now: now)
                    card.dueDate = due
                    repo.context.insert(card); cards.append(card)
                }
            }
            for index in 0..<10000 {
                let log = StudyReviewLog(card: cards[index % cards.count], transition: transition, before: before, after: after,
                                         mode: .mental, durationMs: 1000, wasNew: index < cards.count, sequence: index + 1)
                log.reviewedAt = now.addingTimeInterval(-Double(index) * 3600)
                repo.context.insert(log)
            }
        }
        let creationTime = Date().timeIntervalSince(creationStart)
        let reloadStart = Date()
        let store = try StudyStore(container: container, clock: { due.addingTimeInterval(1) }, mediaStore: repo.mediaStore)
        let reloadTime = Date().timeIntervalSince(reloadStart)
        let library = try await store.libraryReader.load(revision: store.dataRevision)
        XCTAssertEqual(library.cardCount, 3000)
        XCTAssertEqual(try repo.notes().count, 1000)
        XCTAssertEqual(try repo.logs().count, 10000)
        let statisticsReadStart = Date()
        let report = try await StatisticsReader(container: container).load(
            now: due.addingTimeInterval(1), calendar: .current,
            startHour: 4, scope: LearningScope()
        )
        let statisticsReadElapsed = Date().timeIntervalSince(statisticsReadStart)
        XCTAssertEqual(report.ratings[.easy], 10000)
        XCTAssertEqual(report.months.count, 12)
        print("Issue #9: 10000 persisted logs + 3000 FSRS cards report load: \(statisticsReadElapsed)s")
        let reportAttachment = XCTAttachment(string: "statistics 10000 logs / 3000 cards: \(statisticsReadElapsed)s")
        reportAttachment.name = "Issue9-statistics-scale-measurement"
        reportAttachment.lifetime = .keepAlways
        add(reportAttachment)
        XCTAssertEqual(store.counts.due, 3000)
        let pollStart = Date()
        for _ in 0..<5 { store.refreshHome() }
        let pollTime = Date().timeIntervalSince(pollStart) / 5
        XCTAssertNil(store.homeFailure); XCTAssertEqual(store.counts.due, 3000)
        // Empty sessions with 3000 future cards must not write on repeated home reads.
        store.clock = { now }
        try store.repository.transaction {
            store.repository.context.insert(SessionDraft(mode: .review, now: now))
        }
        try store.reload()
        var homeSaves = 0
        store.repository.save = { context in homeSaves += 1; try context.save() }
        let waitingStart = Date()
        for _ in 0..<5 { store.refreshHome() }
        let waitingTime = Date().timeIntervalSince(waitingStart) / 5
        XCTAssertEqual(homeSaves, 0)
        XCTAssertNil(store.homeFailure)
        XCTAssertLessThan(waitingTime, max(1, pollTime * 3))
        let legacyStart = Date()
        for _ in 0..<5 {
            // The original PR #44 refresh path, on the same waiting fixture.
            try store.repository.resume(now: now)
            try store.repository.setSessionActive(false, now: now)
            _ = try store.repository.presentation(now: now)
            _ = try store.repository.homeSnapshot(now: now)
        }
        let legacyTime = Date().timeIntervalSince(legacyStart) / 5
        XCTAssertEqual(homeSaves, 10)
        XCTAssertLessThan(waitingTime, legacyTime * 1.25 + 0.05)
        print("home waiting: cards=3000 logs=10000 newSaves=0 legacySaves=\(homeSaves) average=\(waitingTime)s legacy=\(legacyTime)s readOnlyBaseline=\(pollTime)s")
        try store.repository.completeSession(now: now)
        store.clock = { due.addingTimeInterval(1) }
        let studyStart = Date()
        try repo.start(mode: .review, now: due.addingTimeInterval(1))
        try repo.updateDraft(revealed: true, now: due.addingTimeInterval(1))
        try repo.grade(.good, now: due.addingTimeInterval(2))
        try repo.undo(now: due.addingTimeInterval(3))
        XCTAssertEqual(try repo.logs().count, 10000)
        let studyTime = Date().timeIntervalSince(studyStart)
        let bulkStart = Date()
        let originalStates = Dictionary(uniqueKeysWithValues: try repo.cards().map { ($0.id, $0.fsrsPayload) })
        let selection = Set(originalStates.keys)
        let destination = try repo.createDeck(name: "一括移動先", parentID: deck, now: now)
        for action in [BulkEditAction.move(destination), .addTags(["Scale", "scale"]), .suspended(true), .suspended(false)] {
            let preview = try repo.previewBulkEdit(cardIDs: selection, action: action)
            XCTAssertEqual(preview.notes.count, 1000); XCTAssertEqual(preview.cards.count, 3000)
            XCTAssertEqual(try repo.applyBulkEdit(preview, now: now).changedCards, 3000)
        }
        XCTAssertEqual(try repo.notes().count, 1000)
        XCTAssertEqual(try repo.logs().count, 10000)
        XCTAssertEqual(try repo.tags().count, 1)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try repo.cards().map { ($0.id, $0.fsrsPayload) }), originalStates)
        let bulkMetrics = "bulk: notes=1000 cards=3000 operations=move+add-tags+suspend+resume elapsed=\(Date().timeIntervalSince(bulkStart))s"
        print(bulkMetrics)
        let bulkAttachment = XCTAttachment(string: bulkMetrics); bulkAttachment.name = "Issue6-bulk-scale-measurement"
        bulkAttachment.lifetime = .keepAlways; add(bulkAttachment)
        let backupStart = Date()
        let bytes = try await BackupService.export(repository: repo, now: due, appVersion: "scale-test")
        let backup = try BackupArchive.decode(bytes)
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("Restored.store"))
        _ = try BackupService.restore(backup, location: location, mediaStore: repo.mediaStore, now: due)
        let reopened = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: location.canonicalStore), mediaStore: repo.mediaStore)
        XCTAssertEqual(try reopened.cards().count, 3000)
        XCTAssertEqual(try reopened.logs().count, 10000)
        XCTAssertEqual(Set(try reopened.cards().map(\.id)), Set(cards.map(\.id)))
        let metrics = "scale: notes=1000 cards=3000 logs=10000 creation=\(creationTime)s reload=\(reloadTime)s home-poll-average=\(pollTime)s review-and-undo=\(studyTime)s backup-and-restore=\(Date().timeIntervalSince(backupStart))s bytes=\(bytes.count)"
        print(metrics)
        let attachment = XCTAttachment(string: metrics); attachment.name = "Phase5-scale-measurement"
        attachment.lifetime = .keepAlways; add(attachment)
    }
}

extension ScaleRepositoryTests {
    func testThirtyDayForecastThreeThousandCardsDoesNotWrite() throws {
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try repo.initialize(now: now)
        let deck = try repo.decks()[0].id, scheduler = try ReviewScheduler()
        let content = try JSONEncoder().encode(TextContent(question: "Scale forecast", answer: "A", explanation: ""))
        let snapshot = try JSONEncoder().encode(scheduler.newCard(now: now))
        try repo.transaction {
            for _ in 0..<3000 {
                let note = Note(input: NoteInput(deckID: deck, question: "Scale forecast", answer: "A"), content: content, now: now)
                repo.context.insert(note)
                repo.context.insert(StudyCard(noteID: note.id, variantKey: "basic:front", payload: snapshot, now: now))
            }
        }
        let before = try BackupData.capture(repo).canonical(), start = Date()
        let report = try ReviewForecast.calculate(data: before, deckID: nil, days: 30, now: now, calendar: .current)
        print("Issue #13: 3000 cards / 30 days forecast: \(Date().timeIntervalSince(start))s")
        XCTAssertEqual(report.days.count, 30)
        XCTAssertEqual(report.days.reduce(0) { $0 + $1.newCards }, 300)
        XCTAssertEqual(report.remainingNew, 2700)
        XCTAssertEqual(try BackupData.capture(repo).canonical(), before)
        let past = now.addingTimeInterval(-86400 * 3)
        let first = try scheduler.review(scheduler.newCard(now: past), grade: .good, now: past)
        let transition = try scheduler.review(first.after, grade: .good, now: scheduler.summary(first.after).dueDate)
        let learned = try JSONEncoder().encode(transition.after), due = try scheduler.summary(transition.after).dueDate
        try repo.transaction {
            for card in try repo.cards() { card.fsrsPayload = learned; card.dueDate = due }
        }
        let learnedBefore = try BackupData.capture(repo).canonical(), learnedStart = Date()
        let loaded = try ReviewForecast.calculate(data: learnedBefore, deckID: nil, days: 30, now: now, calendar: .current)
        print("Issue #13: 3000 learned cards / 30 days forecast: \(Date().timeIntervalSince(learnedStart))s")
        XCTAssertEqual(loaded.days[0].scheduled, 3000)
        XCTAssertEqual(loaded.days[0].reviews, 3000)
        XCTAssertGreaterThan(loaded.projectedAnswers, 3000)
        XCTAssertEqual(try BackupData.capture(repo).canonical(), learnedBefore)
    }
}

extension ScaleRepositoryTests {
    func testLibraryProjectionScaleComparisons() async throws {
        for (noteCount, variants, logCount) in [(3000, 1, 0), (1000, 3, 10000)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let container = try PersistenceController.makeStudyContainer(storeURL: root.appendingPathComponent("Scale.store"))
            let repo = StudyRepository(container: container)
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            try repo.initialize(now: now)
            let first = try repo.decks()[0].id
            let decks = [first] + (1..<20).map { _ in UUID() }
            let scheduler = try ReviewScheduler()
            let before = try JSONEncoder().encode(scheduler.newCard(now: now))
            let transition = try scheduler.review(scheduler.newCard(now: now), grade: .easy, now: now)
            let after = try JSONEncoder().encode(transition.after)
            var cards: [StudyCard] = []
            try repo.transaction {
                for id in decks.dropFirst() {
                    let deck = Deck(name: "Scale deck", now: now); deck.id = id; repo.context.insert(deck)
                }
                for number in 0..<noteCount {
                    let question = variants == 1 ? "Card \(number)" : "Card \(number) {{c1::one}} {{c2::two}} {{c3::three}}"
                    let input = NoteInput(deckID: decks[number % decks.count], kind: variants == 1 ? .basic : .cloze, question: question, answer: "Answer")
                    let content = try JSONEncoder().encode(TextContent(question: question, answer: "Answer", explanation: ""))
                    let note = Note(input: input, content: content, now: now)
                    repo.context.insert(note)
                    for variant in 1...variants {
                        let card = StudyCard(noteID: note.id, variantKey: variants == 1 ? "basic:front" : "cloze:\(variant)", payload: after, now: now)
                        repo.context.insert(card); cards.append(card)
                    }
                }
                for number in 0..<logCount {
                    repo.context.insert(StudyReviewLog(card: cards[number % cards.count], transition: transition, before: before, after: after, mode: .mental, durationMs: 1000, wasNew: false, sequence: number + 1))
                }
            }
            let legacyRepository = StudyRepository(container: container)
            let legacyStart = Date()
            let legacy = try legacyRepository.noteItems()
            let legacyLoad = Date().timeIntervalSince(legacyStart)
            let groupingStart = Date()
            let siblingCounts = Dictionary(grouping: legacy, by: \.noteID).mapValues(\.count)
            var legacyDisplayed = 0
            for deck in decks {
                legacyDisplayed += legacy.filter {
                    "\($0.content.question) \($0.content.answer) \($0.deckName) \($0.tagNames.joined(separator: " "))".localizedCaseInsensitiveContains("Card")
                }.filter { $0.deckID == deck }.count
            }
            let legacySearchGroups = Date().timeIntervalSince(groupingStart)
            XCTAssertEqual(legacyDisplayed, 3000); XCTAssertEqual(siblingCounts.count, noteCount)
            let reader = LibraryReader(container: container), metadataStart = Date()
            let metadata = try await reader.load(revision: 1)
            let metadataTime = Date().timeIntervalSince(metadataStart)
            XCTAssertEqual(metadata.cardCount, 3000); XCTAssertEqual(metadata.noteCount, noteCount)
            XCTAssertTrue(metadata.notes.values.allSatisfy { $0.content == nil })
            let scopedStart = Date()
            let scoped = try await reader.search("", revision: 1, deckIDs: [first])
            let scopedTime = Date().timeIntervalSince(scopedStart)
            XCTAssertEqual(scoped.cardCount, 150)
            let scopedIndex = try await reader.load(revision: 1)
            XCTAssertEqual(scopedIndex.notes.values.filter { $0.content != nil }.count, noteCount / 20)
            let searchStart = Date()
            let cold = try await reader.search("Card", revision: 1, deckIDs: nil)
            let coldTime = Date().timeIntervalSince(searchStart)
            let cachedStart = Date()
            let cached = try await reader.search("Card", revision: 1, deckIDs: nil)
            let cachedTime = Date().timeIntervalSince(cachedStart)
            XCTAssertEqual(cold.cardCount, 3000); XCTAssertEqual(cached.cardIDs, Set(cards.map(\.id)))
            XCTAssertEqual(try repo.logs().count, logCount)
            print("Issue115 notes=\(noteCount) cards=3000 logs=\(logCount) decks=20 legacyFullDetails=\(legacyLoad)s legacySearchGroups=\(legacySearchGroups)s metadata=\(metadataTime)s scopedContent=\(scopedTime)s firstSearch=\(coldTime)s cachedSearch=\(cachedTime)s")
        }
    }
}
