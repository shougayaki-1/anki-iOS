import Foundation
import SwiftData
import Observation

struct NoteSaveNotice: Identifiable {
    let id = UUID()
    let message: String
}

struct BackupRestoreSummary: Equatable {
    let decks: Int
    let notes: Int
    let cards: Int
    let logs: Int
    let media: Int
    @MainActor init(context: ModelContext) throws {
        decks = try context.fetchCount(FetchDescriptor<Deck>())
        notes = try context.fetchCount(FetchDescriptor<Note>())
        cards = try context.fetchCount(FetchDescriptor<StudyCard>())
        logs = try context.fetchCount(FetchDescriptor<StudyReviewLog>())
        media = try context.fetchCount(FetchDescriptor<MediaAsset>())
    }
    var description: String { "\(decks)デッキ・\(notes)ノート・\(cards)カード・回答履歴\(logs)件・メディア\(media)件" }
}
struct BackupRestoreOutcome: Equatable {
    let summary: BackupRestoreSummary?
    let warning: String?
}

@MainActor @Observable
final class StudyStore {
    var repository: StudyRepository
    let storageLocation: StudyStorageLocation
    var snapshotPolicy = SnapshotPolicy()
    var snapshots: [LocalSnapshot] = []
    var snapshotFailure: String?
    var snapshotFailures = 0
    var snapshotWorking = false
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    var localSnapshots: LocalSnapshots { LocalSnapshots(location: storageLocation) }
    var clock: () -> Date
    var scope = LearningScope()
    var tags: [TagItem] = []
    var decks: [DeckItem] = []
    @ObservationIgnored var libraryReader: LibraryReader
    var counts = HomeCounts()
    var globalCounts = HomeCounts()
    var nextShortDue: Date?
    var nextHomeRefresh = Date.distantFuture
    var newSlotsRemaining = 0
    var homeFailure: String?
    var hasCards = false
    var homeMedianAnswerSeconds: Double?
    @ObservationIgnored private var homeCards: (repository: ObjectIdentifier, revision: Int, cards: [QueueCard])?
    @ObservationIgnored private var homeDayStart: Date?
    @ObservationIgnored private var homeTimeZone: String?
    var settings = StudySettings()
    var sessionAnswerLimit = 20
    var sessionResponseMode = SessionResponseMode.cardDefault
    var review: ReviewPresentation?
    var typedDraftSaveFailed = false
    @ObservationIgnored private var typedDraftJob: Task<Void, Never>?
    @ObservationIgnored private var typedDraftGeneration = 0
    @ObservationIgnored private var pendingTypedDraft: PendingTypedDraft?
    private struct PendingTypedDraft {
        let sessionID: PersistentIdentifier
        let cardID: UUID
        let text: String
    }
    var failure: String?
    var noteSaveNotice: NoteSaveNotice?
    var reviewRefreshFailed = false
    var showingReview = false
    var selectedTab = 0
    var dataRevision = 0
    var mediaDisplayNamespace = UUID()
    var achievementProgress: AchievementProgress?
    var achievementHistory: [AchievementRecord] = []
    var statistics: StudyStatistics?
    var statisticsLoading = false
    var statisticsError: String?
    var statisticsScope = LearningScope()
    @ObservationIgnored private var statisticsReader: StatisticsReader
    @ObservationIgnored private var statisticsTask: Task<Void, Never>?
    @ObservationIgnored private var statisticsGeneration = 0
    @ObservationIgnored private var statisticsRevision = 0
    var notificationPermission = NotificationPermission.unknown
    var widgetFailure: String?
    @ObservationIgnored private let widgetSnapshots: WidgetSnapshotPublisher?
    var notificationFailure: String?
    let notifications: NotificationService
    var scheduledNotificationCount = 0
    let haptics = HapticsService()
    @ObservationIgnored private var notificationJob: Task<Void, Never>?

