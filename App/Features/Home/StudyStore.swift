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
    var nextHomeRefresh = Date.distantFuture
    var newSlotsRemaining = 0
    var homeFailure: String?
    var hasCards = false
    @ObservationIgnored private var homeDayStart: Date?
    @ObservationIgnored private var homeTimeZone: String?
    var settings = StudySettings()
    var sessionAnswerLimit = 20
    var review: ReviewPresentation?
    var failure: String?
    var reviewRefreshFailed = false
    var showingReview = false
    var selectedTab = 0
    var statistics: StudyStatistics?
    var statisticsLoading = false
    var statisticsError: String?
    var statisticsScope = LearningScope()
    @ObservationIgnored private var statisticsReader: StatisticsReader
    @ObservationIgnored private var statisticsTask: Task<Void, Never>?
    @ObservationIgnored private var statisticsGeneration = 0
    var notificationPermission = NotificationPermission.unknown
    var notificationFailure: String?
    let notifications: NotificationService
    var scheduledNotificationCount = 0
    let haptics = HapticsService()
    @ObservationIgnored private var notificationJob: Task<Void, Never>?

    init(container: ModelContainer, clock: @escaping () -> Date = Date.init, mediaStore: MediaStore = MediaStore(), storageLocation: StudyStorageLocation = StudyStorageLocation(canonicalStore: StudyStorageLocation.defaultStore), notifications: NotificationService? = nil) throws {
        repository = StudyRepository(container: container, mediaStore: mediaStore)
        statisticsReader = StatisticsReader(container: container)
        self.clock = clock
        self.storageLocation = storageLocation
        self.notifications = notifications ?? NotificationService()
        try repository.initialize(now: clock())
        scope = try repository.homeScope()
        try reload()
    }

    func reload() throws {
        do {
            repository.calendar = .current
            let now = clock()
            let snapshot = try repository.homeSnapshot(now: now)
            let decks = try repository.decks().map { DeckItem(id: $0.id, name: try repository.deckPath($0.id), shortName: $0.name, parentID: $0.parentID) }
            let notes = try repository.noteItems()
            let tags = try repository.tags().map { TagItem(id: $0.id, name: $0.name) }
            let settings = try repository.settings()
            let answerLimit = try repository.options().sessionAnswerLimit ?? 20
            let review = try repository.presentation(now: now)
            // History scans and FSRS predictions belong to the statistics actor,
            // never to the review/save/home reload path.
            // Publish together only after all reads succeed.
            self.decks = decks; self.notes = notes; self.tags = tags
            self.settings = settings; self.sessionAnswerLimit = answerLimit; self.review = review
            statisticsTask?.cancel()
            statisticsGeneration += 1
            statistics = nil
            statisticsLoading = false
            statisticsError = nil
            // A visible statistics tab must reload after grade/Undo, edits and restore.
            // Off-screen reports remain lazy so review saves never await the history actor.
            statisticsScope.deckID = statisticsScope.deckID.flatMap { id in decks.contains { $0.id == id } ? id : nil }
            statisticsScope.tagIDs.removeAll { id in !tags.contains { $0.id == id } }
            if selectedTab == 2 { refreshStatistics() }
            reviewRefreshFailed = false
            applyHomeSnapshot(snapshot)
            scheduleNotifications()
        } catch { homeFailure = error.localizedDescription; throw error }
    }
    private func applyHomeSnapshot(_ snapshot: HomeSnapshot) {
        if scope != snapshot.scope { scope = snapshot.scope }
        if counts != snapshot.counts { counts = snapshot.counts }
        if globalCounts != snapshot.globalCounts { globalCounts = snapshot.globalCounts }
        if nextShortDue != snapshot.nextShortDue { nextShortDue = snapshot.nextShortDue }
        if newSlotsRemaining != snapshot.newSlotsRemaining { newSlotsRemaining = snapshot.newSlotsRemaining }
        if hasCards != snapshot.hasCards { hasCards = snapshot.hasCards }
        if nextHomeRefresh != snapshot.nextRefresh { nextHomeRefresh = snapshot.nextRefresh }
        homeDayStart = snapshot.dayStart; homeTimeZone = repository.calendar.timeZone.identifier
        homeFailure = nil
    }
    func refreshHome(reconcileNotifications: Bool = false) {
        do {
            repository.calendar = .current
            let now = clock()
            // A waiting session only writes when a next card becomes available.
            if try repository.advanceWaitingSession(now: now) {
                review = try repository.presentation(now: now)
            }

            let snapshot = try repository.homeSnapshot(now: now)
            let changed = homeDayStart != snapshot.dayStart || homeTimeZone != repository.calendar.timeZone.identifier
                || globalCounts.due != snapshot.globalCounts.due
            applyHomeSnapshot(snapshot)
            if reconcileNotifications || changed { scheduleNotifications() }
        } catch { homeFailure = error.localizedDescription }
    }
    func refreshStatistics() {
        statisticsTask?.cancel()
        statisticsGeneration += 1
        let generation = statisticsGeneration
        statisticsLoading = true
        statisticsError = nil
        let reader = statisticsReader
        let now = clock()
        let calendar = repository.calendar
        let startHour = settings.dayStartHour
        let scope = statisticsScope
        statisticsTask = Task { [weak self] in
            do {
                let report = try await reader.load(now: now, calendar: calendar,
                                                   startHour: startHour, scope: scope)
                guard !Task.isCancelled, self?.statisticsGeneration == generation else { return }
                self?.statistics = report
                self?.statisticsLoading = false
            } catch {
                guard !Task.isCancelled, self?.statisticsGeneration == generation else { return }
                self?.statisticsError = error.localizedDescription
                self?.statisticsLoading = false
            }
        }
    }

    func updateStatisticsScope(_ scope: LearningScope) {
        statisticsScope = scope
        refreshStatistics()
    }
    func sceneChanged(active: Bool) {
        do {
            if let draft = try repository.session(), (draft.activeSince != nil) != (active && showingReview && draft.cardID != nil) {
                try repository.setSessionActive(active && showingReview, now: clock())
            }
            if active {
                refreshHome(reconcileNotifications: true)
                if selectedTab == 2 { refreshStatistics() }
                if showingReview { refreshQueue() }
            }
        } catch { failure = error.localizedDescription }
    }

    @discardableResult
    func updateSettings(_ edit: (inout StudySettings) -> Void) -> Bool {
        var value = settings
        edit(&value)
        do { try repository.updateSettings(value) }
        catch { failure = error.localizedDescription; return false }
        // Publish the committed settings even if a later screen refresh fails.
        settings = value
        do { try reload() }
        catch {
            homeFailure = error.localizedDescription
            failure = "設定は保存しましたが画面を更新できません。再表示してください。\n" + error.localizedDescription
        }
        return true
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
    func changeSessionAnswerLimit(_ limit: Int) {
        guard [0, 10, 20, 30].contains(limit) else { failure = "回答数を選択し直してください。"; return }
        perform {
            var saved = try repository.options()
            saved.sessionAnswerLimit = limit
            try repository.updateOptions(saved)
        }
    }

    var homePrimaryAction: HomePrimaryAction {
        guard homeFailure == nil else { return .unavailable }
        if let review {
            if review.card != nil { return .resume(review.mode) }
            if review.sessionProgress?.isComplete == true { return .complete }
            if let next = review.nextShortDue { return .waiting(next) }
            return .complete
        }
        if !hasCards { return .addCards }
        if counts.due > 0 { return .start(.review, counts.due) }
        if counts.newRemaining > 0 { return .start(.new, counts.newRemaining) }
        return .unavailable
    }
    func completeSession(destination: Int = 0) {
        do { try repository.completeSession(now: clock()) }
        catch { failure = error.localizedDescription; return }
        review = nil; showingReview = false; selectedTab = destination
        do { try reload() }
        catch { homeFailure = error.localizedDescription; failure = "学習は終了しましたが、ホームを更新できません。" }
    }
    func startAnotherSession() {
        if perform({ try repository.startAnotherSession(now: clock()) }) { showingReview = true }
    }

    var isNewLimitReached: Bool {
        homeFailure == nil && counts.eligibleNew > 0 && counts.newRemaining == 0
    }
    var studyDayBoundaryMessage: String {
        let hour = settings.dayStartHour
        return "学習日の切替：\(hour < 12 ? "午前" : "午後")\(hour < 12 ? hour : hour - 12)時"
    }
    var newAvailabilityMessage: String {
        if counts.newRemaining > 0 { return "今日学べる新規カードは\(counts.newRemaining)枚です。" }
        if counts.totalNew == 0 {
            if counts.suspendedNew > 0 { return "現在のフィルター内の未学習カードは停止中です。ライブラリで停止を解除できます。" }
            if globalCounts.totalNew > 0 { return "ほかの学習対象に未学習カードがあります。" }
            if nextShortDue != nil { return "未学習カードはありません。短期復習の期限を待っています。" }
            return "未学習カードはありません。"
        }
        if counts.eligibleNew == 0 {
            return "現在のフィルター内の未学習カードは兄弟カードの同日抑制で待機中です。\(studyDayBoundaryMessage)"
        }
        if isNewLimitReached {
            if newSlotsRemaining > 0 { return "デッキまたは親デッキの新規上限に達しました。ライブラリ > デッキ管理 > デッキ編集で確認できます。\(studyDayBoundaryMessage)" }
            return "今日の新規学習は上限（\(settings.dailyNewLimit)枚）に達しました。\(studyDayBoundaryMessage)"
        }
        return "今は新規カードを出題できません。"
    }
    var newLimitRemainingMessage: String {
        var message = "未学習カードはあと\(globalCounts.totalNew)枚（全デッキ・停止中を除く）。"
        if scope != LearningScope() {
            message += "現在のフィルター内は\(counts.totalNew)枚です。"
        }
        let buried = counts.totalNew - counts.eligibleNew
        if buried > 0 { message += "うち\(buried)枚は兄弟カードの同日抑制で待機中です。" }
        if counts.suspendedNew > 0 { message += "別に停止中の未学習カードが\(counts.suspendedNew)枚あります（現在のフィルター内）。" }
        return message
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
        let previouslyComplete = review?.sessionProgress?.isComplete == true
        do { try repository.grade(grade, now: clock()) }
        catch { failure = "評価を保存できませんでした。評価は確定されていません。\n" + error.localizedDescription; return }
        do { try reload() }
        catch { review = nil; showingReview = false; failure = "評価は保存済みですが画面を更新できません。再表示してください。\n" + error.localizedDescription; return }
        let finishedSet = !previouslyComplete && review?.sessionProgress?.isComplete == true
        haptics.play(finishedSet ? .goal : .grade, mode: settings.hapticsMode)
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
            let wasRevealed = review?.answerRevealed == true
            try repository.updateDraft(mode: mode, text: text, revealed: revealed, now: clock())
            if mode != nil || revealed != nil {
                review = try repository.presentation(now: clock())
            } else if let old = review {
                review = ReviewPresentation(card: old.card, mode: old.mode, responseMode: mode ?? old.responseMode,
                                           typedDraft: text ?? old.typedDraft, answerRevealed: revealed ?? old.answerRevealed,
                                           canUndo: old.canUndo, nextShortDue: old.nextShortDue, ordering: old.ordering, orderingUnavailable: old.orderingUnavailable,
                                           emptyState: old.emptyState, sessionProgress: old.sessionProgress)
            }
            if revealed == true && !wasRevealed { haptics.play(.reveal, mode: settings.hapticsMode) }
        } catch { failure = error.localizedDescription }
    }
    func ordering(_ action: OrderingAction) {
        do {
            let before = review?.answerRevealed == true
            let previousAttempts = review?.ordering?.attempts ?? 0
            try repository.updateOrdering(action, now: clock())
            review = try repository.presentation(now: clock())
            if case .check = action, let state = review?.ordering,
               state.attempts > previousAttempts, let result = state.result {
                // One persisted verdict = one distinct feedback; do not also fire reveal.
                haptics.play(result == .correct ? .orderingCorrect : .orderingIncorrect,
                             mode: settings.hapticsMode)
            } else if !before && review?.answerRevealed == true {
                haptics.play(.reveal, mode: settings.hapticsMode)
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
            statisticsTask?.cancel()
            statisticsGeneration += 1
            statistics = nil
            statisticsLoading = false
            statisticsError = nil
            statisticsScope = LearningScope()
            statisticsReader = StatisticsReader(container: container)
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
        notificationJob = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }
                let permission = try await notifications.reconcile(cards: repository.queueCards(), options: settings.notification,
                                                                    calendar: repository.calendar, now: clock())
                guard !Task.isCancelled else { return }
                notificationPermission = permission; notificationFailure = nil
                scheduledNotificationCount = notifications.scheduledCount
            } catch {
                if !Task.isCancelled { self?.notificationFailure = error.localizedDescription }
            }
        }
    }
    func refreshQueue() {
        let succeeded = perform {
            if let draft = try repository.session(), draft.cardID == nil {
                try repository.resume(now: clock())
            }
        }
        reviewRefreshFailed = !succeeded
    }
}
