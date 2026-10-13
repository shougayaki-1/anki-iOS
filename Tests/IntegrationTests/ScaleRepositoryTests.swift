import XCTest
import SwiftData
import UIKit
import Darwin
@testable import AnkiIOS

private final class ImportMemoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
    private func sample() {
        let value = Self.footprint()
        lock.lock(); peak = max(peak, value); lock.unlock()
    }
    static func run<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let probe = Self(), before = footprint(), start = Date()
        probe.sample()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { probe.sample() }; timer.resume()
        defer { timer.cancel() }
        let result = try body()
        probe.sample(); probe.lock.lock(); let peak = probe.peak; probe.lock.unlock()
        print("IMPORT_BUFFER stage=\(name) ms=\(Date().timeIntervalSince(start) * 1000) before_bytes=\(before) sampled_peak_bytes=\(peak) after_bytes=\(footprint())")
        return result
    }
}

@MainActor
final class ScaleRepositoryTests: XCTestCase {
    func testProfilingFixturesAreIsolatedAndDoNotReplaceExistingData() throws {
        #if DEBUG
        for basic in [true, false] {
            let container = try PersistenceController.makeStudyContainer(inMemory: true)
            let repository = StudyRepository(container: container)
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            try repository.initialize(now: now)
            try UITestFixtures.populateScale(repository, now: now, basic: basic, multipleDecks: true)
            let notes = try repository.notes(), cards = try repository.cards(), logs = try repository.logs()
            XCTAssertEqual(notes.count, basic ? 3000 : 1000)
            XCTAssertEqual(cards.count, 3000)
            XCTAssertEqual(logs.count, basic ? 0 : 10000)
            XCTAssertEqual(try repository.decks().count, 20)
            let ids = Set(notes.map(\.id)), cardIDs = Set(cards.map(\.id)), logIDs = Set(logs.map(\.id))
            try UITestFixtures.populateScale(repository, now: now, basic: !basic, multipleDecks: true)
            XCTAssertEqual(Set(try repository.notes().map(\.id)), ids)
            XCTAssertEqual(Set(try repository.cards().map(\.id)), cardIDs)
            XCTAssertEqual(Set(try repository.logs().map(\.id)), logIDs)
        }
        #endif
    }