    init(container: ModelContainer, clock: @escaping () -> Date = Date.init, mediaStore: MediaStore = MediaStore(), storageLocation: StudyStorageLocation = StudyStorageLocation(canonicalStore: StudyStorageLocation.defaultStore), notifications: NotificationService? = nil, widgetSnapshots: WidgetSnapshotPublisher? = nil) throws {
        self.widgetSnapshots = widgetSnapshots
        repository = StudyRepository(container: container, mediaStore: mediaStore)
        statisticsReader = StatisticsReader(container: container)
        libraryReader = LibraryReader(container: container)
        self.clock = clock
        self.storageLocation = storageLocation
        self.notifications = notifications ?? NotificationService()
        do { snapshotPolicy = try localSnapshots.policy(); snapshots = try localSnapshots.list() }
        catch { snapshotPolicy.enabled = false; snapshotFailure = error.localizedDescription }
        try repository.initialize(now: clock())
        scope = try repository.homeScope()
        try reload()
    }

    func reload() throws { try refreshStudy(metadata: true) }

    var sessionStudyPaused = false
    var homeStudyPaused = false
    func toggleStudyPaused(_ id: UUID) {
        guard flushTypedDraft(), let deck = decks.first(where: { $0.id == id }) else { return }
        do { try repository.setStudyPaused(deckID: id, paused: !deck.isStudyPaused, now: clock()) }
        catch { failure = "休止設定を保存できませんでした。\n" + error.localizedDescription; return }
        noteSaveNotice = NoteSaveNotice(message: deck.isStudyPaused ? "学習を再開しました。元の期限を過ぎたカードは復習対象になります。" : "学習を休止しました。カードと履歴、回答下書きとUndoは保持しています。")
        do { try reload() }
        catch { failure = "休止設定は保存済みですが、画面更新に失敗しました。\n" + error.localizedDescription }
    }


