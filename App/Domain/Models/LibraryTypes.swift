import Foundation

struct LearningScope: Codable, Equatable {
    var schemaVersion = 1
    var deckID: UUID?
    var tagIDs: [UUID] = []
}

struct StudyOptions: Codable, Equatable {
    var schemaVersion = 2
    var siblingBuryEnabled = true
    var notification: NotificationOptions? = nil
    var hapticsMode: HapticsMode? = nil
    var homeScope: LearningScope? = nil
    var reviewAppearance: ReviewAppearance? = nil
    var speech: SpeechPreferences? = nil
    // Optional fields preserve decoding of existing .studybackup preference JSON.
    // nil = default 20 answers; 0 = unlimited.
    var sessionAnswerLimit: Int? = nil
    var fsrsOptimization: FSRSOptimizationState? = nil
    var deckLearning: [DeckLearningOverride]? = nil
    var deckNewUsage: [DeckNewUsage]? = nil
    var sessionResponseMode: SessionResponseMode? = nil
    var activeSessionProgress: StudySessionProgressSnapshot? = nil
}

// The session boundary is the last persisted ReviewLog sequence when the session starts.
// This is stored separately from the daily unique-card goal and survives app relaunch.
struct StudySessionProgressSnapshot: Codable, Equatable {
    var startSequence: Int
    var answerLimit: Int
    var responseMode: SessionResponseMode? = nil
}

enum SessionResponseMode: String, Codable, CaseIterable {
    case cardDefault, mental, typing, ordering
    var title: String {
        switch self {
        case .cardDefault: return "カードに合わせる"
        case .mental: return "頭の中"
        case .typing: return "文字入力"
        case .ordering: return "並び替え"
        }
    }
    var override: ResponseMode? { ResponseMode(rawValue: rawValue) }
    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .cardDefault
    }
}

struct TagItem: Identifiable {
    let id: UUID
    let name: String
}

extension NoteInput {
    // Tags are handled separately from content to preserve stable card variants.
}

struct ImportRow: Identifiable, Equatable {
    let id: UUID
    var line: Int
    var question: String
    var answer: String
    var explanation: String = ""
    // nil preserves an existing hint on import; an explicit empty string clears it.
    var hint: String? = nil
    var responseMode: ResponseMode? = nil
    var modeWarning: String? = nil
    var questionLayout: TextLayout? = nil
    var answerLayout: TextLayout? = nil
    var error: String?
    var included = true
    init(line: Int, question: String, answer: String, error: String? = nil) {
        id = UUID(); self.line = line; self.question = question; self.answer = answer; self.error = error
    }
}

struct ImportResult {
    // Kept for existing callers: successfully processed rows, not unique notes/cards.
    let imported: Int
    let skipped: Int
    let errors: [String]
    var createdNotes = 0
    var updatedNotes = 0
    var createdCards = 0
    var maintainedCards = 0
    var duplicateRows = 0
    var excludedRows = 0
    var summary: String {
        "新規 \(createdNotes)ノート / 更新 \(updatedNotes)ノート\n新規カード \(createdCards)枚 / 維持したカード \(maintainedCards)枚\n処理 \(imported)行 / 重複スキップ \(duplicateRows)行 / 除外 \(excludedRows)行 / エラー \(errors.count)行"
    }
}

enum DuplicateAction: String, CaseIterable {
    case skip, add, update
    var title: String {
        switch self {
        case .skip: return "スキップ"
        case .add: return "別ノートとして追加"
        case .update: return "既存ノートを更新"
        }
    }
}

enum LibraryError: LocalizedError {
    case cycle, invalidDestination, malformedCSV(Int), fileTooLarge, invalidUTF8
    var errorDescription: String? {
        switch self {
        case .cycle: return "自分自身や子孫を親デッキにできません。"
        case .invalidDestination: return "移動先のデッキを選んでください。"
        case .malformedCSV(let line): return "\(line)行目付近の引用符または区切りの形式が不正です。"
        case .fileTooLarge: return "ファイルが大きすぎます（上限10MB）。分割して取り込んでください。"
        case .invalidUTF8: return "UTF-8のテキストファイルを選んでください。"
        }
    }
}

// Optional in StudyOptions: stores created before these settings retain defaults.
struct ReviewAppearance: Codable, Equatable {
    var gesturesEnabled = false
    var textSize = ReviewTextSize.standard
    var imageDisplay = ReviewImageDisplay.standard
    var answerFirst = false
    var animationsEnabled = true
    func showsImage(for kind: NoteKind) -> Bool { kind == .imageOcclusion || imageDisplay != .hidden }
}


enum ReviewTextSize: String, Codable, CaseIterable {
    case standard, larger, extraLarge
    var title: String {
        switch self { case .standard: return "標準"; case .larger: return "大きめ"; case .extraLarge: return "特大" }
    }
}

enum ReviewImageDisplay: String, Codable, CaseIterable {
    case standard, compact, hidden
    var title: String {
        switch self { case .standard: return "標準"; case .compact: return "コンパクト"; case .hidden: return "非表示" }
    }
}

enum ReviewSwipeAction: Equatable {
    case reveal, grade(ReviewGrade)
    static func decide(x: Double, y: Double, revealed: Bool) -> Self? {
        guard x.isFinite, y.isFinite else { return nil }
        if abs(x) >= 96 && abs(x) >= abs(y) * 1.5 {
            if !revealed { return x > 0 ? .reveal : nil }
            return .grade(x > 0 ? .good : .again)
        }
        if revealed && abs(y) >= 96 && abs(y) >= abs(x) * 1.5 {
            return .grade(y > 0 ? .hard : .easy)
        }
        return nil
    }
}

