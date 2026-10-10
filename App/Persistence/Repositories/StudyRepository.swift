import Foundation
import SwiftData

extension PersistenceController {
    static func makeStudyContainer(storeURL: URL? = nil, inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: StudySchemaV3.self)
        let config: ModelConfiguration
        if let storeURL {
            config = ModelConfiguration("Study", schema: schema, url: try StudyStorageLocation(canonicalStore: storeURL).activeStore(), cloudKitDatabase: .none)
        } else if inMemory {
            config = ModelConfiguration("Study", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            let directory = URL.applicationSupportDirectory.appendingPathComponent("Study")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            config = ModelConfiguration("Study", schema: schema,
                                        url: try StudyStorageLocation(canonicalStore: directory.appendingPathComponent("Study.store")).activeStore(), cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: StudyMigrationPlan.self, configurations: [config])
    }
}

@MainActor
final class StudyRepository {
    let context: ModelContext
    var calendar: Calendar
    var mediaStore: MediaStore
    var save: (ModelContext) throws -> Void

    init(container: ModelContainer, calendar: Calendar = .current, mediaStore: MediaStore = MediaStore(),
         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        context = ModelContext(container); context.autosaveEnabled = false
        self.calendar = calendar; self.save = save; self.mediaStore = mediaStore
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        do {
            let result = try body()
            try save(context)
            return result
        } catch {
            context.rollback()
            throw error
        }
    }

    func initialize(now: Date) throws {
        try transaction {
            if try decks().isEmpty { context.insert(Deck(name: "マイデッキ", now: now)) }
            if try context.fetch(FetchDescriptor<StudyPreferences>()).isEmpty {
                context.insert(StudyPreferences())
            }
            // Process restart must not count time spent while the app was absent.
            if let draft = try session() { draft.activeSince = nil }
        }
    }

