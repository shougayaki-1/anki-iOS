import Foundation

enum NoteKind: String, Codable, CaseIterable {
    case basic, written, cloze, imageOcclusion
    var title: String {
        switch self {
        case .basic: return "一問一答"
        case .written: return "記述式"
        case .cloze: return "穴埋め"
        case .imageOcclusion: return "画像マスク"
        }
    }
}

enum ResponseMode: String, Codable, CaseIterable {
    case mental, typing, ordering
    var title: String {
        switch self { case .mental: return "頭の中で回答"; case .typing: return "文字入力"; case .ordering: return "並び替え" }
    }
    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .mental
    }
}

enum StudyMode: String, Codable, CaseIterable, Identifiable {
    case review, new, mixed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .review: return "復習する"
        case .new: return "新しく覚える"
        case .mixed: return "復習＋新規"
        }
    }
}

extension StudyMode {
    var explanation: String {
        switch self {
        case .review: return "復習のタイミングになったカードを学習します"
        case .new: return "まだ学んでいないカードを学習します"
        case .mixed: return "復習と新しいカードを組み合わせて学習します"
        }
    }
}

struct TextContent: Codable, Equatable {
    var schemaVersion = 2
    var question: String
    var answer: String
    var explanation: String
    var hint: String? = nil
    var reverseEnabled: Bool? = nil
    var imageID: UUID? = nil
    var masks: [ImageMask]? = nil
    var hideAllMasks: Bool? = nil
    /// Overrides are keyed by generated card variant, preserving reverse/cloze sibling independence.
    var speechOverrides: [String: SpeechAutoplay]? = nil
    var speechQuestion: String? = nil
    var speechAnswer: String? = nil
    var questionAudioID: UUID? = nil
    var answerAudioID: UUID? = nil
    var questionLayout: TextLayout? = nil
    var answerLayout: TextLayout? = nil
}

struct NoteInput: Codable, Equatable {
    var deckID: UUID
    var kind: NoteKind = .basic
    var question = ""
    var answer = ""
    var explanation = ""
    var hint: String? = nil
    var responseMode: ResponseMode = .mental
    var tagNames: [String] = []
    var reverseEnabled = false
    var imageID: UUID? = nil
    var masks: [ImageMask] = []
    var hideAllMasks = true
    // Optional to decode editor drafts saved by older releases.
    var speechOverrides: [String: SpeechAutoplay]? = nil
    var speechQuestion: String? = nil
    var speechAnswer: String? = nil
    var questionAudioID: UUID? = nil
    var answerAudioID: UUID? = nil
    var questionLayout: TextLayout? = nil
    var answerLayout: TextLayout? = nil
}

struct StudySettings: Equatable {
    static let newLimitRange = 0...500
    static let goalRange = 1...500
    static let dayStartRange = 0...23
    static let retentionPercentRange = 80...97
    var desiredRetention = 0.9
    var dailyNewLimit = 10
    var dailyGoal: Int? = 20
    var dayStartHour = 4
    var siblingBuryEnabled = true
    var notification = NotificationOptions()
    var hapticsMode = HapticsMode.standard
    var reviewAppearance = ReviewAppearance()
    var speech = SpeechPreferences()
}

enum NumericSettingsInput {
    static func percentageText(_ value: Double) -> String {
        let text = String(value * 100)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
    static func integer(_ text: String, in range: ClosedRange<Int>) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(text), range.contains(value) else { return nil }
        return value
    }

    /// Mask coordinates may come from a drag, so preserve fractional percentages.
    static func percentage(_ text: String, lower: Double, upper: Double) -> Double? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
        }), let value = Double(text), value.isFinite,
              value >= lower, value <= upper else { return nil }
        return value / 100
    }
}

struct DeckItem: Identifiable {
    let id: UUID
    let name: String              // Full path used by pickers and scope selection.
    var isStudyPaused = false
    var isEffectivelyStudyPaused = false
    let shortName: String         // Local deck name used by the management tree.
    let parentID: UUID?

    init(id: UUID, name: String, shortName: String? = nil, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.shortName = shortName ?? name
        self.parentID = parentID
    }
}

struct NoteItem: Identifiable {
    let noteID: UUID
    var id: UUID { cardID }
    let cardID: UUID
    let deckID: UUID
    let deckName: String
    let kind: NoteKind
    let content: TextContent
    let sourceContent: TextContent
    let variantKey: String
    let responseMode: ResponseMode
    let summary: ScheduleSummary
    let isSuspended: Bool
    var flag: CardFlag? = nil
    var hiddenUntil: Date? = nil
    var tagNames: [String] = []
    var tagIDs: [UUID] = []
}

struct HomeCounts: Equatable {
    var due = 0
    var totalNew = 0
    var newRemaining = 0
    var learnedToday = 0
    var answerCount = 0
    var eligibleNew = 0
    var suspendedNew = 0
}

