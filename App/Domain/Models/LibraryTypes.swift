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
    var reviewAppearance: ReviewAppearance? = nil
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
    var error: String?
    var included = true
    init(line: Int, question: String, answer: String, error: String? = nil) {
        id = UUID(); self.line = line; self.question = question; self.answer = answer; self.error = error
    }
}

struct ImportResult {
    let imported: Int
    let skipped: Int
    let errors: [String]
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
