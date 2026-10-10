import Foundation
import SwiftData
import Observation

@MainActor @Observable
final class StudyStore {
    var repository: StudyRepository
    let storageLocation: StudyStorageLocation
    var clock: () -> Date
    var scope = LearningScope()
    var tags: [TagItem] = []
    var decks: [DeckItem] = []
    var notes: [NoteItem] = []
    var counts = HomeCounts()
    var globalCounts = HomeCounts()
    var nextShortDue: Date?
    var newSlotsRemaining = 0
    var homeFailure: String?
    var settings = StudySettings()
    var review: ReviewPresentation?
    var failure: String?
    var showingReview = false
    var selectedTab = 0
    var statistics: StudyStatistics?
    var notificationPermission = NotificationPermission.unknown
    var notificationFailure: String?
    let notifications: NotificationService
    var scheduledNotificationCount = 0
    let haptics = HapticsService()
    @ObservationIgnored private var notificationJob: Task<Void, Never>?

    init(container: ModelContainer, clock: @escaping () -> Date = Date.init, mediaStore: MediaStore = MediaStore(), storageLocation: StudyStorageLocation = StudyStorageLocation(canonicalStore: StudyStorageLocation.defaultStore), notifications: NotificationService? = nil) throws {
        repository = StudyRepository(container: container, mediaStore: mediaStore)
        self.clock = clock
        self.storageLocation = storageLocation
        self.notifications = notifications ?? NotificationService()
        try repository.initialize(now: clock())
        scope = try repository.homeScope()
        try reload()
    }

    func reload() throws {
        repository.calendar = .current
        decks = try repository.decks().map { DeckItem(id: $0.id, name: try repository.deckPath($0.id)) }
        scope = try repository.homeScope()
        notes = try repository.noteItems()
        tags = try repository.tags().map { TagItem(id: $0.id, name: $0.name) }
        counts = try repository.scopedCounts(scope: scope, now: clock())
        globalCounts = try repository.counts(now: clock())
        let logs = try repository.queueLogs(), value = try repository.settings()
        let day = StudyDay(calendar: repository.calendar, startHour: value.dayStartHour).interval(containing: clock())
        let consumed = Set(logs.filter { $0.wasNew && $0.reviewedAt >= day.start && $0.reviewedAt < day.end }.map(\.cardID)).count
        newSlotsRemaining = max(0, value.dailyNewLimit - consumed)
        nextShortDue = try repository.scopedQueueCards(scope).filter {
            !$0.suspended && ["learning", "relearning"].contains($0.state) && $0.due > clock()
        }.map(\.due).min()
        homeFailure = nil
        settings = try repository.settings()
        review = try repository.presentation(now: clock())
        statistics = try repository.statistics(now: clock())
        scheduleNotifications()
    }

