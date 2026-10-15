import XCTest
import SwiftData
import UserNotifications
import UIKit
import SwiftUI
@testable import AnkiIOS

@MainActor
final class QualityRepositoryTests: XCTestCase {
    func testGardenCommittedGrowthUndoFailureScopeAndRestart() async throws {
        let container = try PersistenceController.makeStudyContainer(inMemory: true)
        let store = try StudyStore(container: container, clock: { self.now })
        let repo = store.repository, deck = try repo.decks()[0].id
        try repo.createNote(NoteInput(deckID: deck, question: "Garden", answer: "A"), now: now)
        try store.reload()
        func groups() async throws -> [MemoryGrowthGroup] {
            try await StatisticsReader(container: container).load(now: now, calendar: .current, startHour: 4, scope: LearningScope(), revision: repo.mutationRevision).growth
        }
        store.start(.new); store.draft(revealed: true)
        repo.save = { _ in throw Failure.save }
        store.grade(.good)
        XCTAssertTrue(store.gardenGrowth.isEmpty)
        XCTAssertEqual(try repo.logs().count, 0)
        repo.save = { try $0.save() }
        store.grade(.good)
        let grown = try await groups()
        XCTAssertEqual(grown.map { $0.cards.count }, [0, 1, 0, 0])
        let event = store.claimGardenGrowth(groups: grown)
        XCTAssertEqual(event?.from, .seed); XCTAssertEqual(event?.to, .sprout)
        XCTAssertNil(store.claimGardenGrowth(groups: grown)) // Reappearance / refresh.
        let restarted = try StudyStore(container: container, clock: { self.now })
        XCTAssertNil(restarted.claimGardenGrowth(groups: grown))
        store.undo()
        XCTAssertTrue(store.gardenGrowth.isEmpty)
        XCTAssertEqual(try repo.logs().count, 0)
        store.draft(revealed: true); store.grade(.good)
        XCTAssertFalse(store.gardenGrowth.isEmpty)
        store.statisticsScope = LearningScope(deckID: UUID())
        XCTAssertTrue(store.gardenGrowth.isEmpty)
        store.undo(); store.draft(revealed: true); store.grade(.good)
        store.undo()
        XCTAssertNil(store.claimGardenGrowth(groups: grown)) // Even a stale snapshot cannot replay Undo.
        let undone = try await groups()
        XCTAssertEqual(undone.map { $0.cards.count }, [1, 0, 0, 0])
        try repo.transaction { try repo.cards()[0].isSuspended = true }
        let excluded = try await groups()
        XCTAssertEqual(excluded.flatMap(\.cards).count, 0)
        try repo.transaction { try repo.cards()[0].isSuspended = false }
        try repo.setStudyPaused(deckID: deck, paused: true, now: now)
        let paused = try await groups()
        XCTAssertEqual(paused.flatMap(\.cards).count, 0)
    }

    func testGardenLearningToReviewToFlowerAndRegression() async throws {
        var date = now
        let container = try PersistenceController.makeStudyContainer(inMemory: true)
        let store = try StudyStore(container: container, clock: { date })
        let repo = store.repository, deck = try repo.decks()[0].id
        try repo.createNote(NoteInput(deckID: deck, question: "Grow", answer: "A"), now: date)
        try store.reload(); store.start(.new); store.draft(revealed: true); store.grade(.good)
        XCTAssertEqual(store.gardenGrowth.last?.to, .sprout)
        func answer(_ grade: ReviewGrade) throws {
            date = try repo.cards()[0].dueDate.addingTimeInterval(1)
            try repo.start(mode: .review, now: date)
            try store.reload(); store.draft(revealed: true); store.grade(grade)
        }
        try answer(.good)
        XCTAssertEqual(store.gardenGrowth.last?.from, .sprout)
        XCTAssertEqual(store.gardenGrowth.last?.to, .plant)
        for _ in 0..<5 {
            if store.gardenGrowth.last?.to == .flower { break }
            try answer(.easy)
        }
        XCTAssertEqual(store.gardenGrowth.last?.from, .plant)
        XCTAssertEqual(store.gardenGrowth.last?.to, .flower)
        let report = try await StatisticsReader(container: container).load(now: date, calendar: .current, startHour: 4, scope: LearningScope(), revision: repo.mutationRevision)
        XCTAssertEqual(store.claimGardenGrowth(groups: report.growth)?.to, .flower)
        try answer(.again)
        XCTAssertTrue(store.gardenGrowth.isEmpty) // No punishment or stale earlier growth.
    }