    func testAnkiImportBufferMeasurements() throws {
        let url = try XCTUnwrap(Bundle(for: ScaleRepositoryTests.self).url(forResource: "latest-vocabulary-1900", withExtension: "apkg", subdirectory: "Anki"))
        let bytes = try Data(contentsOf: url)
        let preview = try ImportMemoryProbe.run("apkg_1900_preview") { try AnkiImport.decode(bytes) }
        XCTAssertEqual(preview.sourceNotes, 1900)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: root.appendingPathComponent("Study.store")), mediaStore: MediaStore(root: root.appendingPathComponent("Media")))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try repo.initialize(now: now)
        let count = try ImportMemoryProbe.run("apkg_1900_commit") { try repo.importDeckPackage(preview.deck, skipDuplicates: true, now: now) }
        XCTAssertEqual(count, 1900)
        _ = try ImportMemoryProbe.run("apkg_1900_home") { try StudyStore(container: repo.context.container, clock: { now }, mediaStore: repo.mediaStore) }
    }
    func testTextImportPreparationScale() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true))
        try repo.initialize(now: now)
        let deck = try repo.decks()[0].id
        let rows = (0..<3000).map { ImportRow(line: $0 + 1, question: "Question \($0)", answer: "Answer \($0)") }
        // Reproduce the previous per-row persistence validation without saving.
        let oldPayloads = try ImportMemoryProbe.run("csv_previous_validation_3000") {
            try rows.map { try repo.validate(NoteInput(deckID: deck, question: $0.question, answer: $0.answer)) }
        }
        let prepared = try await Task.detached(priority: .userInitiated) {
            try ImportMemoryProbe.run("csv_worker_preparation_3000") {
                try PreparedTextImport.make(rows, deckID: deck, kind: .basic, tagNames: [])
            }
        }.value
        XCTAssertEqual(try prepared.rows.map { try JSONDecoder().decode(TextContent.self, from: $0.content) },
                       try oldPayloads.map { try JSONDecoder().decode(TextContent.self, from: $0) })
        let result = try ImportMemoryProbe.run("csv_prepared_commit_3000") {
            try repo.importPreparedRows(prepared, action: .skip, source: "CSV", now: now)
        }
        XCTAssertEqual(result.createdCards, 3000)
        XCTAssertEqual(try repo.cards().count, 3000)
        XCTAssertEqual(try repo.context.fetch(FetchDescriptor<ImportBatch>()).count, 1)
    }

    func testImportBufferScaleMeasurements() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: root.appendingPathComponent("Study.store")), mediaStore: MediaStore(root: root.appendingPathComponent("Media")))
        try repo.initialize(now: now)
        let deck = try repo.decks()[0].id
        let text = "question,answer\n" + (0..<3000).map { "問題\($0),\"解答・日本語の細字 \(String(repeating: "内容", count: 80))\"" }.joined(separator: "\r\n")
        let rows = try ImportMemoryProbe.run("csv_preview") { ImportParser.map(try ImportParser.table(text, delimiter: ","), header: true, questionColumn: 0, answerColumn: 1) }
        XCTAssertEqual(rows.count, 3000)
        let result = try ImportMemoryProbe.run("csv_commit") { try repo.importRows(rows, deckID: deck, kind: .basic, tagNames: [], action: .skip, source: "CSV", now: now) }
        XCTAssertEqual(result.createdCards, 3000)
        _ = try ImportMemoryProbe.run("csv_home") { try StudyStore(container: repo.context.container, clock: { now }, mediaStore: repo.mediaStore) }
        let share = try await DeckExchange.export(repository: repo, rootID: deck)
        let validated = try ImportMemoryProbe.run("studydeck_3000_preview") { try DeckExchange.decode(share) }
        let destinationRoot = root.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let destination = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: destinationRoot.appendingPathComponent("Study.store")), mediaStore: MediaStore(root: destinationRoot.appendingPathComponent("Media")))
        try destination.initialize(now: now)
        let sharedCount = try ImportMemoryProbe.run("studydeck_3000_commit") { try destination.importDeckPackage(validated, skipDuplicates: true, now: now) }
        XCTAssertEqual(sharedCount, 3000)
        _ = try ImportMemoryProbe.run("studydeck_3000_home") { try StudyStore(container: destination.context.container, clock: { now }, mediaStore: destination.mediaStore) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1200), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
            ("日本語の画像・図表" as NSString).draw(at: CGPoint(x: 100, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 64)])
        }.jpegData(compressionQuality: 0.95))
        var files = Dictionary(uniqueKeysWithValues: (0..<200).map { ("images/\($0).jpg", image) })
        files["cards.csv"] = Data(("question,answer,image\n" + (0..<200).map { "写真\($0),解答,images/\($0).jpg" }.joined(separator: "\n")).utf8)
        let zip = try StoredZIP.write(files)
        let package = try ImportMemoryProbe.run("image_zip_preview") { try ImageImportPackage.read(zip) }
        XCTAssertEqual(package.rows.count, 200); XCTAssertEqual(package.images.count, 200)
        let imported = try ImportMemoryProbe.run("image_zip_commit") { try repo.importImagePackage(package, deckID: deck, action: .skip, now: now) }
        XCTAssertEqual(imported.createdCards, 200); XCTAssertEqual(try repo.assets().count, 1)
        _ = try ImportMemoryProbe.run("image_zip_home") { try StudyStore(container: repo.context.container, clock: { now }, mediaStore: repo.mediaStore) }
    }
    func testReviewHotPathThreeThousandCardsTenThousandLogs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try PersistenceController.makeStudyContainer(storeURL: root.appendingPathComponent("Study.store"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let writer = StudyRepository(container: container)
        try writer.initialize(now: now)
        let deck = try writer.decks()[0].id, scheduler = try ReviewScheduler()
        let before = try JSONEncoder().encode(scheduler.newCard(now: now))
        let transition = try scheduler.review(scheduler.newCard(now: now), grade: .easy, now: now)
        let after = try JSONEncoder().encode(transition.after)
        var cards: [StudyCard] = []
        try writer.transaction {
            for index in 0..<1000 {
                let input = NoteInput(deckID: deck, kind: .cloze, question: "Q \(index) {{c1::one}} {{c2::two}} {{c3::three}}", answer: "")
                let content = try JSONEncoder().encode(TextContent(question: input.question, answer: "", explanation: ""))
                let note = Note(input: input, content: content, now: now)
                writer.context.insert(note)
                for variant in 1...3 {
                    let card = StudyCard(noteID: note.id, variantKey: "cloze:\(variant)", payload: before, now: now)
                    writer.context.insert(card); cards.append(card)
                }
            }
            for index in 0..<10000 {
                let log = StudyReviewLog(card: cards[index % cards.count], transition: transition, before: before, after: after,
                                         mode: .mental, durationMs: 1000, wasNew: false, sequence: index + 1)
                log.reviewedAt = now.addingTimeInterval(-86400 * Double(index + 1))
                writer.context.insert(log)
            }
        }
        let store = try StudyStore(container: container, clock: { now })
        for iteration in 0..<3 {
            let repo = store.repository
            let fullBefore = repo.fullHistoryFetchCount, rowsBefore = repo.historyRowsFetched
            let projectionsBefore = repo.queueProjectionCount, decodeBefore = repo.queueStateDecodeCount
            let projectionBefore = repo.queueProjectionSeconds
            let start = Date()
            try repo.start(mode: .new, now: now)
            let startMs = Date().timeIntervalSince(start) * 1000
            let first = try XCTUnwrap(repo.session()?.cardID)
            try repo.updateDraft(revealed: true, now: now)
            let gradeStart = Date()
            store.grade(.good)
            let gradeMs = Date().timeIntervalSince(gradeStart) * 1000
            XCTAssertNil(store.failure)
            let undoStart = Date()
            store.undo()
            let undoMs = Date().timeIntervalSince(undoStart) * 1000
            XCTAssertNil(store.failure)
            XCTAssertEqual(try repo.session()?.cardID, first)
            XCTAssertEqual(try repo.card(first)?.fsrsPayload, before)
            XCTAssertEqual(repo.fullHistoryFetchCount - fullBefore, 0)
            print("REVIEW_HOT_PATH iteration=\(iteration) start_ms=\(startMs) grade_ms=\(gradeMs) undo_ms=\(undoMs) full_history_fetches=\(repo.fullHistoryFetchCount - fullBefore) history_rows=\(repo.historyRowsFetched - rowsBefore) queue_projections=\(repo.queueProjectionCount - projectionsBefore) queue_ms=\((repo.queueProjectionSeconds - projectionBefore) * 1000) fsrs_decodes=\(repo.queueStateDecodeCount - decodeBefore)")
        }
        XCTAssertEqual(try store.repository.context.fetchCount(FetchDescriptor<StudyReviewLog>()), 10000)
    }

    func testSelectedCardFetchScaling() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try PersistenceController.makeStudyContainer(storeURL: root.appendingPathComponent("Study.store"))
        let writer = StudyRepository(container: container)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try writer.initialize(now: now)
        let deck = try writer.decks()[0].id
        let payload = try JSONEncoder().encode(ReviewScheduler().newCard(now: now))
        var cardIDs: [UUID] = []
        for total in [3000, 10000] {
            try writer.transaction {
                for index in cardIDs.count..<total {
                    let input = NoteInput(deckID: deck, question: "Q \(index)", answer: "A")
                    let content = try JSONEncoder().encode(TextContent(question: input.question, answer: "A", explanation: ""))
                    let note = Note(input: input, content: content, now: now)
                    let card = StudyCard(noteID: note.id, variantKey: "basic:front", payload: payload, now: now)
                    writer.context.insert(note); writer.context.insert(card); cardIDs.append(card.id)
                }
            }
            for count in [10, 100, 1000] {
                let ids = Set(cardIDs.prefix(count))
                let old = StudyRepository(container: container)
                let start = Date()
                let oldCards = try old.cards().filter { ids.contains($0.id) }
                let noteIDs = Set(oldCards.map(\.noteID))
                let oldNotes = try old.notes().filter { noteIDs.contains($0.id) }
                let oldTime = Date().timeIntervalSince(start)
                let targeted = StudyRepository(container: container)
                let selectedStart = Date()
                let items = try targeted.noteItems(cardIDs: ids)
                let selectedTime = Date().timeIntervalSince(selectedStart)
                XCTAssertEqual(Set(items.map(\.cardID)), Set(oldCards.map(\.id)))
                XCTAssertEqual(Set(items.map(\.noteID)), Set(oldNotes.map(\.id)))
                print("ID_FETCH total=\(total) selected=\(count) legacy_fetch_only_ms=\(oldTime * 1000) targeted_projection_ms=\(selectedTime * 1000)")
            }
        }
    }

    func testStatisticsMaterialCacheThreeThousandCardsTenThousandLogs() async throws {
        let container = try PersistenceController.makeStudyContainer(inMemory: true)
        let repo = StudyRepository(container: container)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try repo.initialize(now: now)
        let deck = try repo.decks()[0].id, scheduler = try ReviewScheduler()
        let before = try JSONEncoder().encode(scheduler.newCard(now: now))
        let transition = try scheduler.review(scheduler.newCard(now: now), grade: .easy, now: now)
        let after = try JSONEncoder().encode(transition.after)
        var cards: [StudyCard] = []
        try repo.transaction {
            for index in 0..<1000 {
                let input = NoteInput(deckID: deck, kind: .cloze, question: "Q \(index) {{c1::one}} {{c2::two}} {{c3::three}}", answer: "")
                let note = Note(input: input, content: try JSONEncoder().encode(TextContent(question: input.question, answer: "", explanation: "")), now: now)
                repo.context.insert(note)
                for variant in 1...3 {
                    let card = StudyCard(noteID: note.id, variantKey: "cloze:\(variant)", payload: after, now: now)
                    card.dueDate = try scheduler.summary(transition.after).dueDate
                    repo.context.insert(card); cards.append(card)
                }
            }
            for index in 0..<10000 {
                let log = StudyReviewLog(card: cards[index % cards.count], transition: transition, before: before, after: after,
                                         mode: .mental, durationMs: 1000, wasNew: index < 3000, sequence: index + 1)
                log.reviewedAt = now.addingTimeInterval(-Double(index) * 3600)
                repo.context.insert(log)
            }
        }
        let reader = StatisticsReader(container: container)
        for iteration in 0..<3 {
            let start = Date()
            let report = try await reader.load(now: now, calendar: repo.calendar, startHour: 4, scope: LearningScope(), revision: iteration)
            let coldMs = Date().timeIntervalSince(start) * 1000
            let warmStart = Date()
            let warm = try await reader.load(now: now, calendar: repo.calendar, startHour: 4, scope: LearningScope(deckID: deck), revision: iteration)
            let warmMs = Date().timeIntervalSince(warmStart) * 1000
            let revisitStart = Date()
            let revisit = try await reader.load(now: now.addingTimeInterval(60), calendar: repo.calendar, startHour: 4, scope: LearningScope(), revision: iteration)
            let revisitMs = Date().timeIntervalSince(revisitStart) * 1000
            XCTAssertEqual(revisit.days.map(\.answers), report.days.map(\.answers))
            XCTAssertEqual(warm.days.map(\.answers), report.days.map(\.answers))
            XCTAssertEqual(warm.weeks.map(\.answers), report.weeks.map(\.answers))
            XCTAssertEqual(warm.months.map(\.answers), report.months.map(\.answers))
            XCTAssertEqual(warm.meanRetrievability, report.meanRetrievability)
            XCTAssertEqual(warm.ratings, report.ratings)
            XCTAssertEqual(warm.durationMs, report.durationMs)
            XCTAssertEqual(warm.streak, report.streak)
            XCTAssertEqual(warm.overdueCount, report.overdueCount)
            XCTAssertEqual(warm.unattributedAnswers, report.unattributedAnswers)
            for (actual, expected) in [(warm.days, report.days), (warm.weeks, report.weeks), (warm.months, report.months)] {
                XCTAssertEqual(actual.map(\.date), expected.map(\.date))
                XCTAssertEqual(actual.map(\.cards), expected.map(\.cards))
                XCTAssertEqual(actual.map(\.newAnswers), expected.map(\.newAnswers))
                XCTAssertEqual(actual.map(\.reviewAnswers), expected.map(\.reviewAnswers))
                XCTAssertEqual(actual.map(\.ratings), expected.map(\.ratings))
                XCTAssertEqual(actual.map(\.durationMs), expected.map(\.durationMs))
            }
            let reads = await reader.materialReads, decodes = await reader.fsrsDecodes, cost = await reader.cachedCost
            XCTAssertEqual(reads, iteration + 1)
            XCTAssertEqual(decodes, (iteration + 1) * 3000)
            let aggregations = await reader.historyAggregations
            XCTAssertEqual(aggregations, (iteration + 1) * 2)
            print("STATISTICS_CACHE iteration=\(iteration) cold_ms=\(coldMs) new_scope_ms=\(warmMs) same_scope_revisit_ms=\(revisitMs) material_reads=\(reads) fsrs_decodes=\(decodes) history_aggregations=\(aggregations) cost=\(cost)")
        }
    }
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
            let prepared = try await reader.contents(revision: 1, deckIDs: nil)
            let listed = cached.cardsByDeck.values.flatMap { $0 }
            let beforeDecodes = await reader.contentDecodes
            let legacyRowsStart = Date()
            var legacyCharacters = 0
            for _ in 0..<10 {
                for card in listed { legacyCharacters += try prepared.displayed(card).question.count }
            }
            let legacyRowsMs = Date().timeIntervalSince(legacyRowsStart) * 1000
            let preparedRowsStart = Date()
            var preparedCharacters = 0
            for _ in 0..<10 {
                for card in listed { preparedCharacters += prepared.rowContents[card.id]?.question.count ?? 0 }
            }
            let preparedRowsMs = Date().timeIntervalSince(preparedRowsStart) * 1000
            XCTAssertEqual(legacyCharacters, preparedCharacters)
            for _ in 0..<10 { _ = try await reader.contents(revision: 1, deckIDs: [first]) }
            let afterDecodes = await reader.contentDecodes
            XCTAssertEqual(beforeDecodes, afterDecodes)
            let retainedBytes = await reader.retainedContentBytes
            print("LIBRARY_ROWS notes=\(noteCount) cards=3000 passes=10 repeated_transform_ms=\(legacyRowsMs) prepared_lookup_ms=\(preparedRowsMs) retained_estimated_bytes=\(retainedBytes) reopened_content_decodes=\(afterDecodes - beforeDecodes)")
            XCTAssertEqual(try repo.logs().count, logCount)
            print("Issue115 notes=\(noteCount) cards=3000 logs=\(logCount) decks=20 legacyFullDetails=\(legacyLoad)s legacySearchGroups=\(legacySearchGroups)s metadata=\(metadataTime)s scopedContent=\(scopedTime)s firstSearch=\(coldTime)s cachedSearch=\(cachedTime)s")
        }
    }
}
