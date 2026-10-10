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
    case mental, typing
    var title: String { self == .mental ? "頭の中で回答" : "文字入力" }
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
    var reverseEnabled: Bool? = nil
    var imageID: UUID? = nil
    var masks: [ImageMask]? = nil
    var hideAllMasks: Bool? = nil
}

struct NoteInput: Codable, Equatable {
    var deckID: UUID
    var kind: NoteKind = .basic
    var question = ""
    var answer = ""
    var explanation = ""
    var responseMode: ResponseMode = .mental
    var tagNames: [String] = []
    var reverseEnabled = false
    var imageID: UUID? = nil
    var masks: [ImageMask] = []
    var hideAllMasks = true
}

struct StudySettings: Equatable {
    var desiredRetention = 0.9
    var dailyNewLimit = 10
    var dailyGoal: Int? = 20
    var dayStartHour = 4
    var siblingBuryEnabled = true
    var notification = NotificationOptions()
    var hapticsMode = HapticsMode.standard
    var reviewAppearance = ReviewAppearance()
}

struct DeckItem: Identifiable {
    let id: UUID
    let name: String
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
}

struct HomeSnapshot: Equatable {
    let scope: LearningScope
    let counts: HomeCounts
    let globalCounts: HomeCounts
    let newSlotsRemaining: Int
    let nextShortDue: Date?
    let hasCards: Bool
    let dayStart: Date
}

struct ReviewPresentation {
    let card: NoteItem?
    let mode: StudyMode
    let responseMode: ResponseMode
    let typedDraft: String
    let answerRevealed: Bool
    let canUndo: Bool
    let nextShortDue: Date?
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
