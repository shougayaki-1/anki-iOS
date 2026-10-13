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
    var typedAnswerPolicy: TypedAnswerPolicy? = nil
    // Optional fields preserve decoding of existing .studybackup preference JSON.
    // nil = default 20 answers; 0 = unlimited.
    var sessionAnswerLimit: Int? = nil
    var cardMarks: [CardMark]? = nil
    var fsrsOptimization: FSRSOptimizationState? = nil
    var deckLearning: [DeckLearningOverride]? = nil
    var deckNewUsage: [DeckNewUsage]? = nil
    var sessionResponseMode: SessionResponseMode? = nil
    var librarySearch: LibrarySearchPreferences? = nil
    var activeSessionProgress: StudySessionProgressSnapshot? = nil
}

// The session boundary is the last persisted ReviewLog sequence when the session starts.
// This is stored separately from the daily unique-card goal and survives app relaunch.
struct StudySessionProgressSnapshot: Codable, Equatable {
    var startSequence: Int
    var answerLimit: Int
    var responseMode: SessionResponseMode? = nil
    // Display-only estimate; missing in sessions saved by older app versions.
    var initialEligibleCount: Int? = nil
    var reviewOrderPolicy: ReviewOrderPolicy? = nil
    var reviewOrder: [UUID]? = nil
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

struct TagFilterNote {
    let deckID: UUID
    let tagIDs: Set<UUID>
    let cards: Int
}
struct TagFilterCandidate: Identifiable {
    let id: UUID
    let name: String
    let cards: Int
    let paths: [String]
}
struct TagFilterGroup: Identifiable {
    let id: String
    let title: String
    let tags: [TagFilterCandidate]
}
struct TagFilterSummary {
    var groups: [TagFilterGroup] = []
    var cards = 0
    var unavailable: Set<UUID> = []
}
struct TagFilterIndex {
    let decks: [DeckItem]
    let tags: [TagItem]
    let notes: [TagFilterNote]

