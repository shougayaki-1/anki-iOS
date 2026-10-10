import XCTest
import SwiftData
import UserNotifications
import UIKit
@testable import AnkiIOS

@MainActor
final class QualityRepositoryTests: XCTestCase {
    func testAuthorizedNotificationDiagnosticsAndTestCleanup() async throws {
        guard ProcessInfo.processInfo.environment["ANKI_NOTIFICATION_DIAGNOSTICS"] == "1" else {
            throw XCTSkip("実機のテスト通知診断・後片付けが指定されていません。")
        }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let tests = pending.filter { $0.identifier.hasPrefix("review-test-") }
        let testDelivered = delivered.filter { $0.request.identifier.hasPrefix("review-test-") }
        let earliest = tests.compactMap { ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() }.min()
        print("Notification diagnostics: authorization=\(settings.authorizationStatus.rawValue), alerts=\(settings.alertSetting.rawValue), center=\(settings.notificationCenterSetting.rawValue), scheduledSummary=\(settings.scheduledDeliverySetting.rawValue), testPending=\(tests.count), testDelivered=\(testDelivered.count), nextTestDelay=\(earliest?.timeIntervalSinceNow ?? -1)")
        center.removePendingNotificationRequests(withIdentifiers: tests.map(\.identifier))
        center.removeDeliveredNotifications(withIdentifiers: testDelivered.map { $0.request.identifier })
        let remaining = await center.pendingNotificationRequests()
        XCTAssertFalse(remaining.contains { $0.identifier.hasPrefix("review-test-") })
        XCTAssertEqual(Set(remaining.map(\.identifier)), Set(pending.filter { !$0.identifier.hasPrefix("review-test-") }.map(\.identifier)))
    }
    func testIdentityAssetsAndPrimaryButtonContrast() throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "暗記ノート")
        let icons = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
        XCTAssertEqual(primary["CFBundleIconName"] as? String, "AppIcon")
        for name in ["AccentColor", "SecondaryText", "PrimaryAction", "GradeAgain", "GradeHard", "GradeGood", "GradeEasy"] {
            let color = try XCTUnwrap(UIColor(named: name))
            for style in [UIUserInterfaceStyle.light, .dark] where name != "AccentColor" && name != "SecondaryText" {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
                XCTAssertTrue(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &alpha))
                func linear(_ value: CGFloat) -> Double {
                    let channel = Double(value)
                    if channel <= 0.04045 { return channel / 12.92 }
                    return pow((channel + 0.055) / 1.055, 2.4)
                }
                let red: Double = linear(r) * 0.2126
                let green: Double = linear(g) * 0.7152
                let blue: Double = linear(b) * 0.0722
                let luminance: Double = red + green + blue
                XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 4.5, name)
                XCTAssertEqual(alpha, 1)
            }
        }
    }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    enum Failure: Error { case save }
    func testFailedSaveAndFailedDisplayAfterCommitReportDifferentOutcomes() throws {
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
        try store.repository.createNote(NoteInput(deckID: store.repository.decks()[0].id, question: "Q", answer: "A"), now: now)
        store.start(.new); store.draft(revealed: true)
        let before = try store.repository.cards()[0].fsrsPayload
        store.repository.save = { _ in throw Failure.save }
        store.grade(.good)
        XCTAssertTrue(store.failure?.contains("確定されていません") == true)
        XCTAssertTrue(try store.repository.logs().isEmpty)
        XCTAssertEqual(try store.repository.cards()[0].fsrsPayload, before)
        XCTAssertEqual(store.review?.answerRevealed, true)
        store.repository.save = { context in
            try context.save()
            // Fault injection: the review committed, but unrelated settings cannot be displayed.
            context.insert(try ExtraPreferences(options: StudyOptions(schemaVersion: 99)))
            try context.save()
        }
        store.grade(.good)
        XCTAssertTrue(store.failure?.contains("保存済み") == true)
        XCTAssertEqual(try store.repository.logs().count, 1)
        XCTAssertNotEqual(try store.repository.cards()[0].fsrsPayload, before)
        XCTAssertFalse(store.showingReview); XCTAssertNil(store.review)
    }
    func testDeletedDeckDraftFallbackAndInterruptedRestoreImageCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true), mediaStore: MediaStore(root: root))
        try repo.initialize(now: now)
        let kept = try repo.decks()[0].id, removed = try repo.createDeck(name: "削除する", now: now)
        let input = NoteInput(deckID: removed, question: "編集中", answer: "回答")
        let note = try repo.createNote(input, now: now)
        try repo.saveEditorDraft(key: "new", input: input, now: now)
        try repo.saveEditorDraft(key: "edit:\(note.uuidString)", input: input, now: now)
        try repo.deleteDeck(id: removed, moveNotesTo: nil, now: now)
        XCTAssertEqual(try repo.editorDraft(key: "new")?.question, "編集中")
        XCTAssertEqual(try repo.editorDraft(key: "new")?.deckID, kept)
        XCTAssertNil(try repo.editorDraft(key: "edit:\(note.uuidString)"))
        let prefix = "restored/\(UUID().uuidString)"
        let orphan = try repo.mediaStore.url(for: "\(prefix)/\(UUID().uuidString).jpg")
        try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: orphan)
        let unrelated = try repo.mediaStore.url(for: "restored/readme.txt")
        try Data("keep".utf8).write(to: unrelated)
        try repo.cleanupUnusedMedia()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
    func testTimeZoneChangeAfterDiskRestartOnlyChangesDailyAggregation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Study.store")
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: url))
        let date = ISO8601DateFormatter().date(from: "2026-10-08T03:59:59+09:00")!
        try repo.initialize(now: date)
        var settings = try repo.settings(); settings.dailyNewLimit = 1; try repo.updateSettings(settings)
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "Q", answer: "A"), now: date)
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "Q2", answer: "A2"), now: date)
        try repo.start(mode: .new, now: date); try repo.updateDraft(revealed: true, now: date); try repo.grade(.easy, now: date)
        let state = try repo.cards()[0].fsrsPayload, due = try repo.cards()[0].dueDate
        let reopened = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: url))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        reopened.calendar = calendar
        XCTAssertEqual(try reopened.counts(now: date.addingTimeInterval(1)).newRemaining, 1)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!; reopened.calendar = calendar
        XCTAssertEqual(try reopened.counts(now: date.addingTimeInterval(1)).newRemaining, 0)
        XCTAssertEqual(try reopened.cards()[0].fsrsPayload, state); XCTAssertEqual(try reopened.cards()[0].dueDate, due)
        XCTAssertEqual(try reopened.logs()[0].reviewedAt, date)
    }
    func testExtremeBackupDatesCountersAndSessionDurationAreRejected() throws {
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true))
        try repo.initialize(now: now)
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "Q", answer: "A"), now: now)
        try repo.start(mode: .new, now: now)
        let original = try BackupData.capture(repo)
        var date = original; date.sessions[0].updatedAt = Date(timeIntervalSince1970: 1e100)
        XCTAssertThrowsError(try BackupValidation.validate(date, media: [:]))
        var duration = original; duration.sessions[0].elapsedMs = Int.max
        XCTAssertThrowsError(try BackupValidation.validate(duration, media: [:]))
        let snapshot = try JSONDecoder().decode(SchedulerSnapshot.self, from: original.cards[0].fsrsPayload)
        for (field, number) in [("reps", NSNumber(value: Int.max)), ("stability", NSNumber(value: 1e308)), ("elapsedDays", NSNumber(value: 1e308))] {
            var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.cardData) as? [String: Any])
            raw[field] = number
            let invalid = SchedulerSnapshot(schemaVersion: snapshot.schemaVersion, algorithmVersion: snapshot.algorithmVersion, cardData: try JSONSerialization.data(withJSONObject: raw))
            var data = original; data.cards[0].fsrsPayload = try JSONEncoder().encode(invalid)
            XCTAssertThrowsError(try BackupValidation.validate(data, media: [:]))
        }
        XCTAssertEqual(try repo.cards()[0].fsrsPayload, original.cards[0].fsrsPayload)
    }
}