    @discardableResult
    func perform(_ work: () throws -> Void) -> Bool {
        do { try work() }
        catch { failure = error.localizedDescription; return false }
        do { try reload(); return true }
        catch { homeFailure = error.localizedDescription; failure = "処理は完了しましたが画面を更新できません。再表示してください。\n" + error.localizedDescription; return false }
    }
    func canStart(_ mode: StudyMode) -> Bool {
        guard homeFailure == nil else { return false }
        switch mode {
        case .review: return counts.due > 0
        case .new: return counts.newRemaining > 0
        case .mixed: return counts.due > 0 || counts.newRemaining > 0
        }
    }
    var newAvailabilityMessage: String {
        if counts.newRemaining > 0 { return "今日学べる新規カードは\(counts.newRemaining)枚です。" }
        if newSlotsRemaining == 0 {
            return "今日の新規枠の上限です。学習日の切替は午前\(settings.dayStartHour)時です。"
        }
        if counts.totalNew > 0 { return "今は新規カードを出題できません。同じノートのカードは学習日の切替まで待機します。" }
        return globalCounts.totalNew > 0 ? "ほかの学習対象に未学習カードがあります。" : "未学習カードはありません。"
    }
    var mixedAvailabilityMessage: String {
        if counts.due > 0 && counts.newRemaining > 0 { return StudyMode.mixed.explanation }
        if counts.due > 0 { return "今は復習カードを学習します。" }
        if counts.newRemaining > 0 { return "今は新しいカードを学習します。" }
        return "今はこの条件で学習できるカードがありません。"
    }
    @discardableResult
    func applyScope(_ value: LearningScope) -> Bool {
        perform { try repository.applyHomeScope(value) }
    }
    func start(_ mode: StudyMode) {
        if perform({ try repository.start(mode: mode, scope: scope, now: clock()) }) { showingReview = true }
    }
    func resume() {
        if perform({ try repository.resume(now: clock()) }) { showingReview = true }
    }
    func grade(_ grade: ReviewGrade) {
        let previous = counts.learnedToday
        do { try repository.grade(grade, now: clock()) }
        catch { failure = "評価を保存できませんでした。評価は確定されていません。\n" + error.localizedDescription; return }
        do { try reload() }
        catch { review = nil; showingReview = false; failure = "評価は保存済みですが画面を更新できません。再表示してください。\n" + error.localizedDescription; return }
        let goalReached = settings.dailyGoal.map { previous < $0 && counts.learnedToday >= $0 } ?? false
        haptics.play(goalReached ? .goal : .grade, mode: settings.hapticsMode)
    }
    func undo() {
        do { try repository.undo(now: clock()) }
        catch { failure = "評価を取り消せませんでした。学習状態は変更されていません。\n" + error.localizedDescription; return }
        do { try reload() }
        catch { review = nil; showingReview = false; failure = "評価は取り消し済みですが画面を更新できません。再表示してください。\n" + error.localizedDescription; return }
        haptics.play(.undo, mode: settings.hapticsMode)
    }
    func draft(mode: ResponseMode? = nil, text: String? = nil, revealed: Bool? = nil) {
        do {
            try repository.updateDraft(mode: mode, text: text, revealed: revealed, now: clock())
            if let old = review {
                review = ReviewPresentation(card: old.card, mode: old.mode, responseMode: mode ?? old.responseMode,
                                           typedDraft: text ?? old.typedDraft, answerRevealed: revealed ?? old.answerRevealed,
                                           canUndo: old.canUndo, nextShortDue: old.nextShortDue)
                if revealed == true && !old.answerRevealed { haptics.play(.reveal, mode: settings.hapticsMode) }
            }
        } catch { failure = error.localizedDescription }
    }
    func pause() {
        if perform({ try repository.setSessionActive(false, now: clock()) }) { showingReview = false }
    }
    func restoreBackup(_ backup: ValidatedBackup) throws {
        notificationJob?.cancel()
        do {
            let container = try BackupService.restore(backup, location: storageLocation, mediaStore: repository.mediaStore, now: clock())
            repository = StudyRepository(container: container, mediaStore: repository.mediaStore)
            showingReview = false
            do { scope = try repository.homeScope(); try reload() }
            catch { failure = "復元は保存済みですが、画面の更新に失敗しました: " + error.localizedDescription }
        } catch { scheduleNotifications(); throw error }
    }
    func setNotificationEnabled(_ enabled: Bool) async {
        do {
            if enabled { _ = try await notifications.enablePermission() }
            var value = settings; value.notification.enabled = enabled
            perform { try repository.updateSettings(value) }
        } catch { notificationFailure = error.localizedDescription }
    }
    func scheduleNotifications() {
        notificationJob?.cancel()
        notificationJob = Task {
            do {
                try await Task.sleep(for: .milliseconds(200))
                let permission = try await notifications.reconcile(cards: repository.queueCards(), options: settings.notification,
                                                                    calendar: repository.calendar, now: clock())
                guard !Task.isCancelled else { return }
                notificationPermission = permission; notificationFailure = nil
                scheduledNotificationCount = notifications.scheduledCount
            } catch {
                if !Task.isCancelled { notificationFailure = error.localizedDescription }
            }
        }
    }
    func refreshQueue() {
        perform {
            if let draft = try repository.session(), draft.cardID == nil {
                try repository.resume(now: clock())
            }
        }
    }
}
