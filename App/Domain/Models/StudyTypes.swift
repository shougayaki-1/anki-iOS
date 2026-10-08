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
        case .mixed: return "まとめて学習"
        }
    }
}

struct TextContent: Codable, Equatable {
    var schemaVersion = 1
    var question: String
    var answer: String
    var explanation: String
}

struct NoteInput {
    var deckID: UUID
    var kind: NoteKind = .basic
    var question = ""
    var answer = ""
    var explanation = ""
    var responseMode: ResponseMode = .mental
    var tagNames: [String] = []
}

struct StudySettings: Equatable {
    var desiredRetention = 0.9
    var dailyNewLimit = 10
    var dailyGoal: Int? = 20
    var dayStartHour = 4
    var siblingBuryEnabled = true
}

struct DeckItem: Identifiable {
    let id: UUID
    let name: String
}

struct NoteItem: Identifiable {
    let id: UUID
    let cardID: UUID
    let deckID: UUID
    let deckName: String
    let kind: NoteKind
    let content: TextContent
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
    case invalidContent, missingRecord, unsupportedContent, newLimitReached, cannotUndo, noSession
    var errorDescription: String? {
        switch self {
        case .invalidContent: return "問題文と解答を入力してください。"
        case .missingRecord: return "対象のカードまたはデッキが見つかりません。"
        case .unsupportedContent: return "このデータ形式はまだ編集できません。"
        case .newLimitReached: return "今日の新規カード上限に達しました。"
        case .cannotUndo: return "直前の評価後に状態が変わったため、取り消せません。"
        case .noSession: return "学習セッションがありません。"
        }
    }
}
