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