struct HomeSnapshot: Equatable {
    let scope: LearningScope
    let counts: HomeCounts
    let globalCounts: HomeCounts
    let newSlotsRemaining: Int
    let nextShortDue: Date?
    let hasCards: Bool
    let dayStart: Date
    let nextRefresh: Date
    var studyPaused = false
    var medianAnswerSeconds: Double? = nil
}

// Read-only recommendation. Card pool and answer budget deliberately have separate units.
struct HomeRecommendation: Equatable {
    let mode: StudyMode
    let cardCount: Int
    let answerLimit: Int
    let medianAnswerSeconds: Double?
    let scope: LearningScope
    let responseMode: SessionResponseMode
    init(mode: StudyMode, cardCount: Int, answerLimit: Int, medianAnswerSeconds: Double?, scope: LearningScope = LearningScope(), responseMode: SessionResponseMode = .cardDefault) {
        self.mode = mode; self.cardCount = cardCount; self.answerLimit = answerLimit
        self.medianAnswerSeconds = medianAnswerSeconds; self.scope = scope; self.responseMode = responseMode
    }
    var policy: ReviewOrderPolicy {
        mode == .review && answerLimit > 0 && cardCount > answerLimit ? .forgettingRisk : .traditional
    }
    var title: String { mode == .review ? "おすすめの復習を始める" : "おすすめの新規学習を始める" }
    var poolText: String { "\(mode == .review ? "復習待ち" : "新規カード")：\(cardCount)枚" }
    var limitText: String { answerLimit == 0 ? "今回は回答上限なし" : "今回は最大\(answerLimit)回答" }
    var reason: String {
        if policy == .forgettingRisk { return "復習待ちが多いため、忘れそうなカードから取り組みます。" }
        return mode == .review ? "期限を迎えたカードから復習します。" : "復習待ちはありません。新しいカードに取り組めます。"
    }
    var estimatedAnswers: Int { answerLimit == 0 ? cardCount : min(cardCount, answerLimit) }
    var timeText: String {
        guard let seconds = medianAnswerSeconds, seconds.isFinite, (1...300).contains(seconds), cardCount > 0 else { return "推定不可" }
        return "約\(max(1, Int(ceil(Double(estimatedAnswers) * seconds / 60))))分"
    }
    var estimateExplanation: String {
        "直近30日の有効な回答時間（最大1,000回答・5回答以上）の中央値 × 初回の予定回答数。再回答や待機によって所要時間は変わります。"
    }
}

enum AnswerTimeEstimate {
    static func median(milliseconds: [Int], validRange: ClosedRange<Int> = 1_000...300_000, minimumSamples: Int = 5) -> Double? {
        let values = milliseconds.filter { validRange.contains($0) }.sorted()
        guard values.count >= minimumSamples && !values.isEmpty else { return nil }
        return Double(values[(values.count - 1) / 2] + values[values.count / 2]) / 2_000
    }
}

struct ReviewPresentation {
    let card: NoteItem?
    let mode: StudyMode
    let responseMode: ResponseMode
    let typedDraft: String
    let answerRevealed: Bool
    let canUndo: Bool
    let nextShortDue: Date?
    var ordering: OrderingDraft? = nil
    var orderingUnavailable: String? = nil
    var emptyState: ReviewEmptyState? = nil
    var sessionProgress: SessionAnswerProgress? = nil
    // Current display denominator; the configured answer limit remains unchanged.
    var visibleAnswerTotal: Int? = nil
    // Classification of the persisted #212 snapshot; never infer cards from mode alone.
    var sessionProgressUsesCards = false

    var sessionProgressHeadline: String {
        guard let progress = sessionProgress else { return "" }
        if progress.limit == 0 { return "今回\(progress.answered)回答を記録" }
        if progress.isComplete {
            return sessionProgressUsesCards ? "今回の\(progress.limit)枚を完了" : "上限の\(progress.limit)回答に到達"
        }
        if card == nil {
            return sessionProgressUsesCards ? "\(progress.answered)枚を学習済み" : "\(progress.answered)回答を記録"
        }
        return sessionProgressUsesCards ? "残り\(progress.remaining ?? 0)枚" : "上限まであと\(progress.remaining ?? 0)回答"
    }

    var sessionProgressLabel: String {
        guard let progress = sessionProgress else { return "" }
        if progress.limit == 0 { return "\(progress.answered)回答" }
        return sessionProgressUsesCards ? "今回 \(progress.answered) / \(progress.limit)枚" : "\(progress.answered)回答 / 上限\(progress.limit)回答"
    }

    var sessionProgressAccessibilityValue: String {
        guard let progress = sessionProgress else { return "" }
        let completed = sessionProgressUsesCards ? "\(progress.answered)枚学習済み" : "\(progress.answered)回答済み"
        return "\(completed)、\(sessionProgressHeadline)"
    }
}