    func testGardenScopeAndRenderingAt3000Cards() async throws {
        let container = try PersistenceController.makeStudyContainer(inMemory: true)
        let store = try StudyStore(container: container, clock: { self.now })
        try UITestFixtures.populateGarden(store, scenario: "scale")
        let repo = store.repository, reader = StatisticsReader(container: container)
        let start = ProcessInfo.processInfo.systemUptime
        let report = try await reader.load(now: now, calendar: .current, startHour: 4, scope: LearningScope(), revision: repo.mutationRevision)
        let loaded = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(report.growth.map { $0.cards.count }, [600, 600, 900, 900])
        let counts = report.growth.map { $0.cards.count }
        for _ in 0..<20 {
            let renderer = ImageRenderer(content: MemoryGardenScene(counts: counts).frame(width: 312, height: 180))
            XCTAssertNotNil(renderer.uiImage)
        }
        let rendered = ProcessInfo.processInfo.systemUptime
        let empty = try await reader.load(now: now, calendar: .current, startHour: 4, scope: LearningScope(tagIDs: [UUID()]), revision: repo.mutationRevision)
        XCTAssertEqual(empty.growth.flatMap(\.cards).count, 0)
        let deck = try repo.decks()[0].id
        let filtered = try await reader.load(now: now, calendar: .current, startHour: 4, scope: LearningScope(deckID: deck), revision: repo.mutationRevision)
        XCTAssertEqual(filtered.growth.map { $0.cards.count }, counts)
        let child = try repo.createDeck(name: "Garden child", parentID: deck, now: now)
        try repo.createNote(NoteInput(deckID: child, question: "Tagged", answer: "A", tagNames: ["Garden"]), now: now)
        let tagID = try XCTUnwrap(repo.tags().first).id
        let tagged = try await reader.load(now: now, calendar: .current, startHour: 4, scope: LearningScope(deckID: deck, tagIDs: [tagID]), revision: repo.mutationRevision)
        XCTAssertEqual(tagged.growth.map { $0.cards.count }, [1, 0, 0, 0])
        XCTAssertEqual(tagged.growth.flatMap(\.cards).map(\.title), ["Tagged"])

        print(String(format: "GARDEN_3000 aggregate_ms=%.2f render20_ms=%.2f specimens=40", (loaded-start)*1000, (rendered-loaded)*1000))
    }

    func testReleasedStoreDoesNotRunDeferredNotificationReads() async throws {
        let center = NotificationServiceTests.Center()
        var store: StudyStore? = try StudyStore(
            container: PersistenceController.makeStudyContainer(inMemory: true),
            notifications: NotificationService(center: center))
        weak var releasedStore = store
        store = nil
        XCTAssertNil(releasedStore, "A pending notification debounce must not retain the store")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(center.permissionReads, 0)
        XCTAssertEqual(center.added, 0)
    }

