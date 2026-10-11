import XCTest
import SwiftData
@testable import AnkiIOS

final class WidgetSnapshotTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    func testDueNewProgressAndStudyDayBoundaryUseSavedSchedules() throws {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 3, minute: 59))!
        let id = UUID()
        let cards = [QueueCard(id: id, state: "learning", due: now.addingTimeInterval(-60), createdAt: now, suspended: false),
            QueueCard(id: UUID(), state: "review", due: now.addingTimeInterval(120), createdAt: now, suspended: false),
            QueueCard(id: UUID(), state: "new", due: now, createdAt: now, suspended: false),
            QueueCard(id: UUID(), state: "review", due: now, createdAt: now, suspended: true)]
        let logs = [QueueLog(cardID: id, reviewedAt: now.addingTimeInterval(-60), wasNew: false)]
        var settings = StudySettings(); settings.dailyGoal = 2
        let value = try WidgetProjection.make(cards: cards, logs: logs, settings: WidgetProjectionSettings(settings), now: now, calendar: calendar)
        let point = try XCTUnwrap(value.point(at: now, timeZone: calendar.timeZone))
        XCTAssertEqual(point.due, 1); XCTAssertEqual(point.learnedToday, 1); XCTAssertEqual(point.answersToday, 1); XCTAssertEqual(point.newAvailable, 1)
        let tomorrow = try XCTUnwrap(value.point(at: now.addingTimeInterval(60), timeZone: calendar.timeZone))
        XCTAssertEqual(tomorrow.learnedToday, 0); XCTAssertEqual(tomorrow.due, 1)
        XCTAssertEqual(value.point(at: now.addingTimeInterval(120), timeZone: calendar.timeZone)?.due, 2)
        XCTAssertNil(value.point(at: value.expiresAt, timeZone: calendar.timeZone))
        XCTAssertNil(value.point(at: now, timeZone: TimeZone(identifier: "Asia/Tokyo")!))
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        XCTAssertFalse(json.contains(id.uuidString)); XCTAssertFalse(json.contains("cardID")); XCTAssertFalse(json.contains("noteID"))
    }
    func testDSTAndEntryBudgetExpireBeforeUnrepresentedDeadline() throws {
        var zone = calendar; zone.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = zone.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 3))!
        let value = try WidgetProjection.make(cards: [], logs: [], settings: WidgetProjectionSettings(StudySettings()), now: now, calendar: zone)
        let boundaries = value.points.dropFirst().map(\.date)
        XCTAssertTrue(zip(boundaries, boundaries.dropFirst()).contains { $1.timeIntervalSince($0) == 23 * 3600 })
        let many = (1...200).map { QueueCard(id: UUID(), state: "review", due: now.addingTimeInterval(Double($0) * 60), createdAt: now, suspended: false) }
        let capped = try WidgetProjection.make(cards: many, logs: [], settings: WidgetProjectionSettings(StudySettings()), now: now, calendar: zone)
        XCTAssertTrue(capped.valid()); XCTAssertLessThanOrEqual(capped.points.count, 128)
        XCTAssertEqual(capped.expiresAt, now.addingTimeInterval(113 * 60))
        XCTAssertEqual(capped.point(at: now.addingTimeInterval(112 * 60), timeZone: zone.timeZone)?.due, 112)
        XCTAssertNil(capped.point(at: capped.expiresAt, timeZone: zone.timeZone))
    }
    func testProjectionMatchesFormalQueueWithSiblingBuryAndNewLimit() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000), note = UUID(), reviewed = UUID()
        let cards = [QueueCard(id: reviewed, state: "review", due: now, createdAt: now, suspended: false, noteID: note),
            QueueCard(id: UUID(), state: "review", due: now, createdAt: now, suspended: false, noteID: note),
            QueueCard(id: UUID(), state: "learning", due: now, createdAt: now, suspended: false, noteID: note),
            QueueCard(id: UUID(), state: "new", due: now, createdAt: now, suspended: false)]
        let logs = [QueueLog(cardID: reviewed, reviewedAt: now, wasNew: true, noteID: note)]
        var settings = StudySettings(); settings.dailyNewLimit = 1
        let value = try WidgetProjection.make(cards: cards, logs: logs, settings: WidgetProjectionSettings(settings), now: now, calendar: calendar)
        for point in value.points {
            let expected = ReviewQueueBuilder(calendar: calendar).counts(cards: cards, logs: logs, settings: settings, now: point.date)
            XCTAssertEqual(point.due, expected.due); XCTAssertEqual(point.newAvailable, expected.newRemaining)
            XCTAssertEqual(point.learnedToday, expected.learnedToday); XCTAssertEqual(point.answersToday, expected.answerCount)
        }
    }
    func testReadOnlySnapshotFileRejectsMissingCorruptOversizedAndInvalidPayloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("snapshot.json"), file = WidgetSnapshotFile(url: url)
        XCTAssertNil(file.read())
        let now = Date()
        let value = try WidgetProjection.make(cards: [], logs: [], settings: WidgetProjectionSettings(StudySettings()), now: now, calendar: .current)
        try file.write(value); XCTAssertEqual(file.read(), value)
        var invalid = value; invalid.schemaVersion = 2
        XCTAssertThrowsError(try file.write(invalid))
        XCTAssertEqual(file.read(), value)
        try Data("broken".utf8).write(to: url); XCTAssertNil(file.read())
        try Data(count: WidgetSnapshotFile.maximumBytes + 1).write(to: url); XCTAssertNil(file.read())
        XCTAssertThrowsError(try WidgetSnapshotFile(url: nil).write(value))
    }
    func testWidgetLinksOnlyAcceptExplicitNavigationDestinations() {
        for (path, destination) in [("home", WidgetDestination.home), ("review", .review), ("progress", .progress)] {
            XCTAssertEqual(WidgetDestination.parse(URL(string: "ankistudy://widget/\(path)")!), destination)
        }
        for url in ["https://widget/review", "ankistudy://other/review", "ankistudy://widget/delete", "ankistudy://widget/review?id=1", "ankistudy://widget/review#fragment", "ankistudy://user@widget/review"] {
            XCTAssertNil(WidgetDestination.parse(URL(string: url)!))
        }
    }
    @MainActor func testWidgetPublicationAndFailureNeverChangeLearningDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = WidgetSnapshotFile(url: root.appendingPathComponent("widget.json"))
        var reloads = 0
        let publisher = WidgetSnapshotPublisher(file: file, reload: { reloads += 1 })
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), widgetSnapshots: publisher)
        let now = store.clock()
        try store.repository.createNote(NoteInput(deckID: store.repository.decks()[0].id, question: "Private secret", answer: "Never shared"), now: now)
        try store.reload()
        var settings = try store.repository.settings(); settings.dailyGoal = 50
        try store.repository.updateSettings(settings); try store.reload()
        let before = try BackupData.capture(store.repository)
        for _ in 0..<100 { if file.read()?.dailyGoal == 50 { break }; try await Task.sleep(for: .milliseconds(20)) }
        let snapshot = try XCTUnwrap(file.read())
        XCTAssertEqual(snapshot.dailyGoal, 50); XCTAssertEqual(snapshot.points.first?.newAvailable, 1)
        XCTAssertGreaterThan(reloads, 0); XCTAssertEqual(try BackupData.capture(store.repository), before)
        XCTAssertFalse(String(decoding: try Data(contentsOf: file.url!), as: UTF8.self).contains("Private secret"))
        let failed = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), widgetSnapshots: WidgetSnapshotPublisher(file: WidgetSnapshotFile(url: nil)))
        XCTAssertNotNil(failed.widgetFailure)
        XCTAssertTrue(failed.perform { try failed.repository.createNote(NoteInput(deckID: failed.repository.decks()[0].id, question: "Q", answer: "A"), now: now) })
        XCTAssertEqual(try failed.repository.notes().count, 1)
        XCTAssertTrue(try failed.repository.logs().isEmpty)
    }
}