    func summary(scope: LearningScope) -> TagFilterSummary {
        let deckMap = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, $0) })
        var children: [UUID: [UUID]] = [:]
        for deck in decks {
            if let parent = deck.parentID, deckMap[parent] != nil { children[parent, default: []].append(deck.id) }
        }
        var allowed: Set<UUID>?
        if let selected = scope.deckID {
            var ids: Set<UUID> = [selected], pending = [selected]
            while let next = pending.popLast() {
                for child in children[next] ?? [] where ids.insert(child).inserted { pending.append(child) }
            }
            allowed = ids
        }
        let included = notes.filter { $0.cards > 0 && (allowed?.contains($0.deckID) ?? true) }
        let usedDecks = Set(included.map(\.deckID))
        // Group by the actual root. If a single common container owns the data,
        // skip its single-child chain and use the first branching level as context.
        func chain(_ id: UUID) -> [UUID] {
            var result: [UUID] = [], seen: Set<UUID> = [], current: UUID? = id
            while let value = current, seen.insert(value).inserted, let deck = deckMap[value] {
                result.append(value); current = deck.parentID
            }
            return result.reversed()
        }
        let chains = Dictionary(uniqueKeysWithValues: usedDecks.map { ($0, chain($0)) })
        let rootIDs = Set(chains.values.compactMap(\.first))
        var activeBranches: [UUID: Set<UUID>] = [:]
        for path in chains.values where path.count > 1 {
            for position in 0..<(path.count - 1) { activeBranches[path[position], default: []].insert(path[position + 1]) }
        }
        var groupDeck: [UUID: UUID] = [:]
        for (deck, path) in chains {
            var position = 0
            if rootIDs.count == 1 {
                while position + 1 < path.count {
                    let ancestor = path[position]
                    let activeChildren = activeBranches[ancestor] ?? []
                    position += 1
                    if activeChildren.count > 1 { break }
                }
            }
            groupDeck[deck] = path.isEmpty ? deck : path[position]
        }
        var counts: [UUID: Int] = [:], usage: [UUID: Set<UUID>] = [:]
        let selected = Set(scope.tagIDs)
        var result = TagFilterSummary()
        for note in included {
            if selected.isSubset(of: note.tagIDs) { result.cards += note.cards }
            for tag in note.tagIDs {
                counts[tag, default: 0] += note.cards
                usage[tag, default: []].insert(note.deckID)
            }
        }
        result.unavailable = selected.subtracting(Set(counts.keys))
        var groups: [String: [TagFilterCandidate]] = [:], titles: [String: String] = [:]
        for tag in tags {
            guard let count = counts[tag.id], let used = usage[tag.id] else { continue }
            let key: String, title: String
            if used.count > 1 { key = "shared"; title = "複数デッキで使用" }
            else {
                let id = used.first.flatMap { groupDeck[$0] } ?? used.first!
                key = id.uuidString; title = deckMap[id]?.name ?? "デッキ"
            }
            titles[key] = title
            groups[key, default: []].append(TagFilterCandidate(id: tag.id, name: tag.name, cards: count,
                paths: used.compactMap { deckMap[$0]?.name }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }))
        }
        result.groups = groups.map { key, tags in
            TagFilterGroup(id: key, title: titles[key]!, tags: tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }.sorted {
            if $0.id == "shared" { return false }
            if $1.id == "shared" { return true }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        return result
    }
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

struct ImportDestination: Identifiable {
    let id: UUID
    let name: String
}

struct ImportResult {
    enum Outcome { case complete, partial, empty }
    var outcome: Outcome {
        guard imported > 0 else { return .empty }
        return skipped > 0 || !errors.isEmpty ? .partial : .complete
    }
    var affectedCardIDs: Set<UUID> = []
    var destinations: [ImportDestination] = []
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
    static let distance = 96.0
    static let dominance = 1.5
    var title: String {
        switch self {
        case .reveal: return "答えを表示"
        case .grade(.again): return "Again"
        case .grade(.hard): return "Hard"
        case .grade(.good): return "Good"
        case .grade(.easy): return "Easy"
        }
    }
    var symbol: String {
        switch self {
        case .reveal, .grade(.good): return "arrow.right"
        case .grade(.again): return "arrow.left"
        case .grade(.hard): return "arrow.down"
        case .grade(.easy): return "arrow.up"
        }
    }
    static func candidate(x: Double, y: Double, revealed: Bool) -> Self? {
        guard x.isFinite, y.isFinite, max(abs(x), abs(y)) > 0 else { return nil }
        if abs(x) >= abs(y) * dominance {
            if !revealed { return x > 0 ? .reveal : nil }
            return .grade(x > 0 ? .good : .again)
        }
        if revealed && abs(y) >= abs(x) * dominance {
            return .grade(y > 0 ? .hard : .easy)
        }
        return nil
    }
    static func decide(x: Double, y: Double, revealed: Bool) -> Self? {
        guard max(abs(x), abs(y)) >= distance else { return nil }
        return candidate(x: x, y: y, revealed: revealed)
    }
}

struct ReviewSwipeProgress: Equatable {
    var candidate: ReviewSwipeAction?
    var fraction = 0.0
    var ready = false
    var feedback = false
    static let idle = Self()
}

struct ReviewSwipeGate {
    private var start: (id: UUID, revealed: Bool)?
    private var lastAction: Date?
    private var invalidated = false
    private var feedbackArmed = true
    private var lastFeedback: Date?
    private(set) var gavePreparationFeedback = false
    mutating func begin(id: UUID, revealed: Bool) {
        if start == nil && !invalidated { start = (id, revealed) }
    }
    mutating func cancel() {
        start = nil; invalidated = false; feedbackArmed = true
        gavePreparationFeedback = false; lastFeedback = nil
    }
    mutating func invalidate() { if start != nil { invalidated = true } }
    private func accepts(id: UUID, revealed: Bool, now: Date, enabled: Bool) -> Bool {
        enabled && !invalidated && start?.id == id && start?.revealed == revealed &&
        (lastAction == nil || now.timeIntervalSince(lastAction!) >= 0.6)
    }
    mutating func update(id: UUID, revealed: Bool, x: Double, y: Double, now: Date,
                         enabled: Bool = true) -> ReviewSwipeProgress {
        guard accepts(id: id, revealed: revealed, now: now, enabled: enabled),
              x.isFinite, y.isFinite else { return .idle }
        let magnitude = max(abs(x), abs(y))
        // Rearm only after a substantial retreat, not on diagonal/direction jitter.
        if magnitude < ReviewSwipeAction.distance * 0.75 { feedbackArmed = true }
        let candidate = ReviewSwipeAction.candidate(x: x, y: y, revealed: revealed)
        let ready = ReviewSwipeAction.decide(x: x, y: y, revealed: revealed) != nil
        let feedback = ready && feedbackArmed &&
            (lastFeedback == nil || now.timeIntervalSince(lastFeedback!) >= 0.3)
        if feedback {
            feedbackArmed = false; lastFeedback = now; gavePreparationFeedback = true
        }
        return ReviewSwipeProgress(candidate: candidate,
                                   fraction: candidate == nil ? 0 : min(magnitude / ReviewSwipeAction.distance, 1),
                                   ready: ready, feedback: feedback)
    }
    mutating func finish(id: UUID, revealed: Bool, x: Double, y: Double, now: Date,
                         enabled: Bool = true) -> ReviewSwipeAction? {
        defer { cancel() }
        guard accepts(id: id, revealed: revealed, now: now, enabled: enabled),
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

struct TypedAnswerPolicy: Codable, Equatable {
    var enabled = false
    // 0 explicitly means until manually deleted; default is 30 days.
    var retentionDays = 30
    static let supportedDays = [7, 30, 90, 0]
}
struct TypedAnswerRecord: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let cardID: UUID
    let reviewedAt: Date
    let grade: Int
    let question: String
    let answer: String
    let modelAnswer: String
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

// Metadata is indexed once. Detailed content and FSRS snapshots are not list models.
struct LibraryCard: Identifiable {
    let id: UUID
    let noteID: UUID
    let deckID: UUID
    let variantKey: String
    let isSuspended: Bool
    let createdAt: Date
}

struct LibraryNote {
    let kind: NoteKind
    var content: TextContent?
    let deckName: String
    let tagNames: String
}

struct LibraryRowContent: Equatable {
    let question: String
    let kindTitle: String
    let siblingCount: Int
    let isSuspended: Bool
}

struct LibraryIndex {
    var rowContents: [UUID: LibraryRowContent] = [:]
    var notes: [UUID: LibraryNote] = [:]
    var cardsByDeck: [UUID: [LibraryCard]] = [:]
    var siblingCounts: [UUID: Int] = [:]
    var cardCount = 0
    var noteCount: Int { siblingCounts.count }

    func displayed(_ card: LibraryCard) throws -> TextContent {
        guard let note = notes[card.noteID], let content = note.content else { throw StudyError.missingRecord }
        return try CardGeneration.displayed(kind: note.kind, content: content, variant: card.variantKey)
    }

    func results(deckIDs: Set<UUID>? = nil, matching: Set<UUID>? = nil) -> LibraryResults {
        var groups: [UUID: [LibraryCard]] = [:], noteIDs = Set<UUID>(), count = 0
        for (deck, cards) in cardsByDeck where deckIDs?.contains(deck) ?? true {
            let included = matching.map { ids in cards.filter { ids.contains($0.id) } } ?? cards
            guard !included.isEmpty else { continue }
            groups[deck] = included
            count += included.count
            for card in included { noteIDs.insert(card.noteID) }
        }
        return LibraryResults(cardsByDeck: groups, noteCount: noteIDs.count, cardCount: count)
    }

    static func deckPaths(_ decks: [Deck]) -> [UUID: String] {
        let byID = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, $0) })
        return Dictionary(uniqueKeysWithValues: decks.map { deck in
            var names: [String] = [], current: UUID? = deck.id, seen = Set<UUID>()
            while let id = current, seen.insert(id).inserted, let value = byID[id] {
                names.append(value.name); current = value.parentID
            }
            return (deck.id, names.reversed().joined(separator: " / "))
        })
    }
}

