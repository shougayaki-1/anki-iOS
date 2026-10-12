import Foundation

enum ReplacementField: String, CaseIterable, Identifiable, Codable, Sendable {
    case question, answer, explanation, hint
    var id: String { rawValue }
    var title: String {
        switch self { case .question: return "問題"; case .answer: return "解答"; case .explanation: return "解説"; case .hint: return "ヒント" }
    }
    func value(in content: TextContent) -> String {
        switch self { case .question: return content.question; case .answer: return content.answer; case .explanation: return content.explanation; case .hint: return content.hint ?? "" }
    }
    func set(_ value: String, in content: inout TextContent) {
        switch self { case .question: content.question = value; case .answer: content.answer = value; case .explanation: content.explanation = value; case .hint: content.hint = value }
    }
}

struct ReplacementRequest: Equatable, Sendable {
    enum Scope: Equatable, Sendable { case cards(Set<UUID>); case deck(UUID, descendants: Bool) }
    let scope: Scope
    let find: String, replacement: String
    let fields: Set<ReplacementField>
    var caseSensitive = false
    var wholeField = false

    func replacing(_ value: String) -> (text: String, count: Int) {
        guard !find.isEmpty else { return (value, 0) }
        let options: String.CompareOptions = caseSensitive ? [.literal] : [.literal, .caseInsensitive]
        if wholeField {
            return value.compare(find, options: options, locale: Locale(identifier: "en_US_POSIX")) == .orderedSame ? (replacement, 1) : (value, 0)
        }
        var cursor = value.startIndex, text = "", count = 0
        while cursor < value.endIndex, let range = value.range(of: find, options: options, range: cursor..<value.endIndex, locale: Locale(identifier: "en_US_POSIX")) {
            text += value[cursor..<range.lowerBound]; text += replacement
            cursor = range.upperBound; count += 1
        }
        text += value[cursor...]
        return (text, count)
    }
}

struct ReplacementPreview: Equatable, Sendable {
    struct NoteState: Equatable, Sendable {
        let id: UUID, deckID: UUID
        let type: String, mode: String
        let content: Data
        let tags: [UUID]
        let updated: Date
    }
    struct CardState: Equatable, Sendable {
        let id: UUID, noteID: UUID
        let variant: String
    }
    struct Row: Equatable, Identifiable, Sendable {
        struct Change: Equatable, Sendable { let field: ReplacementField; let before: String, after: String; let count: Int }
        let id: UUID, title: String
        let changes: [Change]
        let cardCount: Int
        let payload: Data?
        let skipReason: String?
    }
    let request: ReplacementRequest
    let notes: [NoteState], cards: [CardState]
    let rows: [Row]
    let draftKeys: Set<String>
    let deckMembership: Set<UUID>?
    var changedRows: [Row] { rows.filter { $0.payload != nil } }
    var changedCards: Int { changedRows.reduce(0) { $0 + $1.cardCount } }
    var occurrences: Int { changedRows.flatMap(\.changes).reduce(0) { $0 + $1.count } }
    var skipped: Int { rows.filter { $0.skipReason != nil }.count }
}

enum ReplacementError: LocalizedError {
    case invalid, stale, empty, cancelled
    var errorDescription: String? {
        switch self {
        case .invalid: return "検索文字列と対象フィールドを指定してください。"
        case .stale: return "対象が編集・削除・移動されたため中断しました。プレビューを作り直してください。"
        case .empty: return "変更できるノートがありません。"
        case .cancelled: return "置換を中断しました。変更は保存していません。"
        }
    }
}