    private func refreshStudy(metadata: Bool = false, changed: Bool = true, forceWidget: Bool = false) throws {
        // Invalidate even if post-save display reads fail. A successful mutation
        // must never reuse the material from before that mutation.
        homeCards = nil
        if changed { statisticsRevision += 1 }
        let interval = PerformanceProbe.begin("Store.refreshStudy")
        repository.recordPerformanceCounters("StudyRefresh.before")
        defer {
            repository.recordPerformanceCounters("StudyRefresh.after")
            PerformanceProbe.end(interval)
        }
        do {
            repository.calendar = .current
            let now = clock()
            let cards = try repository.queueCards()
            let savedSettings = metadata ? try repository.settings() : settings
            let logs = try repository.todayQueueLogs(cards: cards, settings: savedSettings, now: now)
            let snapshot = try repository.homeSnapshot(now: now, cards: cards, logs: logs)
            if metadata {
                let deckModels = try repository.decks()
                let paths = LibraryIndex.deckPaths(deckModels)
                let paused = DeckStudyEligibility.pausedIDs(deckModels.map { ($0.id, $0.parentID, $0.isStudyPaused) })
                let decks = deckModels.map { model in
                    var item = DeckItem(id: model.id, name: paths[model.id] ?? model.name, shortName: model.name, parentID: model.parentID)
                    item.isStudyPaused = model.isStudyPaused
                    item.isEffectivelyStudyPaused = paused.contains(model.id)
                    return item
                }
                let tags = try repository.tags().map { TagItem(id: $0.id, name: $0.name) }
                let settings = try repository.settings()
                let answerLimit = try repository.options().sessionAnswerLimit ?? 20
                let review = try repository.presentation(now: now, cards: cards)
                // History scans and FSRS predictions belong to the statistics actor,
                // never to the review/save/home reload path.
                // Publish together only after all reads succeed.
                self.decks = decks; self.tags = tags
                self.sessionResponseMode = try repository.options().sessionResponseMode ?? .cardDefault
                self.settings = settings; self.sessionAnswerLimit = answerLimit; self.review = review
            } else { review = try repository.presentation(now: now, cards: cards) }
            sessionStudyPaused = try repository.session()?.cardID.map { id in cards.first(where: { $0.id == id })?.studyPaused == true } ?? false
            applyPendingTypedDraft()
            if changed {
                statisticsTask?.cancel()
                statisticsGeneration += 1
                statistics = nil
                achievementProgress = nil; achievementHistory = []
                statisticsLoading = false
                statisticsError = nil
                // A visible statistics tab must reload after grade/Undo, edits and restore.
                // Off-screen reports remain lazy so review saves never await the history actor.
                statisticsScope.deckID = statisticsScope.deckID.flatMap { id in decks.contains { $0.id == id } ? id : nil }
                statisticsScope.tagIDs.removeAll { id in !tags.contains { $0.id == id } }
                if selectedTab == 2 { refreshStatistics() }
                dataRevision += 1
            }
            reviewRefreshFailed = false
            homeCards = (ObjectIdentifier(repository), repository.mutationRevision, cards)
            applyHomeSnapshot(snapshot)
            publishWidget(snapshot, force: forceWidget, cards: cards, logs: logs)
            if changed { scheduleNotifications(cards: cards) }
        } catch { homeFailure = error.localizedDescription; throw error }
    }
    private func applyHomeSnapshot(_ snapshot: HomeSnapshot) {
        homeStudyPaused = snapshot.studyPaused
        homeMedianAnswerSeconds = snapshot.medianAnswerSeconds
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
    func refreshHome(reconcileNotifications: Bool = false, at referenceDate: Date? = nil) {
        let interval = PerformanceProbe.begin("Store.refreshHome")
        defer { PerformanceProbe.end(interval) }
        do {
            repository.calendar = .current
            let now = referenceDate ?? clock()
            let cards: [QueueCard]
            if let cached = homeCards, cached.repository == ObjectIdentifier(repository),
               cached.revision == repository.mutationRevision, !repository.context.hasChanges {
                cards = cached.cards
            } else { cards = try repository.queueCards() }
            // A waiting session only writes when a next card becomes available.
            if try repository.advanceWaitingSession(now: now, cards: cards) {
                review = try repository.presentation(now: now)
            }

            let logs = try repository.todayQueueLogs(cards: cards, settings: settings, now: now)
            let snapshot = try repository.homeSnapshot(now: now, cards: cards, logs: logs)
            let changed = homeDayStart != snapshot.dayStart || homeTimeZone != repository.calendar.timeZone.identifier
                || globalCounts.due != snapshot.globalCounts.due
            homeCards = (ObjectIdentifier(repository), repository.mutationRevision, cards)
            applyHomeSnapshot(snapshot)
            publishWidget(snapshot, force: false, cards: cards, logs: logs)
            if reconcileNotifications || changed { scheduleNotifications(cards: cards) }
        } catch { homeCards = nil; homeFailure = error.localizedDescription }
    }
    private func publishWidget(_ snapshot: HomeSnapshot, force: Bool, cards: [QueueCard]? = nil, logs: [QueueLog]? = nil) {
        widgetSnapshots?.publish(repository: repository, snapshot: snapshot, settings: settings, now: clock(), force: force, cards: cards, logs: logs) { [weak self] message in
            self?.widgetFailure = message
        }
    }
    @discardableResult
    func refreshWidget() -> Bool {
        do { try refreshStudy(metadata: true, changed: false, forceWidget: true); return true }
        catch { failure = error.localizedDescription; return false }
    }
    func refreshStatistics() {
        statisticsTask?.cancel()
        statisticsGeneration += 1
        let generation = statisticsGeneration
        statisticsLoading = true
        statisticsError = nil
        let reader = statisticsReader
        let now = clock()
        let calendar = Calendar.current
        let startHour = settings.dayStartHour
        let scope = statisticsScope
        // Includes direct repository writes such as claiming an event, in addition
        // to Store refreshes and failures after a successful save.
        let revision = statisticsRevision &+ repository.mutationRevision
        statisticsTask = Task { [weak self] in
            do {
                let report = try await reader.load(now: now, calendar: calendar,
                                                   startHour: startHour, scope: scope, revision: revision)
                guard !Task.isCancelled, self?.statisticsGeneration == generation else { return }
                self?.statistics = report
                self?.achievementProgress = report.achievements?.progress
                self?.achievementHistory = report.achievements?.history ?? []
                self?.statisticsLoading = false
            } catch {
                guard !Task.isCancelled, self?.statisticsGeneration == generation else { return }
                self?.statisticsError = error.localizedDescription
                self?.achievementProgress = nil
                self?.achievementHistory = []
                self?.statisticsLoading = false
            }
        }
    }

    func updateStatisticsScope(_ scope: LearningScope) {
        statisticsScope = scope
        refreshStatistics()
    }
    func refreshSnapshots() {
        do { snapshots = try localSnapshots.list(); snapshotPolicy = try localSnapshots.policy() }
        catch { snapshotFailure = error.localizedDescription }
    }
    func setSnapshotPolicy(_ value: SnapshotPolicy) {
        do { try localSnapshots.savePolicy(value); snapshotPolicy = value }
        catch { snapshotFailure = error.localizedDescription }
    }
    func automaticSnapshotIfDue() {
        guard snapshotTask == nil, !snapshotWorking,
              localSnapshots.isDue(now: clock(), policy: snapshotPolicy, entries: snapshots) else { return }
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            defer { snapshotTask = nil }
            do { try await createSnapshot(kind: .automatic, reason: "起動・画面復帰") }
            catch {
                if !(error is CancellationError) { snapshotFailures += 1; snapshotFailure = error.localizedDescription }
            }
        }
    }
    /// Call before the mutation; a failed point aborts the operation, leaving the store untouched.
    func createRestorePoint(_ reason: String) async throws {
        if let task = snapshotTask { await task.value }
        try Task.checkCancellation()
        try await createSnapshot(kind: .beforeChange, reason: reason)
    }
    func createSnapshot(kind: SnapshotKind, reason: String) async throws {
        guard !snapshotWorking else { throw SnapshotBusyError() }
        snapshotWorking = true
        defer { snapshotWorking = false }
        let now = clock(), manager = localSnapshots
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let bytes: Data
        if kind == .automatic {
            let source = repository
            let revision = source.mutationRevision
            let displayRevision = dataRevision
            bytes = try await BackupService.exportCommitted(container: repository.context.container,
                mediaStore: repository.mediaStore, now: now, appVersion: version)
            // Discard a read spanning a save or store replacement. The next due check retries.
            guard repository === source, source.mutationRevision == revision, dataRevision == displayRevision else { throw CancellationError() }
        } else {
            bytes = try await BackupService.export(repository: repository, now: now,
                appVersion: version, pruneExpiredAnswers: false)
        }
        try Task.checkCancellation()
        let job = Task.detached(priority: .utility) { try manager.save(bytes, kind: kind, reason: reason, now: now) }
        _ = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
        refreshSnapshots()
        snapshotFailures = 0; snapshotFailure = nil
    }

