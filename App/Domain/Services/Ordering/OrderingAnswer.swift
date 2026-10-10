import Foundation

struct OrderingToken: Identifiable, Equatable {
    let id: Int
    let text: String
    let comparison: String
}

enum OrderingError: LocalizedError {
    case unsupportedKind, tooShort, tooLong, notEnglish, symbols, identical, invalidDraft, incomplete
    var errorDescription: String? {
        switch self {
        case .unsupportedKind: return "並び替えは一問一答・記述式で利用できます。"
        case .tooShort: return "並び替えには空白で区切られた2語以上の英文が必要です。"
        case .tooLong: return "並び替えは40語・600文字以内、各語48文字以内、3行以内の英文に対応します。"
        case .notEnglish: return "並び替えには英字を含む英文を登録してください。"
        case .symbols: return "記号だけの語句は並び替えにできません。通常の回答方法を利用してください。"
        case .identical: return "すべて同じ語句のため語順を判定できません。通常の回答方法を利用してください。"
        case .invalidDraft: return "並び替えの下書きが変更されています。回答方法を切り替えてやり直してください。"
        case .incomplete: return "すべての語句を選んでから正誤判定してください。"
        }
    }
}

struct OrderingAnswer {
    let original: String
    let tokens: [OrderingToken]

    init(kind: NoteKind, answer: String) throws {
        guard [.basic, .written].contains(kind) else { throw OrderingError.unsupportedKind }
        guard answer.count <= 600, answer.split(whereSeparator: \.isNewline).count <= 3 else { throw OrderingError.tooLong }
        let words = answer.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2 else { throw OrderingError.tooShort }
        guard words.count <= 40, words.allSatisfy({ $0.count <= 48 }) else { throw OrderingError.tooLong }
        guard answer.unicodeScalars.contains(where: { (65...90).contains($0.value) || (97...122).contains($0.value) }) else { throw OrderingError.notEnglish }
        let tokens = words.enumerated().map { OrderingToken(id: $0.offset, text: $0.element, comparison: Self.normalized($0.element)) }
        guard tokens.allSatisfy({ !$0.comparison.isEmpty && $0.comparison.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) }) else { throw OrderingError.symbols }
        guard Set(tokens.map(\.comparison)).count > 1 else { throw OrderingError.identical }
        original = answer; self.tokens = tokens
    }

    static func normalized(_ word: String) -> String {
        word.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"“”‘’'()[]{}"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
    static func reason(kind: NoteKind, answer: String) -> String? {
        do { _ = try Self(kind: kind, answer: answer); return nil }
        catch { return error.localizedDescription }
    }
    func correct(_ ids: [Int]) -> Bool {
        guard ids.count == tokens.count, Set(ids) == Set(tokens.map(\.id)) else { return false }
        return ids.map { tokens[$0].comparison } == tokens.map(\.comparison)
    }
    func shuffled(using shuffle: ([Int]) -> [Int] = { $0.shuffled() }) -> [Int] {
        let ids = tokens.map(\.id)
        var pool = shuffle(ids)
        if pool.count != ids.count || Set(pool) != Set(ids) { pool = ids }
        if correct(pool), let other = pool.indices.first(where: { tokens[pool[$0]].comparison != tokens[pool[0]].comparison }) {
            pool.swapAt(0, other)
        }
        return pool
    }
}

// `to` is the final zero-based position after removal, not a swap index.
enum OrderingAction { case select(Int), remove(Int), move(Int, to: Int), reset, check }
enum OrderingResult: String, Codable { case correct, incorrect }

struct OrderingDraft: Codable, Equatable {
    var schemaVersion = 1
    let cardID: UUID
    let answer: String
    var pool: [Int]
    var selected: [Int] = []
    var result: OrderingResult?
    var firstAttemptCorrect: Bool?
    var attempts = 0
    var answerShown = false

    init(cardID: UUID, problem: OrderingAnswer, shuffle: ([Int]) -> [Int] = { $0.shuffled() }) {
        self.cardID = cardID; answer = problem.original; pool = problem.shuffled(using: shuffle)
    }
    func isValid(for problem: OrderingAnswer, cardID: UUID) -> Bool {
        schemaVersion == 1 && self.cardID == cardID && answer == problem.original &&
        pool.count == problem.tokens.count && Set(pool) == Set(problem.tokens.map(\.id)) && !problem.correct(pool) &&
        selected.count == Set(selected).count && Set(selected).isSubset(of: Set(pool)) &&
        (0...1_000_000).contains(attempts) && ((attempts == 0) == (firstAttemptCorrect == nil)) &&
        (result == nil || (attempts > 0 && selected.count == pool.count && (result == .correct) == problem.correct(selected)))
    }
    mutating func apply(_ action: OrderingAction, problem: OrderingAnswer) throws {
        guard isValid(for: problem, cardID: cardID) else { throw OrderingError.invalidDraft }
        switch action {
        case .select(let id):
            guard pool.contains(id), !selected.contains(id) else { throw OrderingError.invalidDraft }
            selected.append(id); result = nil
        case .remove(let id):
            guard selected.contains(id) else { throw OrderingError.invalidDraft }
            selected.removeAll { $0 == id }; result = nil
        case .move(let id, to: let destination):
            guard let source = selected.firstIndex(of: id), selected.indices.contains(destination) else {
                throw OrderingError.invalidDraft
            }
            if source != destination {
                selected.remove(at: source)
                selected.insert(id, at: destination)
                result = nil
            }
        case .reset: selected = []; result = nil
        case .check:
            guard selected.count == pool.count else { throw OrderingError.incomplete }
            let correct = problem.correct(selected)
            if firstAttemptCorrect == nil { firstAttemptCorrect = correct }
            attempts = min(attempts + 1, 1_000_000)
            result = correct ? .correct : .incorrect
        }
    }
    var evaluationGuidance: String {
        if firstAttemptCorrect == false || (answerShown && firstAttemptCorrect != true) {
            return "初回の誤答・答えの確認にはAgainが目安です。最終評価は自分で選んでください。"
        }
        return "初回正解はGoodが目安です。思い出しやすさに応じて最終評価を選んでください。"
    }
}