// Count confirmed answers in this session, not the number of unique cards studied today.
struct SessionAnswerProgress: Equatable {
    let answered: Int
    let limit: Int  // 0 = unlimited

    var remaining: Int? { limit == 0 ? nil : max(0, limit - answered) }
    var isComplete: Bool { limit > 0 && answered >= limit }
}

struct ReviewEmptyState: Equatable {
    enum Reason: Equatable { case complete, waiting, reviewWaiting, modeExcluded, newLimit, noTargets, suspended, siblings, held, retry }
    let reason: Reason
    let title: String
    let message: String
    var suggestsSettings = false
    var suggestsScopeChange = false
    var canRetry = false
}

// Primary actions preserve the existing session; replacement is a secondary action.
enum HomePrimaryAction: Equatable {
    case resume(StudyMode), waiting(Date), complete
    case start(StudyMode, Int), addCards, unavailable

    var title: String {
        switch self {
        case .resume: return "続きから再開"
        case .waiting: return "短期復習の待機中"
        case .complete: return "今回の学習を完了"
        case let .start(mode, _): return mode.title
        case .addCards: return "カードを追加する"
        case .unavailable: return "今は学習できるカードがありません"
        }
    }
    func buttonTitle(answerLimit: Int) -> String {
        guard case let .start(mode, _) = self else { return title }
        return HomeStudyPresentation.startTitle(mode: mode, answerLimit: answerLimit)
    }
    func accessibilityLabel(answerLimit: Int) -> String {
        guard case let .start(mode, count) = self else { return title }
        return buttonTitle(answerLimit: answerLimit) + "。" + HomeStudyPresentation.cardPool(mode: mode, count: count)
    }
    var identifier: String {
        switch self {
        case .resume: return "resumeStudy"
        case .waiting: return "waitingStudy"
        case .complete: return "completeStudy"
        case let .start(mode, _): return "start-\(mode.rawValue)"
        case .addCards: return "addFirstHomeNote"
        case .unavailable: return "unavailableStudy"
        }
    }
}

enum HomeStudyPresentation {
    static func sessionSummary(answerLimit: Int, responseMode: SessionResponseMode) -> String {
        let limit = answerLimit == 0 ? "回答上限なし" : "最大\(answerLimit)回答"
        return "1回の学習：\(limit)・\(responseMode.title)"
    }

    static func dailyProgress(count: Int, goal: Int?) -> String {
        guard let goal, goal > 0 else { return "\(count)枚" }
        return count >= goal ? "\(count)枚・目標\(goal)枚 達成" : "\(count) / \(goal)枚"
    }

    static func startTitle(mode: StudyMode, answerLimit: Int) -> String {
        let limit = answerLimit == 0 ? "上限なし" : "最大\(answerLimit)回答"
        return "\(mode.title)・\(limit)"
    }

    static func cardPool(mode: StudyMode, count: Int) -> String {
        let title: String
        switch mode {
        case .review: title = "復習できるカード"
        case .new: title = "新しく学べるカード"
        case .mixed: title = "復習＋新規で学べるカード"
        }
        return "\(title)：\(count)枚"
    }

    static func explanation(answerLimit: Int) -> String {
        let limit = answerLimit == 0 ? "回答数の上限はありません。" : "1回の学習は最大\(answerLimit)回の回答で終了します。"
        return limit + "同じカードへの再回答も数えます。出題できるカードがなくなると、上限より前に終了することがあります。"
    }
}

enum StudyError: LocalizedError {
    case deckStudyPaused, reviewEditStructure, invalidContent, missingRecord, unsupportedContent, newLimitReached, cannotUndo, noSession, noAvailableCards, noOrderingCards
    var errorDescription: String? {
        switch self {
        case .deckStudyPaused: return "このデッキは学習を休止しています。回答下書きとUndoは保持しています。デッキ管理で学習を再開してください。"
        case .reviewEditStructure: return "学習中はカード形式・生成枚数・穴埋め番号・マスクIDを変更できません。構造の変更は学習を中断してライブラリで行ってください。"
        case .invalidContent: return "問題文と解答を入力してください。"
        case .missingRecord: return "対象のカードまたはデッキが見つかりません。"
        case .unsupportedContent: return "このデータ形式はまだ編集できません。"
        case .newLimitReached: return "今日の新規カード上限に達しました。"
        case .cannotUndo: return "直前の評価後に状態が変わったため、取り消せません。"
        case .noOrderingCards: return "今は並び替えで学習できるカードがありません。英文の一問一答・記述式が対象です。学習設定の回答形式や学習対象を確認してください。"
        case .noAvailableCards: return "今はこの条件で学習できるカードがありません。学習対象を確認してください。"
        case .noSession: return "学習セッションがありません。"
        }
    }
}