    func decks() throws -> [Deck] {
        try context.fetch(FetchDescriptor<Deck>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]))
    }
    func notes() throws -> [Note] { try context.fetch(FetchDescriptor<Note>()) }
    func cards() throws -> [StudyCard] { try context.fetch(FetchDescriptor<StudyCard>()) }
    func logs() throws -> [StudyReviewLog] {
        try context.fetch(FetchDescriptor<StudyReviewLog>(sortBy: [SortDescriptor(\.sequence)]))
    }
    func session() throws -> SessionDraft? { try context.fetch(FetchDescriptor<SessionDraft>()).first }
    func preferences() throws -> StudyPreferences {
        guard let value = try context.fetch(FetchDescriptor<StudyPreferences>()).first else { throw StudyError.missingRecord }
        return value
    }
    func settings() throws -> StudySettings {
        let p = try preferences(), options = try options()
        return StudySettings(desiredRetention: p.desiredRetention, dailyNewLimit: p.dailyNewLimit,
                             dailyGoal: p.dailyGoal, dayStartHour: p.dayStartHour, siblingBuryEnabled: options.siblingBuryEnabled,
                             notification: options.notification ?? NotificationOptions(), hapticsMode: options.hapticsMode ?? .standard,
                             reviewAppearance: options.reviewAppearance ?? ReviewAppearance())
    }
    func updateSettings(_ value: StudySettings) throws {
        guard (0.8...0.97).contains(value.desiredRetention), StudySettings.newLimitRange.contains(value.dailyNewLimit),
              StudySettings.dayStartRange.contains(value.dayStartHour), (0...23).contains(value.notification.hour), (0...59).contains(value.notification.minute), value.dailyGoal == nil || StudySettings.goalRange.contains(value.dailyGoal!) else {
            throw StudyError.invalidContent
        }
        try transaction {
            let p = try preferences()
            p.desiredRetention = value.desiredRetention; p.dailyNewLimit = value.dailyNewLimit
            p.dailyGoal = value.dailyGoal; p.dayStartHour = value.dayStartHour
            var options = try options(); options.schemaVersion = 2; options.siblingBuryEnabled = value.siblingBuryEnabled
            options.notification = value.notification; options.hapticsMode = value.hapticsMode
            options.reviewAppearance = value.reviewAppearance
            if let row = try context.fetch(FetchDescriptor<ExtraPreferences>()).first {
                row.payload = try JSONEncoder().encode(options)
            } else { context.insert(try ExtraPreferences(options: options)) }
        }
    }

    @discardableResult
    func createDeck(name: String, parentID: UUID? = nil, now: Date) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StudyError.invalidContent }
        return try transaction {
            if let parentID, try !decks().contains(where: { $0.id == parentID }) { throw StudyError.missingRecord }
            let deck = Deck(name: name, now: now); deck.parentID = parentID
            context.insert(deck); return deck.id
        }
    }

    func validate(_ input: NoteInput) throws -> Data {
        if let imageID = input.imageID { guard try assets().contains(where: { $0.id == imageID }) else { throw StudyError.missingRecord } }
        guard !input.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ([.cloze, .imageOcclusion].contains(input.kind) || !input.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else { throw StudyError.invalidContent }
        guard try decks().contains(where: { $0.id == input.deckID }) else { throw StudyError.missingRecord }
        let content = TextContent(question: input.question, answer: input.answer,
                                  explanation: input.explanation, reverseEnabled: input.reverseEnabled,
                                  imageID: input.imageID, masks: input.masks, hideAllMasks: input.hideAllMasks)
        _ = try CardGeneration.variants(kind: input.kind, content: content)
        return try JSONEncoder().encode(content)
    }

    @discardableResult
    func createNote(_ input: NoteInput, clearingDraft key: String? = nil, now: Date) throws -> UUID {
        let content = try validate(input)
        let scheduler = try ReviewScheduler(desiredRetention: settings().desiredRetention)
        let payload = try JSONEncoder().encode(scheduler.newCard(now: now))
        return try transaction {
            let note = Note(input: input, content: content, now: now)
            note.tagIDs = try tagIDs(for: input.tagNames)
            context.insert(note)
            let value = try JSONDecoder().decode(TextContent.self, from: content)
            for key in try CardGeneration.variants(kind: input.kind, content: value) {
                context.insert(StudyCard(noteID: note.id, variantKey: key, payload: payload, now: now))
            }
            try removeEditorDraftInTransaction(key: key)
            return note.id
        }
    }

    func updateNote(id: UUID, input: NoteInput, resetHistory: Bool = false, clearingDraft key: String? = nil, now: Date) throws {
        let content = try validate(input)
        try transaction {
            guard let note = try notes().first(where: { $0.id == id }) else { throw StudyError.missingRecord }
            note.deckID = input.deckID; note.type = input.kind.rawValue; note.contentPayload = content
            note.defaultResponseMode = input.responseMode.rawValue; note.updatedAt = now
            note.tagIDs = try tagIDs(for: input.tagNames)
            let value = try JSONDecoder().decode(TextContent.self, from: content)
            let variants = try CardGeneration.variants(kind: input.kind, content: value)
            let existing = try cards().filter { $0.noteID == id }
            let payload = try JSONEncoder().encode(ReviewScheduler(desiredRetention: settings().desiredRetention).newCard(now: now))
            for card in existing {
                if !variants.contains(card.variantKey) {
                    if let draft = try session(), draft.cardID == card.id { draft.cardID = nil; draft.typedDraft = ""; draft.answerRevealed = false }
                    context.delete(card)
                } else if resetHistory {
                    card.fsrsPayload = payload; card.dueDate = now; card.updatedAt = now
                }
            }
            for key in variants where !existing.contains(where: { $0.variantKey == key }) {
                context.insert(StudyCard(noteID: id, variantKey: key, payload: payload, now: now))
            }
            // Historical logs remain even when a variant is removed.
            try removeEditorDraftInTransaction(key: key)
            if let draft = try session(), let cardID = draft.cardID,
               try cards().contains(where: { $0.id == cardID && $0.noteID == id }) {
                draft.typedDraft = ""; draft.answerRevealed = false; draft.activeSince = now; draft.elapsedMs = 0
                draft.undoLogID = nil
            }
        }
    }

    func deleteNote(id: UUID) throws {
        try transaction {
            let removed = try cards().filter { $0.noteID == id }
            let ids = Set(removed.map(\.id))
            if let draft = try session() {
                if let cardID = draft.cardID, ids.contains(cardID) {
                    draft.cardID = nil; draft.typedDraft = ""; draft.answerRevealed = false; draft.activeSince = nil
                }
                if let logID = draft.undoLogID, try logs().contains(where: { $0.id == logID && ids.contains($0.cardID) }) {
                    draft.undoLogID = nil
                }
            }
            for card in removed { context.delete(card) }
            if let note = try notes().first(where: { $0.id == id }) { context.delete(note) }
            try removeEditorDraftInTransaction(key: "edit:\(id.uuidString)")
            // ReviewLog is intentionally retained even after content deletion.
        }
    }

    func setSuspended(cardID: UUID, value: Bool, now: Date) throws {
        try transaction {
            guard let card = try cards().first(where: { $0.id == cardID }) else { throw StudyError.missingRecord }
            card.isSuspended = value; card.updatedAt = now
            if let draft = try session(), draft.cardID == cardID, value {
                draft.cardID = nil; draft.typedDraft = ""; draft.answerRevealed = false
            }
        }
    }

    func snapshot(_ card: StudyCard) throws -> SchedulerSnapshot {
        try JSONDecoder().decode(SchedulerSnapshot.self, from: card.fsrsPayload)
    }

    func noteItems(cardID: UUID? = nil) throws -> [NoteItem] {
        let scheduler = try ReviewScheduler()
        let noteMap = Dictionary(uniqueKeysWithValues: try notes().map { ($0.id, $0) })
        let deckMap = Dictionary(uniqueKeysWithValues: try decks().map { ($0.id, try deckPath($0.id)) })
        let tagMap = Dictionary(uniqueKeysWithValues: try tags().map { ($0.id, $0.name) })
        return try cards().filter { cardID == nil || $0.id == cardID }.sorted { $0.createdAt > $1.createdAt }.map { card in
            guard let note = noteMap[card.noteID], let kind = NoteKind(rawValue: note.type),
                  let mode = ResponseMode(rawValue: note.defaultResponseMode) else { throw StudyError.missingRecord }
            let content = try JSONDecoder().decode(TextContent.self, from: note.contentPayload)
            guard (1...2).contains(content.schemaVersion) else { throw StudyError.unsupportedContent }
            return NoteItem(noteID: note.id, cardID: card.id, deckID: note.deckID,
                            deckName: deckMap[note.deckID] ?? "", kind: kind,
                            content: try CardGeneration.displayed(kind: kind, content: content, variant: card.variantKey),
                            sourceContent: content, variantKey: card.variantKey,
                            responseMode: mode, summary: try scheduler.summary(snapshot(card)), isSuspended: card.isSuspended, tagNames: note.tagIDs.compactMap { tagMap[$0] }, tagIDs: note.tagIDs)
        }
    }

    func queueCards() throws -> [QueueCard] {
        let scheduler = try ReviewScheduler()
        return try cards().map { card in
            let state = try scheduler.summary(snapshot(card)).state
            return QueueCard(id: card.id, state: state, due: card.dueDate, createdAt: card.createdAt,
                             suspended: card.isSuspended, noteID: card.noteID)
        }
    }
    func queueLogs() throws -> [QueueLog] {
        let map = Dictionary(uniqueKeysWithValues: try cards().map { ($0.id, $0.noteID) })
        return try logs().map { QueueLog(cardID: $0.cardID, reviewedAt: $0.reviewedAt, wasNew: $0.wasNew, noteID: map[$0.cardID]) }
    }
    func counts(now: Date) throws -> HomeCounts {
        try ReviewQueueBuilder(calendar: calendar).counts(cards: queueCards(), logs: queueLogs(),
                                                        settings: settings(), now: now)
    }

    func start(mode: StudyMode, scope: LearningScope = LearningScope(), now: Date) throws {
        try transaction {
            let normalized = try normalizedScope(scope)
            let available = try ReviewQueueBuilder(calendar: calendar).queue(
                cards: scopedQueueCards(normalized), logs: queueLogs(), settings: settings(),
                mode: mode, touched: [], reviewStreak: 0, now: now)
            // Check before replacing an interrupted draft, even if home counts were stale.
            guard !available.isEmpty else { throw StudyError.noAvailableCards }
            if let existing = try session() { context.delete(existing) }
            try setScopeInTransaction(normalized)
            let draft = SessionDraft(mode: mode, now: now)
            context.insert(draft)
            try selectNext(draft: draft, now: now)
        }
    }
    func completeSession(now: Date) throws {
        try transaction {
            guard let draft = try session(), draft.cardID == nil else { throw StudyError.noSession }
            // Recheck at execution time so a newly available card cannot be discarded.
            try selectNext(draft: draft, now: now)
            guard draft.cardID == nil else { throw StudyError.noAvailableCards }
            context.delete(draft)
            for row in try context.fetch(FetchDescriptor<SessionScope>()) { context.delete(row) }
        }
    }
    func resume(now: Date) throws {
        try transaction {
            guard let draft = try session() else { throw StudyError.noSession }
            if draft.cardID == nil { try selectNext(draft: draft, now: now) }
            else { draft.activeSince = now }
        }
    }
    func selectNext(draft: SessionDraft, now: Date) throws {
        let ids = try ReviewQueueBuilder(calendar: calendar).queue(
            cards: scopedQueueCards(scope()), logs: queueLogs(), settings: settings(),
            mode: StudyMode(rawValue: draft.mode) ?? .review, touched: Set(draft.touchedCardIDs),
            reviewStreak: draft.reviewStreak, now: now)
        draft.cardID = ids.first; draft.typedDraft = ""; draft.answerRevealed = false
        draft.elapsedMs = 0; draft.updatedAt = now
        draft.activeSince = draft.cardID == nil ? nil : now
        if let id = draft.cardID, let item = try noteItems(cardID: id).first {
            draft.answerMode = item.responseMode.rawValue
        }
    }
    func updateDraft(mode: ResponseMode? = nil, text: String? = nil, revealed: Bool? = nil, now: Date) throws {
        try transaction {
            guard let draft = try session() else { throw StudyError.noSession }
            if let mode { draft.answerMode = mode.rawValue }
            if let text { draft.typedDraft = text }
            if let revealed { draft.answerRevealed = revealed }
            draft.updatedAt = now
        }
    }
    func setSessionActive(_ active: Bool, now: Date) throws {
        try transaction {
            guard let draft = try session() else { return }
            if let since = draft.activeSince {
                draft.elapsedMs += max(0, Int(now.timeIntervalSince(since) * 1000))
            }
            draft.activeSince = active && draft.cardID != nil ? now : nil
            draft.updatedAt = now
        }
    }

    func grade(_ grade: ReviewGrade, now: Date) throws {
        try transaction {
            guard let draft = try session(), let cardID = draft.cardID, draft.answerRevealed,
                  let card = try cards().first(where: { $0.id == cardID && !$0.isSuspended }) else {
                throw StudyError.noSession
            }
            let scheduler = try ReviewScheduler(desiredRetention: settings().desiredRetention)
            let before = try snapshot(card)
            let summary = try scheduler.summary(before)
            if summary.state == "new", try counts(now: now).newRemaining == 0 { throw StudyError.newLimitReached }
            let transition = try scheduler.review(before, grade: grade, now: now)
            let after = try JSONEncoder().encode(transition.after)
            let duration = draft.elapsedMs + (draft.activeSince.map { max(0, Int(now.timeIntervalSince($0) * 1000)) } ?? 0)
            let log = StudyReviewLog(card: card, transition: transition, before: card.fsrsPayload, after: after,
                                     mode: ResponseMode(rawValue: draft.answerMode) ?? .mental,
                                     durationMs: duration, wasNew: summary.state == "new",
                                     sequence: (try logs().map(\.sequence).max() ?? 0) + 1)
            context.insert(log)
            card.fsrsPayload = after; card.dueDate = try scheduler.summary(transition.after).dueDate
            card.updatedAt = now
            draft.undoLogID = log.id
            if !draft.touchedCardIDs.contains(card.id) { draft.touchedCardIDs.append(card.id) }
            if summary.state == "new" { draft.reviewStreak = 0 }
            else if summary.state == "review" { draft.reviewStreak += 1 }
            try selectNext(draft: draft, now: now)
        }
    }

    func undo(now: Date) throws {
        try transaction {
            guard let draft = try session(), let logID = draft.undoLogID,
                  let latest = try logs().last, latest.id == logID,
                  let card = try cards().first(where: { $0.id == latest.cardID }),
                  card.fsrsPayload == latest.fsrsAfter else { throw StudyError.cannotUndo }
            let before = try JSONDecoder().decode(SchedulerSnapshot.self, from: latest.fsrsBefore)
            card.fsrsPayload = latest.fsrsBefore
            card.dueDate = try ReviewScheduler().summary(before).dueDate
            card.updatedAt = latest.previousUpdatedAt
            draft.cardID = card.id; draft.answerMode = latest.responseMode
            draft.typedDraft = ""; draft.answerRevealed = false; draft.undoLogID = nil
            draft.elapsedMs = 0; draft.activeSince = now; draft.updatedAt = now
            draft.reviewStreak = 0
            if latest.wasNew { draft.touchedCardIDs.removeAll { $0 == card.id } }
            context.delete(latest)
        }
    }

    func presentation(now: Date) throws -> ReviewPresentation? {
        guard let draft = try session() else { return nil }
        let mode = StudyMode(rawValue: draft.mode) ?? .review
        let item = try draft.cardID.flatMap { try noteItems(cardID: $0).first }
        let short = try scopedQueueCards(scope()).filter {
            !$0.suspended && ($0.state == "learning" || $0.state == "relearning") && $0.due > now
                && (mode != .new || draft.touchedCardIDs.contains($0.id))
        }.map(\.due).min()
        return ReviewPresentation(card: item, mode: mode,
                                  responseMode: ResponseMode(rawValue: draft.answerMode) ?? .mental,
                                  typedDraft: draft.typedDraft, answerRevealed: draft.answerRevealed,
                                  canUndo: draft.undoLogID != nil, nextShortDue: short,
                                  emptyState: item == nil ? try emptyState(draft: draft, mode: mode, short: short, now: now) : nil)
    }
    private func emptyState(draft: SessionDraft, mode: StudyMode, short: Date?, now: Date) throws -> ReviewEmptyState {
        let cards = try scopedQueueCards(scope()), logs = try queueLogs(), settings = try settings()
        let builder = ReviewQueueBuilder(calendar: calendar)
        let counts = builder.counts(cards: cards, logs: logs, settings: settings, now: now)
        let queue = builder.queue(cards: cards, logs: logs, settings: settings, mode: mode,
                                  touched: Set(draft.touchedCardIDs), reviewStreak: draft.reviewStreak, now: now)
        guard draft.cardID == nil, queue.isEmpty else {
            return ReviewEmptyState(reason: .retry, title: "出題を確認してください", message: "学習状態を再取得してください。", canRetry: true)
        }
        let limit = mode != .review && counts.eligibleNew > 0 && counts.newRemaining == 0
        let global = builder.counts(cards: try queueCards(), logs: logs, settings: settings, now: now)
        let remaining = "未学習カードはあと\(global.totalNew)枚（全デッキ・停止中を除く）。現在の学習対象内は\(counts.totalNew)枚です。"
        if short != nil {
            return ReviewEmptyState(reason: .waiting, title: "今出題できるカードはありません",
                                    message: "期限が来ると自動で出題を再確認します。このセッションで続けるか、今回はここまでにできます。" + (limit ? "今日の新規学習は上限（\(settings.dailyNewLimit)枚）に達しました。" + remaining : ""),
                                    suggestsSettings: limit, canRetry: true)
        }
        if limit {
            return ReviewEmptyState(reason: .newLimit, title: "今日の新規学習は上限です",
                                    message: "上限\(settings.dailyNewLimit)枚。" + remaining + "設定 > 学習で変更できます。学習日の切替は\(settings.dayStartHour)時です。", suggestsSettings: true, canRetry: true)
        }
        // Match queue()'s mode membership before asking why eligible cards are blocked.
        // In .new, touching a card does not make its long-term review state eligible.
        guard cards.allSatisfy({ ["new", "learning", "relearning", "review"].contains($0.state) }) else {
            return ReviewEmptyState(reason: .retry, title: "出題を確認してください",
                                    message: "学習対象の状態を確認できません。出題を再確認してください。", canRetry: true)
        }
        let touched = Set(draft.touchedCardIDs)
        let relevant = cards.filter { card in
            switch mode {
            case .review: return card.state != "new"
            case .new: return card.state == "new" || (["learning", "relearning"].contains(card.state) && touched.contains(card.id))
            case .mixed: return true
            }
        }
        func available(_ candidates: [QueueCard], with options: StudySettings) -> Bool {
            !builder.queue(cards: candidates, logs: logs, settings: options, mode: mode,
                           touched: touched, reviewStreak: draft.reviewStreak, now: now).isEmpty
        }
        // Prove suppression is blocking this mode's queue. Due alone is not proof.
        var unburied = settings; unburied.siblingBuryEnabled = false
        if settings.siblingBuryEnabled && available(cards, with: unburied) {
            return ReviewEmptyState(reason: .siblings, title: "兄弟カードの同日抑制で待機中です",
                                    message: "同じノートのカードは次の学習日に出題できます。学習日の切替は\(settings.dayStartHour)時です。", suggestsScopeChange: true, canRetry: true)
        }
        let unsuspended = cards.map {
            QueueCard(id: $0.id, state: $0.state, due: $0.due, createdAt: $0.createdAt, suspended: false, noteID: $0.noteID)
        }
        if (!relevant.isEmpty && relevant.allSatisfy(\.suspended)) || available(unsuspended, with: settings) {
            return ReviewEmptyState(reason: .suspended, title: "対象のカードは停止中です",
                                    message: "ライブラリで停止を解除できます。", suggestsScopeChange: true)
        }
        // Multiple blocking rules or an unexplained queue mismatch cannot establish
        // one cause. Keep retry available rather than claiming siblings/completion.
        if relevant.contains(where: { $0.state == "new" || $0.due <= now }) {
            return ReviewEmptyState(reason: .retry, title: "今出題できるカードはありません",
                                    message: "複数の出題条件により対象外になっている可能性があります。設定や学習対象を確認して、出題を再確認してください。",
                                    suggestsScopeChange: true, canRetry: true)
        }
        if mode == .new && cards.contains(where: { !$0.suspended && $0.state == "review" && $0.due <= now }) {
            return ReviewEmptyState(reason: .modeExcluded, title: "今回の新規学習は完了しました",
                                    message: "復習期限に達したカードは「復習する」から学習できます。このセッションでは長期の復習カードを出題しません。", suggestsScopeChange: true)
        }
        if let next = relevant.filter({ !$0.suspended && !touched.contains($0.id) && $0.due > now }).map(\.due).min() {
            return ReviewEmptyState(reason: .reviewWaiting, title: "現在復習できるカードはありません",
                                    message: "次の復習予定: \(next.formatted(date: .abbreviated, time: .shortened))。期限到来後にホームから学習できます。", canRetry: true)
        }
        if relevant.isEmpty && !cards.contains(where: { touched.contains($0.id) }) {
            if cards.isEmpty {
                return ReviewEmptyState(reason: .noTargets, title: "学習対象にカードがありません",
                                        message: "ホームでデッキ・タグなどの学習対象を確認できます。", suggestsScopeChange: true)
            }
            return ReviewEmptyState(reason: .modeExcluded, title: "このモードの学習対象にカードがありません",
                                    message: mode == .review ? "未学習カードは「新しく覚える」から学習できます。" : "復習カードは「復習する」から学習できます。新規学習で続ける短期復習は、このセッションで学んだカードだけです。",
                                    suggestsScopeChange: true)
        }
        return ReviewEmptyState(reason: .complete, title: "今回の学習は完了しました",
                                message: mode == .new ? "今回出題できる新規カードの学習を終えました。今後の復習は期限到来後にホームから始められます。" : "現在復習できるカードはありません。今後の復習は期限到来後にホームから始められます。")
    }

}
