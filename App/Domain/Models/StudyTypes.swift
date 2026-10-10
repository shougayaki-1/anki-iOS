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
}

// Count confirmed answers in this session, not the number of unique cards studied today.
struct SessionAnswerProgress: Equatable {
    let answered: Int
    let limit: Int  // 0 = unlimited

    var remaining: Int? { limit == 0 ? nil : max(0, limit - answered) }
    var isComplete: Bool { limit > 0 && answered >= limit }
}

struct ReviewEmptyState: Equatable {
    enum Reason: Equatable { case complete, waiting, reviewWaiting, modeExcluded, newLimit, noTargets, suspended, siblings, retry }
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
        case let .start(mode, count): return "\(mode.title)（\(count)枚）"
        case .addCards: return "カードを追加する"
        case .unavailable: return "今は学習できるカードがありません"
        }
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

enum StudyError: LocalizedError {
    case invalidContent, missingRecord, unsupportedContent, newLimitReached, cannotUndo, noSession, noAvailableCards
    var errorDescription: String? {
        switch self {
        case .invalidContent: return "問題文と解答を入力してください。"
        case .missingRecord: return "対象のカードまたはデッキが見つかりません。"
        case .unsupportedContent: return "このデータ形式はまだ編集できません。"
        case .newLimitReached: return "今日の新規カード上限に達しました。"
        case .cannotUndo: return "直前の評価後に状態が変わったため、取り消せません。"
        case .noAvailableCards: return "今はこの条件で学習できるカードがありません。学習対象を確認してください。"
        case .noSession: return "学習セッションがありません。"
        }
    }
}