struct LibraryResults {
    var cardsByDeck: [UUID: [LibraryCard]] = [:]
    var noteCount = 0
    var cardCount = 0
    var cardIDs: Set<UUID> { Set(cardsByDeck.values.joined().map(\.id)) }
}

// Counts and note grouping are prepared once per library revision/search result.
// Expanding a folder only flattens the visible branches of the shared deck tree.
struct LibraryNoteRow: Identifiable {
    let card: LibraryCard
    let cardIDs: Set<UUID>
    var id: UUID { card.noteID }
}

struct LibraryTreeRow: Identifiable {
    let deck: DeckTreeNode?
    let note: LibraryNoteRow?
    let depth: Int
    let cardCount: Int
    let expanded: Bool
    let expandable: Bool
    var id: String { deck.map { "deck-\($0.id)" } ?? "note-\(note!.id)" }
}

struct LibraryTreeProjection {
    let roots: [DeckTreeNode]
    let notesByDeck: [UUID: [LibraryNoteRow]]
    let subtreeCards: [UUID: Int]
    let searchDeckIDs: Set<UUID>?

    init(decks: [DeckItem], index: LibraryIndex, results: LibraryResults, search: String) {
        let roots = DeckTreeBuilder.roots(from: decks)
        self.roots = roots
        var groups: [UUID: [LibraryNoteRow]] = [:]
        for (deck, cards) in results.cardsByDeck {
            var order: [UUID] = [], byNote: [UUID: [LibraryCard]] = [:]
            for card in cards {
                if byNote[card.noteID] == nil { order.append(card.noteID) }
                byNote[card.noteID, default: []].append(card)
            }
            groups[deck] = order.compactMap { id in
                guard let cards = byNote[id], let first = cards.first else { return nil }
                return LibraryNoteRow(card: first, cardIDs: Set(cards.map(\.id)))
            }
        }
        notesByDeck = groups
        var counts: [UUID: Int] = [:], included = Set<UUID>()
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        func visit(_ node: DeckTreeNode, path: String) -> Bool {
            let path = path.isEmpty ? node.name : "\(path) / \(node.name)"
            var found = groups[node.id]?.isEmpty == false || path.localizedCaseInsensitiveContains(query)
            var count = index.cardsByDeck[node.id]?.count ?? 0
            for child in node.children {
                if visit(child, path: path) { found = true }
                count += counts[child.id] ?? 0
            }
            counts[node.id] = count
            if found { included.insert(node.id) }
            return found
        }
        for root in roots { _ = visit(root, path: "") }
        subtreeCards = counts
        searchDeckIDs = query.isEmpty ? nil : included
    }