    func sceneChanged(active: Bool) {
        if !active { Task { await libraryReader.clearContents() } }
        if !active {
            let reader = statisticsReader
            Task { await reader.clearCache() }
        }
        if !active, !flushTypedDraft() { return }
        do {
            if let draft = try repository.session(), (draft.activeSince != nil) != (active && showingReview && draft.cardID != nil) {
                try repository.setSessionActive(active && showingReview, now: clock())
            }
            if active {
                // Shortcuts can save through another context while the app is absent.
                homeCards = nil
                automaticSnapshotIfDue()
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
    func perform(metadata: Bool = true, changed: Bool = true, _ work: () throws -> Void) -> Bool {
        guard flushTypedDraft() else { return false }
        do { try work() }
        catch { failure = error.localizedDescription; return false }
        do { try refreshStudy(metadata: metadata, changed: changed); return true }
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
    func homeCardCount(_ mode: StudyMode) -> Int {
        switch mode {
        case .review: return counts.due
        case .new: return counts.newRemaining
        case .mixed: return counts.due + counts.newRemaining
        }
    }
    func changeSessionResponseMode(_ mode: SessionResponseMode) {
        perform {
            var saved = try repository.options()
            saved.sessionResponseMode = mode
            try repository.updateOptions(saved)
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
        if sessionStudyPaused { return .unavailable }
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
    var homeRecommendation: HomeRecommendation? {
        guard case let .start(mode, count) = homePrimaryAction else { return nil }
        return HomeRecommendation(mode: mode, cardCount: count, answerLimit: sessionAnswerLimit, medianAnswerSeconds: homeMedianAnswerSeconds, scope: scope, responseMode: sessionResponseMode)
    }
    func startRecommended() {
        let interval = PerformanceProbe.begin("Store.startRecommended")
        defer { PerformanceProbe.end(interval) }
        repository.recordPerformanceCounters("Recommended.beforeHome")
        let previous = homeRecommendation
        let referenceDate = clock()
        refreshHome(at: referenceDate)
        repository.recordPerformanceCounters("Recommended.afterHome")
        let hasSession: Bool
        do {
            let checks = PerformanceProbe.begin("Store.recommendedChecks")
            defer { PerformanceProbe.end(checks) }
            let options = try repository.options()
            sessionAnswerLimit = options.sessionAnswerLimit ?? 20
            sessionResponseMode = options.sessionResponseMode ?? .cardDefault
            // Re-read the persisted draft before starting: never replace an interrupted session.
            hasSession = try repository.session() != nil
        } catch { failure = error.localizedDescription; return }
        guard !hasSession else { resume(); return }
        guard let current = homeRecommendation else { return }
        guard previous == current else {
            noteSaveNotice = NoteSaveNotice(message: "学習対象が更新されました。おすすめの内容を確認して開始してください。")
            return
        }
        repository.recordPerformanceCounters("Recommended.beforeStart")
        start(current.mode, policy: current.policy, at: referenceDate)
        repository.recordPerformanceCounters("Recommended.afterStart")
    }
    func completeSession(destination: Int = 0) {
        guard flushTypedDraft() else { return }
        do { try repository.completeSession(now: clock()) }
        catch { failure = error.localizedDescription; return }
        review = nil; showingReview = false; selectedTab = destination
        do { try refreshStudy(changed: false) }
        catch { homeFailure = error.localizedDescription; failure = "学習は終了しましたが、ホームを更新できません。" }
    }
    func startAnotherSession() {
        if perform(metadata: false, changed: false, { try repository.startAnotherSession(now: clock()) }) { showingReview = true }
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
        perform(metadata: false, changed: false) { try repository.applyHomeScope(value) }
    }
    func start(_ mode: StudyMode, policy: ReviewOrderPolicy = .traditional, at referenceDate: Date? = nil) {
        repository.withStudyQueueReuse {
            let interval = PerformanceProbe.begin("Store.start")
            defer { PerformanceProbe.end(interval) }
            if perform(metadata: false, changed: false, {
                repository.recordPerformanceCounters("Start.beforeRepository")
                defer { repository.recordPerformanceCounters("Start.afterRepository") }
                try repository.start(mode: mode, scope: scope, policy: policy, now: referenceDate ?? clock())
            }) {
                let publish = PerformanceProbe.begin("Store.showReview")
                showingReview = true
                PerformanceProbe.end(publish)
                // This measures publication only. SwiftUI/AttributeGraph rendering
                // happens later and must be inspected in the Main Thread trace.
            }
        }
    }
    func resume() {
        repository.withStudyQueueReuse {
            if perform(metadata: false, changed: false, { try repository.resume(now: clock()) }) { showingReview = true }
        }
    }
    func grade(_ grade: ReviewGrade, swipePrepared: Bool = false) {
        repository.withStudyQueueReuse {
            let interval = PerformanceProbe.begin("Store.grade")
            defer { PerformanceProbe.end(interval) }
            guard flushTypedDraft() else { return }
            let previouslyComplete = review?.sessionProgress?.isComplete == true
            do { try repository.grade(grade, now: clock()) }
            catch { failure = "評価を保存できませんでした。評価は確定されていません。\n" + error.localizedDescription; return }
            do { try refreshStudy() }
            catch { review = nil; showingReview = false; failure = "評価は保存済みですが画面を更新できません。再表示してください。\n" + error.localizedDescription; return }
            let finishedSet = !previouslyComplete && review?.sessionProgress?.isComplete == true
            if finishedSet || !swipePrepared {
                haptics.play(finishedSet ? .sessionCompleted : .grade, mode: settings.hapticsMode)
            }
        }
    }
    func undo() {
        repository.withStudyQueueReuse {
            let interval = PerformanceProbe.begin("Store.undo")
            defer { PerformanceProbe.end(interval) }
            guard flushTypedDraft() else { return }
            do { try repository.undo(now: clock()) }
            catch { failure = "評価を取り消せませんでした。学習状態は変更されていません。\n" + error.localizedDescription; return }
            do { try refreshStudy() }
            catch { review = nil; showingReview = false; failure = "評価は取り消し済みですが画面を更新できません。再表示してください。\n" + error.localizedDescription; return }
            haptics.play(.undo, mode: settings.hapticsMode)
        }
    }
    func draft(mode: ResponseMode? = nil, text: String? = nil, revealed: Bool? = nil, swipePrepared: Bool = false) {
        if let text, mode == nil, revealed == nil {
            bufferTypedDraft(text)
            return
        }
        guard flushTypedDraft() else { return }
        do {
            let wasRevealed = review?.answerRevealed == true
            try repository.updateDraft(mode: mode, text: text, revealed: revealed, now: clock())
            if mode != nil || revealed != nil {
                review = try repository.presentation(now: clock())
            } else if let old = review {
                review = ReviewPresentation(card: old.card, mode: old.mode, responseMode: mode ?? old.responseMode,
                                           typedDraft: text ?? old.typedDraft, answerRevealed: revealed ?? old.answerRevealed,
                                           canUndo: old.canUndo, nextShortDue: old.nextShortDue, ordering: old.ordering, orderingUnavailable: old.orderingUnavailable,
                                           emptyState: old.emptyState, sessionProgress: old.sessionProgress,
                                           visibleAnswerTotal: old.visibleAnswerTotal)
            }
            if revealed == true && !wasRevealed && !swipePrepared { haptics.play(.reveal, mode: settings.hapticsMode) }
        } catch { failure = error.localizedDescription }
    }
    private func bufferTypedDraft(_ text: String) {
        guard let cardID = review?.card?.cardID else { return }
        do {
            let sessionID: PersistentIdentifier
            if let pending = pendingTypedDraft, pending.cardID == cardID { sessionID = pending.sessionID }
            else {
                guard let session = try repository.session(), session.cardID == cardID else { throw StudyError.noSession }
                sessionID = session.persistentModelID
            }
            pendingTypedDraft = PendingTypedDraft(sessionID: sessionID, cardID: cardID, text: text)
            applyPendingTypedDraft()
            typedDraftJob?.cancel()
            typedDraftGeneration += 1
            let generation = typedDraftGeneration
            typedDraftJob = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                guard !Task.isCancelled, let self, self.typedDraftGeneration == generation else { return }
                self.flushTypedDraft()
            }
        } catch { failure = error.localizedDescription }
    }
    private func applyPendingTypedDraft() {
        guard let pending = pendingTypedDraft, let old = review, old.card?.cardID == pending.cardID else { return }
        review = ReviewPresentation(card: old.card, mode: old.mode, responseMode: old.responseMode,
                                   typedDraft: pending.text, answerRevealed: old.answerRevealed,
                                   canUndo: old.canUndo, nextShortDue: old.nextShortDue, ordering: old.ordering,
                                   orderingUnavailable: old.orderingUnavailable, emptyState: old.emptyState,
                                   sessionProgress: old.sessionProgress, visibleAnswerTotal: old.visibleAnswerTotal)
    }
    @discardableResult
    func flushTypedDraft() -> Bool {
        typedDraftJob?.cancel(); typedDraftJob = nil
        typedDraftGeneration += 1
        guard let pending = pendingTypedDraft else { return true }
        do {
            guard let session = try repository.session(), session.persistentModelID == pending.sessionID,
                  session.cardID == pending.cardID else { throw StudyError.noSession }
            try repository.updateDraft(text: pending.text, now: clock())
            pendingTypedDraft = nil
            if typedDraftSaveFailed { failure = nil }
            typedDraftSaveFailed = false
            return true
        } catch {
            typedDraftSaveFailed = true
            applyPendingTypedDraft()
            failure = "入力した回答を保存できませんでした。入力は画面に保持しています。再試行してください。\n" + error.localizedDescription
            return false
        }
    }
    // Acknowledges a saved and displayed change for view feedback and announcements.
    @discardableResult
    func ordering(_ action: OrderingAction) -> Bool {
        guard flushTypedDraft() else { return false }
        do {
            let before = review?.answerRevealed == true
            let previousDraft = review?.ordering
            let previousAttempts = previousDraft?.attempts ?? 0
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
            return review?.ordering != previousDraft
        } catch {
            failure = error.localizedDescription
            return false
        }
    }
    func pause() {
        repository.withStudyQueueReuse {
            if perform(metadata: false, changed: false, { try repository.setSessionActive(false, now: clock()) }) { showingReview = false }
        }
    }
    @discardableResult
    func restoreBackup(_ backup: ValidatedBackup) throws -> BackupRestoreOutcome {
        guard flushTypedDraft() else { throw StudyError.noSession }
        notificationJob?.cancel()
        do {
            let container = try BackupService.restore(backup, location: storageLocation, mediaStore: repository.mediaStore, now: clock())
            statisticsTask?.cancel()
            statisticsGeneration += 1
            statistics = nil
            achievementProgress = nil; achievementHistory = []
            statisticsLoading = false
            statisticsError = nil
            statisticsScope = LearningScope()
            statisticsReader = StatisticsReader(container: container)
            libraryReader = LibraryReader(container: container)
            repository = StudyRepository(container: container, mediaStore: repository.mediaStore)
            mediaDisplayNamespace = UUID()
            Task { await DisplayImageLoader.shared.clearCache() }
            showingReview = false
            failure = nil
            var warning: String?
            do { scope = try repository.homeScope(); try reload() }
            catch { warning = "復元は保存済みですが、画面を更新できませんでした。ホームで再表示してください。\n" + error.localizedDescription }
            let summary: BackupRestoreSummary?
            do { summary = try BackupRestoreSummary(context: repository.context) }
            catch {
                summary = nil
                warning = (warning.map { $0 + "\n" } ?? "") + "復元は保存済みですが、件数を確認できませんでした。復元を繰り返す必要はありません。"
            }
            return BackupRestoreOutcome(summary: summary, warning: warning)
        } catch { scheduleNotifications(); throw error }
    }
    func setNotificationEnabled(_ enabled: Bool) async {
        do {
            if enabled { _ = try await notifications.enablePermission() }
            var value = settings; value.notification.enabled = enabled
            perform { try repository.updateSettings(value) }
        } catch { notificationFailure = error.localizedDescription }
    }
    func scheduleNotifications() { scheduleNotifications(cards: nil) }
    private func scheduleNotifications(cards: [QueueCard]?) {
        notificationJob?.cancel()
        notificationJob = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }
                let notificationCards = settings.notification.enabled ? try cards ?? repository.queueCards() : []
                let permission = try await notifications.reconcile(cards: notificationCards, options: settings.notification,
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
        let succeeded = perform(metadata: false, changed: false) {
            if let draft = try repository.session(), draft.cardID == nil {
                try repository.resume(now: clock())
            }
        }
        reviewRefreshFailed = !succeeded
    }
}

private struct SnapshotBusyError: LocalizedError {
    var errorDescription: String? { "バックアップを作成中です。完了後に再試行してください。変更は行っていません。" }
}
