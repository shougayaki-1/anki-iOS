import XCTest
import SwiftData
@testable import AnkiIOS

final class WidgetSnapshotTests: XCTestCase {
    @MainActor func testStreakProjectionSavedRatingsUndoBoundaryZoneAndLegacySnapshot() throws {
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true))
        repo.calendar = calendar
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 3, minute: 59))!
        try repo.initialize(now: now)
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "Q", answer: "A"), now: now)
        let settings = try repo.settings()
        XCTAssertEqual(try repo.widgetStreakDays(now: now, settings: settings)[0].streak, 0)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(revealed: true, now: now)
        XCTAssertEqual(try repo.widgetStreakDays(now: now, settings: settings)[0].cards, 0)
        try repo.grade(.again, now: now)
        let before = try BackupData.capture(repo)
        let days = try repo.widgetStreakDays(now: now, settings: settings)
        XCTAssertEqual(days[0].streak, 1); XCTAssertEqual(days[0].cards, 1)
        XCTAssertEqual(days[1].streak, 1); XCTAssertEqual(days[1].cards, 0)
        XCTAssertEqual(days[2].streak, 0)
        XCTAssertEqual(try BackupData.capture(repo), before)
        var snapshot = try WidgetProjection.make(cards: [], logs: [], settings: WidgetProjectionSettings(settings), now: now, calendar: calendar)
        let legacy = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertNil(legacy.streakDays); XCTAssertNotNil(legacy.point(at: now, timeZone: calendar.timeZone))
        snapshot.streakDays = days
        XCTAssertTrue(snapshot.valid())
        XCTAssertEqual(snapshot.streak(at: now.addingTimeInterval(60), timeZone: calendar.timeZone)?.cards, 0)
        XCTAssertNil(snapshot.streak(at: now, timeZone: TimeZone(identifier: "Asia/Tokyo")!))
        XCTAssertNil(snapshot.streak(at: snapshot.expiresAt, timeZone: calendar.timeZone))
        try repo.undo(now: now)
        XCTAssertEqual(try repo.widgetStreakDays(now: now, settings: settings)[0].streak, 0)
    }

    @MainActor func testStreakSevenDayWindowMatchesCanonicalLongRunAndTimezone() throws {
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true), calendar: calendar)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 5))!
        try repo.initialize(now: now)
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "Q", answer: "A"), now: now)
        let card = try XCTUnwrap(repo.cards().first), scheduler = try ReviewScheduler()
        for offset in -10...0 {
            let date = calendar.date(byAdding: .day, value: offset, to: now)!
            let transition = try scheduler.review(repo.snapshot(card), grade: .good, now: date)
            for sequence in 0..<3 {
                repo.context.insert(StudyReviewLog(card: card, transition: transition, before: card.fsrsPayload,
                    after: try JSONEncoder().encode(transition.after), mode: .mental, durationMs: 0, wasNew: false, sequence: sequence))
            }
        }
        try repo.context.save()
        for zone in ["GMT", "Asia/Tokyo", "America/Los_Angeles"] {
            repo.calendar.timeZone = TimeZone(identifier: zone)!
            for offset in 0...2 {
                let date = calendar.date(byAdding: .day, value: offset, to: now)!
                let actual = try repo.widgetStreakDays(now: date, settings: repo.settings())[0]
                let expected = try repo.achievementProgress(now: date)
                XCTAssertEqual(actual.streak, expected.currentStreak)
                XCTAssertEqual(actual.cards, expected.uniqueCardsToday)
                XCTAssertEqual(actual.studied, expected.studiedToday)
            }
        }
    }

    @MainActor func testThreeThousandCardsDuplicateWidgetProjectionMeasurement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = WidgetSnapshotFile(url: root.appendingPathComponent("widget.json"))
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try repo.initialize(now: now)
        let cards = (0..<3000).map { index in
            QueueCard(id: UUID(), state: "review", due: now.addingTimeInterval(Double(index % 30 + 1) * 3600), createdAt: now, suspended: false)
        }
        let snapshot = try repo.homeSnapshot(now: now, cards: cards, logs: []), settings = try repo.settings()
        var writes = 0
        let publisher = WidgetSnapshotPublisher(file: file, reload: { writes += 1 })
        func publish(force: Bool) async throws {
            var completed = false
            publisher.publish(repository: repo, snapshot: snapshot, settings: settings, now: now, force: force, cards: cards, logs: []) {
                XCTAssertNil($0); completed = true
            }
            for _ in 0..<200 {
                if completed { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("Widget projection did not finish")
        }
        let oldStart = Date()
        for _ in 0..<10 { try await publish(force: true) }
        let forcedMs = Date().timeIntervalSince(oldStart) * 1000
        XCTAssertEqual(writes, 10)
        let suppressedStart = Date()
        for _ in 0..<10 { try await publish(force: false) }
        let suppressedMs = Date().timeIntervalSince(suppressedStart) * 1000
        XCTAssertEqual(writes, 10)
        XCTAssertEqual(publisher.projectionCount, 10)
        print("WIDGET_DUPLICATES cards=3000 requests=10 forced_ms=\(forcedMs) identical_ms=\(suppressedMs) forced_writes=10 identical_writes=0")
    }
    @MainActor func testWidgetCoalescesAndFutureScheduleChangeInvalidatesEqualHomeCounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = WidgetSnapshotFile(url: root.appendingPathComponent("widget.json"))
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try repo.initialize(now: now)
        let cards = [QueueCard(id: UUID(), state: "review", due: now.addingTimeInterval(3600), createdAt: now, suspended: false),
                     QueueCard(id: UUID(), state: "review", due: now.addingTimeInterval(7200), createdAt: now, suspended: false)]
        let snapshot = try repo.homeSnapshot(now: now, cards: cards, logs: [])
        let settings = try repo.settings()
        var reloads = 0, completions = 0
        let publisher = WidgetSnapshotPublisher(file: file, reload: { reloads += 1 })
        func publish(_ input: [QueueCard], force: Bool = false) {
            publisher.publish(repository: repo, snapshot: snapshot, settings: settings, now: now, force: force, cards: input, logs: []) {
                XCTAssertNil($0); completions += 1
            }
        }
        for _ in 0..<10 { publish(cards) }
        for _ in 0..<100 where completions < 10 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(completions, 10); XCTAssertEqual(reloads, 1); XCTAssertEqual(publisher.projectionCount, 1)
        publish(Array(cards.reversed()))
        XCTAssertEqual(publisher.projectionCount, 1)
        // The earliest due date and home counts are identical, but a later
        // timeline point changed. Aggregate-only invalidation would miss it.
        let changed = [cards[0], QueueCard(id: cards[1].id, state: "review", due: now.addingTimeInterval(10800), createdAt: now, suspended: false)]
        publish(changed)
        for _ in 0..<100 where reloads < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(publisher.projectionCount, 2)
        XCTAssertTrue(file.read()?.points.contains { $0.date == now.addingTimeInterval(10800) } == true)
        publish(changed, force: true)
        for _ in 0..<100 where reloads < 3 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(publisher.projectionCount, 3)
        XCTAssertTrue(try repo.logs().isEmpty)
    }
    func testForecastSavedDeadlinesExcludeOverdueNewHiddenAndDuplicates() throws {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 3, minute: 59))!
        let start = StudyDay(calendar: calendar).interval(containing: now).start
        func card(_ due: Date, state: String = "review", suspended: Bool = false, hidden: Date? = nil) -> QueueCard {
            QueueCard(id: UUID(), state: state, due: due, createdAt: start, suspended: suspended, hiddenUntil: hidden)
        }
        let today = card(start), tomorrow = card(now.addingTimeInterval(60))
        let cards = [card(start.addingTimeInterval(-1)), today, today, tomorrow,
                     card(now, state: "new"), card(now, suspended: true), card(now, hidden: now.addingTimeInterval(60))]
        let forecast = try ReviewForecast.widgetSchedule(cards: cards, now: now, calendar: calendar, startHour: 4)
        XCTAssertEqual(forecast.overdue, 1)
        XCTAssertEqual(forecast.days.map(\.count), [1, 1, 0, 0, 0, 0, 0])
        let after = try ReviewForecast.widgetSchedule(cards: cards, now: now.addingTimeInterval(60), calendar: calendar, startHour: 4)
        XCTAssertEqual(after.days[0].date, tomorrow.due)
        XCTAssertEqual(after.overdue, 3) // previous day + today's deadline + newly unhidden
        var snapshot = try WidgetProjection.make(cards: [], logs: [], settings: WidgetProjectionSettings(StudySettings()), now: now, calendar: calendar)
        snapshot.reviewForecast = forecast; snapshot.dailyCardExpiresAt = now.addingTimeInterval(60)
        XCTAssertNotNil(snapshot.forecast(at: now, timeZone: calendar.timeZone))
        XCTAssertNil(snapshot.forecast(at: now.addingTimeInterval(60), timeZone: calendar.timeZone))
        XCTAssertNil(snapshot.forecast(at: now, timeZone: TimeZone(identifier: "Asia/Tokyo")!))
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        let empty = try ReviewForecast.widgetSchedule(cards: [], now: now, calendar: calendar, startHour: 4)
        XCTAssertEqual(empty.days.map(\.count), Array(repeating: 0, count: 7))
    }

    func testForecastRankingUsesOfficialRiskOrderAndFallbackWithoutEarlyReview() throws {
        let now = Date(), scheduler = try ReviewScheduler()
        var payloads: [UUID: Data] = [:]
        func card(days: Int) throws -> QueueCard {
            let date = now.addingTimeInterval(-Double(days) * 86400)
            let transition = try scheduler.review(scheduler.newCard(now: date), grade: .easy, now: date)
            let id = UUID(); payloads[id] = try JSONEncoder().encode(transition.after)
            return QueueCard(id: id, state: "review", due: now.addingTimeInterval(-60), createdAt: date, suspended: false)
        }
        let recent = try card(days: 5), old = try card(days: 50)
        let future = QueueCard(id: UUID(), state: "review", due: now.addingTimeInterval(60), createdAt: now, suspended: false)
        for cards in [[recent, old, future], [future, old, recent]] {
            XCTAssertEqual(WidgetProjection.reviewCardID(cards: cards, logs: [], settings: StudySettings(), payloads: payloads, parameters: nil, now: now, calendar: calendar), old.id)
        }
        XCTAssertNil(WidgetProjection.reviewCardID(cards: [future], logs: [], settings: StudySettings(), payloads: payloads, parameters: nil, now: now, calendar: calendar))
        let earliest = QueueCard(id: UUID(), state: "review", due: now.addingTimeInterval(-3600), createdAt: now, suspended: false)
        XCTAssertEqual(WidgetProjection.reviewCardID(cards: [recent, earliest, old], logs: [], settings: StudySettings(), payloads: payloads, parameters: nil, now: now, calendar: calendar), earliest.id)
    }

    @MainActor func testForecastPublisherScopePauseEditGradeUndoAndReadOnly() async throws {
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true), calendar: calendar)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
        try repo.initialize(now: now)
        let parent = try repo.decks()[0].id
        let child = try repo.createDeck(name: "Child", parentID: parent, now: now)
        try repo.createNote(NoteInput(deckID: child, question: "Selected", answer: "A", tagNames: ["target"]), now: now)
        try repo.createNote(NoteInput(deckID: parent, question: "Excluded", answer: "B"), now: now)
        let tag = try XCTUnwrap(repo.tags().first?.id)
        let scheduler = try ReviewScheduler()
        let saved = try scheduler.review(scheduler.newCard(now: now.addingTimeInterval(-30 * 86400)), grade: .easy, now: now.addingTimeInterval(-30 * 86400)).after
        try repo.transaction {
            for card in try repo.cards() { card.fsrsPayload = try JSONEncoder().encode(saved); card.dueDate = now.addingTimeInterval(-86400) }
        }
        try repo.applyHomeScope(LearningScope(deckID: parent, tagIDs: [tag]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = WidgetSnapshotFile(url: root.appendingPathComponent("widget.json"))
        let publisher = WidgetSnapshotPublisher(file: file, reload: {})
        func publish() async throws -> WidgetReviewForecast {
            let before = try BackupData.capture(repo)
            var finished = false
            publisher.publish(repository: repo, snapshot: try repo.homeSnapshot(now: now), settings: try repo.settings(), now: now, force: false) {
                XCTAssertNil($0); finished = true
            }
            for _ in 0..<200 where !finished { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(finished)
            XCTAssertEqual(try BackupData.capture(repo), before)
            return try XCTUnwrap(file.read()?.forecast(at: now, timeZone: calendar.timeZone))
        }
        let first = try await publish(), id = try XCTUnwrap(first.card?.id)
        XCTAssertEqual(first.overdue, 1); XCTAssertEqual(first.days.map(\.count), Array(repeating: 0, count: 7))
        let noteID = try XCTUnwrap(repo.card(id)?.noteID)
        try repo.updateNote(id: noteID, input: NoteInput(deckID: child, question: "Edited", answer: "A", tagNames: ["target"]), now: now)
        let edited = try await publish(); XCTAssertEqual(edited.card?.question, "Edited"); XCTAssertEqual(edited.card?.id, id)
        try repo.setStudyPaused(deckID: parent, paused: true, now: now)
        let paused = try await publish(); XCTAssertNil(paused.card); XCTAssertEqual(paused.overdue, 0)
        try repo.setStudyPaused(deckID: parent, paused: false, now: now)
        try repo.startWidgetCard(id, now: now)
        XCTAssertEqual(try repo.presentation(now: now)?.card?.cardID, id)
        try repo.updateDraft(revealed: true, now: now); try repo.grade(.easy, now: now)
        let graded = try await publish(); XCTAssertNil(graded.card); XCTAssertEqual(graded.overdue, 0)
        try repo.undo(now: now)
        let undone = try await publish(); XCTAssertEqual(undone.card?.id, id); XCTAssertEqual(undone.overdue, 1)
        try repo.setSuspended(cardID: id, value: true, now: now)
        let suspended = try await publish(); XCTAssertNil(suspended.card); XCTAssertEqual(suspended.overdue, 0)
        try repo.setSuspended(cardID: id, value: false, now: now)
        try repo.deleteNote(id: noteID)
        let deleted = try await publish(); XCTAssertNil(deleted.card); XCTAssertEqual(deleted.overdue, 0)
        XCTAssertNil(try repo.widgetCard(id, now: now))
    }

    func testForecastThreeThousandCardsTenThousandLogs() throws {
        let now = Date(), start = StudyDay(calendar: calendar).interval(containing: now).start
        let cards = (0..<3000).map { index in
            QueueCard(id: UUID(), state: "review", due: start.addingTimeInterval(Double(index % 7) * 86400), createdAt: start, suspended: false)
        }
        let logs = (0..<10000).map { index in QueueLog(cardID: cards[index % cards.count].id, reviewedAt: now.addingTimeInterval(-Double(index)), wasNew: false) }
        let scheduler = try ReviewScheduler(), learned = now.addingTimeInterval(-30 * 86400)
        let payload = try JSONEncoder().encode(scheduler.review(scheduler.newCard(now: learned), grade: .easy, now: learned).after)
        let payloads = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, payload) })
        let began = Date()
        let forecast = try ReviewForecast.widgetSchedule(cards: cards, now: now, calendar: calendar, startHour: 4)
        let selected = WidgetProjection.reviewCardID(cards: cards, logs: logs, settings: StudySettings(), payloads: payloads, parameters: nil, now: now, calendar: calendar)
        XCTAssertEqual(forecast.days.map(\.count).reduce(0, +), 3000); XCTAssertEqual(forecast.overdue, 0)
        XCTAssertNotNil(selected)
        print("WIDGET_FORECAST cards=3000 logs=10000 ms=\(Date().timeIntervalSince(began) * 1000)")
    }

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
        XCTAssertEqual(snapshot.dailyCard?.question, "Private secret")
        XCTAssertFalse(String(decoding: try Data(contentsOf: file.url!), as: UTF8.self).contains("Never shared"))
        let failed = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), widgetSnapshots: WidgetSnapshotPublisher(file: WidgetSnapshotFile(url: nil)))
        XCTAssertNotNil(failed.widgetFailure)
        XCTAssertTrue(failed.perform { try failed.repository.createNote(NoteInput(deckID: failed.repository.decks()[0].id, question: "Q", answer: "A"), now: now) })
        XCTAssertEqual(try failed.repository.notes().count, 1)
        XCTAssertTrue(try failed.repository.logs().isEmpty)
    }
    @MainActor func testDailyCardSelectionPreviewAndTargetedReviewPreserveData() throws {
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true))
        let now = Date()
        try repo.initialize(now: now)
        let deck = try repo.decks()[0].id
        try repo.createNote(NoteInput(deckID: deck, question: "Question", answer: "Answer"), now: now)
        try repo.createNote(NoteInput(deckID: deck, question: "Other", answer: "Other answer"), now: now)
        let cards = try repo.queueCards(), settings = try repo.settings()
        let before = try BackupData.capture(repo)
        let value = try XCTUnwrap(repo.dailyWidgetCard(cards: cards, logs: [], settings: settings, now: now))
        XCTAssertEqual(try repo.dailyWidgetCard(cards: Array(cards.reversed()), logs: [], settings: settings, now: now), value)
        XCTAssertNotNil(try repo.widgetCard(value.id, now: now)?.content.answer)
        XCTAssertEqual(try BackupData.capture(repo), before)
        XCTAssertEqual(WidgetDestination.parse(value.url()), .card(value.id, answer: false))
        XCTAssertEqual(WidgetDestination.parse(value.url(answer: true)), .card(value.id, answer: true))
        XCTAssertNil(WidgetDestination.parse(URL(string: "ankistudy://widget/card/not-a-uuid")!))
        // Choose the second candidate explicitly: normal queue must open that exact ID.
        let target = try XCTUnwrap(repo.dailyWidgetIDs(cards: cards, logs: [], settings: settings, now: now).last)
        try repo.startWidgetCard(target, now: now)
        XCTAssertEqual(try repo.presentation(now: now)?.card?.cardID, target)
        XCTAssertFalse(try XCTUnwrap(repo.presentation(now: now)).answerRevealed)
        XCTAssertTrue(try repo.logs().isEmpty)
        let started = try BackupData.capture(repo)
        XCTAssertThrowsError(try repo.startWidgetCard(value.id, now: now))
        XCTAssertEqual(try BackupData.capture(repo), started)
        try repo.updateDraft(revealed: true, now: now)
        try repo.grade(.good, now: now)
        XCTAssertEqual(try repo.logs().count, 1)
        try repo.undo(now: now)
        XCTAssertTrue(try repo.logs().isEmpty)
        for card in cards {
            XCTAssertEqual(try repo.card(card.id)?.dueDate, card.due)
        }
    }
    @MainActor func testDailyCardStartSaveFailureRollsBack() throws {
        enum Failure: Error { case save }
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true))
        let now = Date()
        try repo.initialize(now: now)
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "Q", answer: "A"), now: now)
        let id = try XCTUnwrap(repo.cards().first?.id)
        let before = try BackupData.capture(repo)
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.startWidgetCard(id, now: now))
        XCTAssertNil(try repo.session())
        XCTAssertEqual(try BackupData.capture(repo), before)
    }
    @MainActor func testDailyCardRespectsQueueFiltersAndScope() throws {
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true))
        let now = Date()
        try repo.initialize(now: now)
        let deck = try repo.decks()[0].id
        let other = try repo.createDeck(name: "Other", now: now)
        try repo.createNote(NoteInput(deckID: deck, question: "Q", answer: "A"), now: now)
        try repo.createNote(NoteInput(deckID: other, question: "Other", answer: "A"), now: now)
        try repo.applyHomeScope(LearningScope(deckID: deck))
        let settings = try repo.settings(), cards = try repo.queueCards()
        let id = try XCTUnwrap(repo.dailyWidgetCard(cards: cards, logs: [], settings: settings, now: now)?.id)
        let blocked = cards.map { value -> QueueCard in
            var value = value
            if value.id == id { value.studyPaused = true }
            return value
        }
        XCTAssertNil(try repo.dailyWidgetCard(cards: blocked, logs: [], settings: settings, now: now))
        let due = cards.map { value -> QueueCard in
            QueueCard(id: value.id, state: value.id == id ? "review" : "new", due: now.addingTimeInterval(-60), createdAt: value.createdAt, suspended: false, noteID: value.noteID)
        }
        XCTAssertEqual(try repo.dailyWidgetIDs(cards: due, logs: [], settings: settings, now: now).first, id)
        XCTAssertNil(try repo.widgetCard(UUID(), now: now))
    }

}