    func rows(expanded: Set<UUID>) -> [LibraryTreeRow] {
        var result: [LibraryTreeRow] = []
        func visit(_ node: DeckTreeNode, depth: Int) {
            if let included = searchDeckIDs, !included.contains(node.id) { return }
            let open = searchDeckIDs != nil || expanded.contains(node.id)
            result.append(LibraryTreeRow(deck: node, note: nil, depth: depth,
                                         cardCount: subtreeCards[node.id] ?? 0, expanded: open,
                                         expandable: !node.children.isEmpty || (subtreeCards[node.id] ?? 0) > 0))
            guard open else { return }
            for note in notesByDeck[node.id] ?? [] {
                result.append(LibraryTreeRow(deck: nil, note: note, depth: depth + 1,
                                             cardCount: note.cardIDs.count, expanded: false, expandable: false))
            }
            for child in node.children { visit(child, depth: depth + 1) }
        }
        for root in roots { visit(root, depth: 0) }
        return result
    }

    static func expandedIDs(_ saved: String) -> Set<UUID> {
        Set(saved.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }
    static func saveExpanded(_ ids: Set<UUID>) -> String {
        ids.map(\.uuidString).sorted().joined(separator: ",")
    }
}

/// A receipt is created only after persistence succeeds. Warnings never reopen the operation.
struct LibraryOperationCompletion {
    let operation: String
    let notes: Int
    let cards: Int
    let targetName: String?
    let destinationID: UUID?
    var warning: String?
    var hasChanges: Bool { notes > 0 || cards > 0 }
    var isSuccess: Bool { hasChanges && warning == nil }
    var title: String { hasChanges ? "\(operation)を保存しました" : "変更対象はありません" }
    var summary: String {
        "\(operation)：\(notes)ノート・\(cards)枚" + (targetName.map { " · \($0)" } ?? "")
    }
}

// Card-keyed optional metadata keeps old stores and backup JSON readable without a schema migration.
enum CardFlag: String, Codable, CaseIterable, Identifiable {
    case red, blue, yellow
    var id: Self { self }
    var title: String {
        switch self { case .red: return "赤"; case .blue: return "青"; case .yellow: return "黄" }
    }
}
struct CardMark: Codable, Equatable {
    let cardID: UUID
    var flag: CardFlag?
    var hiddenUntil: Date?
}

// Conditions are shared by the reader and UI; saved searches never retain card IDs.
struct LibrarySearchConditions: Codable, Equatable {
    var text = ""
    var deckID: UUID?
    var descendants = true
    var tags: [UUID] = []
    var anyTag = false
    var state = LibrarySearchState.all
    var dueOnly = false
    var againToday = false
    var reviewedDays = 0
    var minimumLapses = 0
    var minimumDifficulty = 0.0
    var maximumRecall = 1.0
    var missingFSRS = false
    var flag: CardFlag?
    var oldestFirst = false
    var requiresSchedule: Bool {
        state != .all || minimumLapses > 0 || minimumDifficulty > 0 || maximumRecall < 1 || missingFSRS
    }
}
struct SavedLibrarySearch: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var conditions: LibrarySearchConditions
}
struct LibrarySearchPreferences: Codable, Equatable {
    var current = LibrarySearchConditions()
    var saved: [SavedLibrarySearch] = []
}

enum LibrarySearchState: String, Codable, CaseIterable {
    case all, new, learning, relearning, review, suspended
}
