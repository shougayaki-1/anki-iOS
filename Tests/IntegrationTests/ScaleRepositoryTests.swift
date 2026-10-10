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
        XCTAssertEqual(store.notes.count, 3000)
        XCTAssertEqual(try repo.notes().count, 1000)
        XCTAssertEqual(try repo.logs().count, 10000)
        XCTAssertEqual(store.counts.due, 3000)
        let pollStart = Date()
        for _ in 0..<5 { store.refreshHome() }
        let pollTime = Date().timeIntervalSince(pollStart) / 5
        XCTAssertNil(store.homeFailure); XCTAssertEqual(store.counts.due, 3000)
        let studyStart = Date()
        try repo.start(mode: .review, now: due.addingTimeInterval(1))
        try repo.updateDraft(revealed: true, now: due.addingTimeInterval(1))
        try repo.grade(.good, now: due.addingTimeInterval(2))
        try repo.undo(now: due.addingTimeInterval(3))
        XCTAssertEqual(try repo.logs().count, 10000)
        let studyTime = Date().timeIntervalSince(studyStart)
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