    func testVisibleStatisticsReloadAfterGradeUndoFiltersAndRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("Restored.store"))
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true),
                                   clock: { self.now }, mediaStore: MediaStore(root: root.appendingPathComponent("Media")),
                                   storageLocation: location)
        let repo = store.repository, deck = try repo.decks()[0].id
        try repo.createNote(NoteInput(deckID: deck, question: "Q", answer: "A"), now: now)
        try store.reload()
        XCTAssertNil(store.statistics) // Review/home path stays lazy.
        store.selectedTab = 2
        try store.reload()
        try await awaitStatistics(store)
        XCTAssertEqual(store.statistics?.days[0].answers, 0)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(revealed: true, now: now)
        try repo.grade(.easy, now: now)
        try store.reload()
        try await awaitStatistics(store)
        XCTAssertEqual(store.statistics?.days[0].answers, 1)
        let backup = try BackupArchive.decode(await BackupService.export(repository: repo, now: now, appVersion: "audit"))
        store.updateStatisticsScope(LearningScope(deckID: UUID(), tagIDs: [UUID()]))
        try store.reload() // Invalid selections are removed after edits/restore.
        XCTAssertEqual(store.statisticsScope, LearningScope())
        try await awaitStatistics(store)
        try repo.undo(now: now)
        try store.reload()
        try await awaitStatistics(store)
        XCTAssertEqual(store.statistics?.days[0].answers, 0)
        try store.restoreBackup(backup)
        try await awaitStatistics(store)
        XCTAssertEqual(store.statistics?.days[0].answers, 1)
        store.selectedTab = 0
        try store.reload()
        XCTAssertNil(store.statistics)
        XCTAssertFalse(store.statisticsLoading)
    }

    private func awaitStatistics(_ store: StudyStore) async throws {
        for _ in 0..<200 {
            if !store.statisticsLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.statisticsLoading)
        XCTAssertNil(store.statisticsError)
        XCTAssertNotNil(store.statistics)
    }

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
        XCTAssertEqual(store.statistics?.days.map(\.answers), stats)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(center.permissionReads, notifications)
        try store.reload()
        XCTAssertNil(store.homeFailure) // List content is now loaded only by the library reader.
        do {
            _ = try await store.libraryReader.search("", revision: store.dataRevision, deckIDs: nil)
            XCTFail("Broken content must be reported by the library")
        } catch { }
        // Broken settings fail the lightweight read too, keeping the last good counts.
        repo.save = { try $0.save() }
        var options = try repo.options(); options.schemaVersion = 99
        try repo.updateOptions(options)
        store.refreshHome(); XCTAssertNotNil(store.homeFailure)
        XCTAssertEqual(store.counts.newRemaining, 1)
        options.schemaVersion = 2; try repo.updateOptions(options)
        store.refreshHome(); XCTAssertNil(store.homeFailure)
    }
    func testHomeProjectionReuseInvalidatesAfterMutationFailureAndDeletion() throws {
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now })
        let repo = store.repository
        let note = try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "Q", answer: "A"), now: now)
        try store.reload()
        let projected = repo.queueProjectionCount
        for _ in 0..<3 { store.refreshHome() }
        XCTAssertEqual(repo.queueProjectionCount, projected)
        let card = try XCTUnwrap(repo.cards().first)
        try repo.setSuspended(cardID: card.id, value: true, now: now)
        store.refreshHome()
        XCTAssertEqual(store.counts.newRemaining, 0)
        XCTAssertEqual(repo.queueProjectionCount, projected + 1)
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.setSuspended(cardID: card.id, value: false, now: now))
        store.refreshHome()
        XCTAssertEqual(store.counts.newRemaining, 0)
        XCTAssertEqual(repo.queueProjectionCount, projected + 2)
        repo.save = { try $0.save() }
        try repo.deleteNote(id: note)
        store.refreshHome()
        XCTAssertFalse(store.hasCards)
        XCTAssertNil(store.homeFailure)
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
        #if targetEnvironment(macCatalyst)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String, "AppIcon")
        XCTAssertNotNil(Bundle.main.url(forResource: "AppIcon", withExtension: "icns"))
        #else
        let icons = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
        XCTAssertEqual(primary["CFBundleIconName"] as? String, "AppIcon")
        #endif
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