struct ReviewSwipeGate {
    private var start: (id: UUID, revealed: Bool)?
    private var lastAction: Date?
    private var invalidated = false
    mutating func begin(id: UUID, revealed: Bool) {
        if start == nil && !invalidated { start = (id, revealed) }
    }
    mutating func cancel() { start = nil; invalidated = false }
    mutating func invalidate() { if start != nil { invalidated = true } }
    mutating func finish(id: UUID, revealed: Bool, x: Double, y: Double, now: Date) -> ReviewSwipeAction? {
        defer { start = nil; invalidated = false }
        guard !invalidated, let start, start.id == id, start.revealed == revealed,
              lastAction == nil || now.timeIntervalSince(lastAction!) >= 0.6,
              let action = ReviewSwipeAction.decide(x: x, y: y, revealed: revealed) else { return nil }
        lastAction = now
        return action
    }
}


enum BulkEditAction: Equatable {
    case move(UUID), addTags([String]), removeTags(Set<UUID>), suspended(Bool), deleteNotes
    var title: String {
        switch self {
        case .move: return "ノートをデッキ移動"
        case .addTags: return "ノートにタグを追加"
        case .removeTags: return "ノートからタグを除去"
        case .suspended(let value): return value ? "選択カードを停止" : "選択カードを再開"
        case .deleteNotes: return "ノートを削除"
        }
    }
}

struct BulkEditPreview {
    struct NoteState: Equatable {
        let id: UUID, deckID: UUID
        let content: Data
        let type: String, responseMode: String
        let tags: [UUID]
        let updated: Date
    }
    struct CardState: Equatable {
        let id: UUID, noteID: UUID
        let fsrs: Data
        let due: Date, updated: Date
        let suspended: Bool
    }
    struct DraftState: Equatable { let key: String; let payload: Data; let updated: Date }
    struct Row: Identifiable, Equatable { let id: UUID; let question: String, deck: String; let cardCount: Int }
    let selection: Set<UUID>
    let action: BulkEditAction
    let notes: [NoteState], cards: [CardState], drafts: [DraftState]
    let rows: [Row]
    let changedNotes: Set<UUID>, changedCards: Set<UUID>
    let detail: String
    var selectedCount: Int { selection.count }
    var changedCount: Int { changedCards.count }
}

struct BulkEditResult {
    let changedNotes: Int, changedCards: Int
}

enum BulkEditError: LocalizedError {
    case emptySelection, staleSelection, invalidTags
    var errorDescription: String? {
        switch self {
        case .emptySelection: return "カードを選択してください。"
        case .staleSelection: return "対象が変更されたため確定できません。選択とプレビューを確認し直してください。"
        case .invalidTags: return "追加・除去するタグを指定してください。"
        }
    }
}


// A deck-content operation never modifies Deck identity, parentID or the tree.
enum DeckContentsScope: String, CaseIterable, Identifiable {
    case direct
    case includingDescendants
    var id: String { rawValue }
    var title: String {
        switch self {
        case .direct: return "このデッキ直下のみ"
        case .includingDescendants: return "子デッキの中身も含める"
        }
    }
}

enum DeckContentsAction: Equatable {
    case move(to: UUID)
    case delete
}

struct DeckContentsPreview {
    struct DeckState: Equatable {
        let id: UUID
        let name: String
        let parentID: UUID?
        let sortOrder: Int
        let createdAt: Date
        let updatedAt: Date
    }

    let sourceID: UUID
    let scope: DeckContentsScope
    let action: DeckContentsAction
    let hierarchy: [DeckState]
    let sourcePath: String
    let destinationPath: String?
    let includedChildPaths: [String]
    let noteIDs: Set<UUID>
    let cardIDs: Set<UUID>
    // The actual mutation is delegated to the same snapshot/transaction as library bulk edits.
    let bulk: BulkEditPreview?

    var noteCount: Int { noteIDs.count }
    var cardCount: Int { cardIDs.count }
    var changedNoteCount: Int { bulk?.changedNotes.count ?? 0 }
    var changedCardCount: Int { bulk?.changedCards.count ?? 0 }
    var canCommit: Bool { changedNoteCount > 0 }
}


struct LearningStatePresentation {
    let state: String
    var title: String {
        switch state {
        case "new": return "未学習"
        case "learning": return "学習中"
        case "review": return "復習待ち"
        case "relearning": return "再学習中"
        default: return "状態を確認できません"
        }
    }
    var explanation: String {
        switch state {
        case "new": return "まだ自己評価していないカードです。"
        case "learning": return "初回の短い間隔で覚えている段階です。"
        case "review": return "長い間隔で定着を確認する段階です。"
        case "relearning": return "忘れた内容を短い間隔で覚え直している段階です。"
        default: return "カードの状態を読み込み直してください。"
        }
    }
    func availability(suspended: Bool, due: Date, now: Date) -> String {
        if suspended { return "停止中のため出題されません。停止を解除しても復習予定は変わりません。" }
        if state == "new" { return "新規枠・学習対象・同日抑制に従って出題します。" }
        if due > now { return "次回復習の時刻まで待機します。" }
        return "復習の期日に達しています。学習モード・対象・同日抑制によっては出題対象外になることがあります。"
    }
}
struct DeckLearningOverride: Codable, Equatable {
    var deckID: UUID
    var newLimit: Int?
    var retention: Double?
    var isValid: Bool {
        (newLimit.map { (0...500).contains($0) } ?? true) &&
        (retention.map { $0.isFinite && (0.8...0.97).contains($0) } ?? true)
    }
}
struct DeckNewUsage: Codable, Equatable {
    var sequence: Int
    var cardID: UUID
    var quotaDeckIDs: [UUID]
}
