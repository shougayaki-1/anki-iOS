import XCTest
import SwiftData
import UserNotifications
import UIKit
@testable import AnkiIOS

@MainActor
final class QualityRepositoryTests: XCTestCase {
    func testHomePollingDoesNotSaveRegenerateContentOrReconcileUnchangedNotifications() async throws {
        var date = now
        let center = NotificationServiceTests.Center()
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { date },
                                   notifications: NotificationService(center: center))
        let repo = store.repository, deck = try store.repository.decks()[0].id
        let note = try repo.createNote(NoteInput(deckID: deck, question: "Q", answer: "A"), now: date)
        try store.reload()
        try await Task.sleep(for: .milliseconds(300))
        let notifications = center.permissionReads
        let stats = store.statistics?.days.map(\.answers)
        // Polling uses metadata, not displayed note content or historical stats.
        try repo.transaction { try repo.notes().first { $0.id == note }?.contentPayload = Data("invalid display content".utf8) }
        repo.save = { _ in throw Failure.save }
        for _ in 0..<3 { date = date.addingTimeInterval(15); store.refreshHome() }
        XCTAssertNil(store.homeFailure); XCTAssertEqual(store.counts.newRemaining, 1)
        XCTAssertEqual(store.notes.first?.content.question, "Q")
        XCTAssertEqual(store.statistics?.days.map(\.answers), stats)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(center.permissionReads, notifications)
        XCTAssertThrowsError(try store.reload())
        XCTAssertNotNil(store.homeFailure); XCTAssertFalse(store.canStart(.new))
        // Broken settings fail the lightweight read too, keeping the last good counts.
        repo.save = { try $0.save() }
        var options = try repo.options(); options.schemaVersion = 99
        try repo.updateOptions(options)
        store.refreshHome(); XCTAssertNotNil(store.homeFailure)
        XCTAssertEqual(store.counts.newRemaining, 1)
        options.schemaVersion = 2; try repo.updateOptions(options)
        store.refreshHome(); XCTAssertNil(store.homeFailure)
    }
    func testHomeSnapshotDueDayBoundaryAndBackupRestorePreserveFilterAndDraft() async throws {
        var date = now
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = MediaStore(root: root.appendingPathComponent("Media"))
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { date }, mediaStore: media)
        let repo = store.repository, deck = try repo.decks()[0].id
        let other = try repo.createDeck(name: "Other", now: date)
        try repo.createNote(NoteInput(deckID: deck, question: "Q", answer: "A"), now: date)
        try repo.start(mode: .new, scope: LearningScope(deckID: deck), now: date)
        try repo.updateDraft(revealed: true, now: date); try repo.grade(.again, now: date)
        try repo.applyHomeScope(LearningScope(deckID: other))
        try store.reload()
        XCTAssertEqual(store.counts.learnedToday, 1); XCTAssertEqual(store.counts.due, 0)
        date = try XCTUnwrap(store.review?.nextShortDue)
        store.refreshHome()
        XCTAssertEqual(store.counts.due, 0); XCTAssertEqual(store.globalCounts.due, 1)
        try repo.resume(now: date)
        try repo.updateDraft(mode: .typing, text: "backup draft", revealed: true, now: date)
        let undo = try repo.session()?.undoLogID
        let backup = try BackupArchive.decode(await BackupService.export(repository: repo, now: date, appVersion: "31"))
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("Restored.store"))
        _ = try BackupService.restore(backup, location: location, mediaStore: media, now: date)
        let restored = try StudyStore(container: PersistenceController.makeStudyContainer(storeURL: location.canonicalStore), clock: { date }, mediaStore: media, storageLocation: location)
        XCTAssertEqual(restored.scope.deckID, other)
        XCTAssertEqual(try restored.repository.scope().deckID, deck)
        XCTAssertEqual(restored.review?.typedDraft, "backup draft"); XCTAssertEqual(restored.review?.answerRevealed, true)
        XCTAssertEqual(try restored.repository.session()?.undoLogID, undo)
        XCTAssertEqual(restored.counts.learnedToday, 1)
        date = StudyDay(calendar: repo.calendar, startHour: store.settings.dayStartHour).interval(containing: date).end
        restored.refreshHome()
        XCTAssertEqual(restored.counts.learnedToday, 0)
        XCTAssertEqual(restored.counts.answerCount, 0)
        XCTAssertEqual(restored.globalCounts.due, 1)
        restored.refreshStatistics()
        for _ in 0..<100 {
            if !restored.statisticsLoading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(restored.statisticsError)
        XCTAssertEqual(restored.statistics?.days.first?.cards, 0)
        try await Task.sleep(for: .milliseconds(300))
    }

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
    func testLegacyReviewOptionsAndSettingsDiskRestartPreserveStudyState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Study.store")
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: url))
        try repo.initialize(now: now)
        let row = try ExtraPreferences(options: StudyOptions())
        row.payload = Data("{\"schemaVersion\":1,\"siblingBuryEnabled\":true}".utf8)
        repo.context.insert(row); try repo.context.save()
        XCTAssertEqual(try repo.settings().reviewAppearance, ReviewAppearance())
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "Q", answer: "A"), now: now)
        try repo.start(mode: .new, now: now); try repo.updateDraft(revealed: true, now: now); try repo.grade(.good, now: now)
        let cards = try repo.cards().map { ($0.id, $0.fsrsPayload, $0.dueDate) }, logs = try repo.logs().map(\.id)
        var settings = try repo.settings()
        settings.reviewAppearance = ReviewAppearance(gesturesEnabled: true, textSize: .larger, imageDisplay: .compact, answerFirst: true, animationsEnabled: false)
        try repo.updateSettings(settings)
        let reopened = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: url))
        XCTAssertEqual(try reopened.settings(), settings)
        let actual = try reopened.cards()
        XCTAssertEqual(actual.count, cards.count)
        for (id, fsrs, due) in cards {
            let card = try XCTUnwrap(actual.first { $0.id == id })
            XCTAssertEqual(card.fsrsPayload, fsrs); XCTAssertEqual(card.dueDate, due)
        }
        XCTAssertEqual(try reopened.logs().map(\.id), logs)
        XCTAssertThrowsError(try JSONDecoder().decode(StudyOptions.self, from: Data("{\"schemaVersion\":2,\"siblingBuryEnabled\":true,\"reviewAppearance\":{\"gesturesEnabled\":true,\"textSize\":\"bad\",\"imageDisplay\":\"hidden\",\"answerFirst\":false,\"animationsEnabled\":true}}".utf8)))
    }
    func testTextPaletteContrastAgainstSystemSurfaces() throws {
        func luminance(_ color: UIColor) -> Double {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
            func linear(_ v: CGFloat) -> Double {
                let c = Double(v)
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return linear(r) * 0.2126 + linear(g) * 0.7152 + linear(b) * 0.0722
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            for color in [try XCTUnwrap(UIColor(named: "SecondaryText")), try XCTUnwrap(UIColor(named: "AccentColor")), UIColor.label] {
                for surface in [UIColor.systemGroupedBackground, UIColor.secondarySystemGroupedBackground] {
                    let text = luminance(color.resolvedColor(with: traits)), background = luminance(surface.resolvedColor(with: traits))
                    XCTAssertGreaterThanOrEqual((max(text, background) + 0.05) / (min(text, background) + 0.05), 4.5)
                }
            }
        }
    }
    func testIdentityAssetsAndPrimaryButtonContrast() throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "暗記ノート")
        let icons = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
        XCTAssertEqual(primary["CFBundleIconName"] as? String, "AppIcon")
        func luminance(_ color: UIColor, traits: UITraitCollection) -> Double {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a))
            func linear(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return linear(r) * 0.2126 + linear(g) * 0.7152 + linear(b) * 0.0722
        }
        let secondary = try XCTUnwrap(UIColor(named: "SecondaryText"))
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let foreground = luminance(secondary, traits: traits)
            for background in [UIColor.systemBackground, .systemGroupedBackground, .secondarySystemGroupedBackground] {
                let back = luminance(background, traits: traits)
                XCTAssertGreaterThanOrEqual((max(foreground, back) + 0.05) / (min(foreground, back) + 0.05), 4.5)
            }
        }
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
