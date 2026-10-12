import SwiftUI
import UIKit

struct LibraryView: View {
    @Bindable var store: StudyStore
    @Binding var shortcutDeck: ShortcutDeckDestination?
    var deckFilter: UUID? = nil
    @State private var clearedDeckFilter = false
    private var activeDeckFilter: UUID? { clearedDeckFilter ? nil : deckFilter }
    @State private var adding = false
    @State private var ocr = false
    @State private var importing = false
    @State private var addingDeck = false
    @State private var deckName = ""
    @State private var search = ""
    @State private var editMode = EditMode.inactive
    @State private var selection = Set<UUID>()
    @State private var replacing = false
    @State private var bulkEditing = false
    @State private var bulkCommitted = false

    @AppStorage("libraryExpandedDeckIDs") private var savedExpansion = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tree: LibraryTreeProjection?
    @State private var cardMarks: [UUID: CardMark] = [:]
    @State private var index: LibraryIndex?
    @State private var results = LibraryResults()
    @State private var loading = true
    @State private var libraryFailure: String?
    @State private var loadAttempt = 0

    init(store: StudyStore, shortcutDeck: Binding<ShortcutDeckDestination?>, deckFilter: UUID? = nil) {
        self.store = store
        _shortcutDeck = shortcutDeck
        self.deckFilter = deckFilter
        _savedExpansion = AppStorage(wrappedValue: "", "libraryExpandedDeckIDs.\(store.storageLocation.canonicalStore.lastPathComponent)")
    }

    private var hasSearch: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var emptyLibrary: some View {
        let isFirstCard = (index?.cardCount ?? 0) == 0 && !hasSearch
        return ContentUnavailableView {
            Label(isFirstCard ? "カードがありません" : (hasSearch ? "検索結果がありません" : "このデッキにはカードがありません"),
                  systemImage: hasSearch && !isFirstCard ? "magnifyingglass" : "rectangle.on.rectangle")
        } description: {
            Text(isFirstCard ? "問題と解答を登録して、学習を始めましょう。" : (hasSearch ? "問題・解答・デッキ・タグの検索条件を変えてください。" : "このデッキと下位デッキにカードを追加できます。"))
        } actions: {
            if isFirstCard || !hasSearch {
                Button(activeDeckFilter == nil ? "カードを追加" : "このデッキにカードを追加") {
                    selection.removeAll(); editMode = .inactive; adding = true
                }
                .buttonStyle(.borderedProminent).tint(Color("PrimaryAction"))
                .accessibilityIdentifier("emptyLibraryAdd")
                if isFirstCard {
                    Button("一括登録") { selection.removeAll(); editMode = .inactive; importing = true }
                        .buttonStyle(.bordered).accessibilityIdentifier("emptyLibraryImport")
                }
            }
            if hasSearch {
                Button("検索条件をクリア") { search = ""; selection.removeAll(); editMode = .inactive }
                    .buttonStyle(.bordered).accessibilityIdentifier("emptyLibraryClearSearch")
            }
            if activeDeckFilter != nil {
                Button("デッキの絞り込みを解除") {
                    clearedDeckFilter = true; selection.removeAll(); editMode = .inactive
                }
                .buttonStyle(.bordered).accessibilityIdentifier("emptyLibraryClearDeck")
            }
        }
    }

    private struct Request: Equatable {
        let revision: Int
        let query: String
        let deck: UUID?
        let tab: Int
        let attempt: Int
        let expansion: String
    }

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                Section {
                    NavigationLink { FlaggedCardsView(store: store) } label: { Label("フラグ付きカード", systemImage: "flag") }
                }
                Section("登録数") {
                    Text("登録全体: \(index?.noteCount ?? 0)ノート / \(index?.cardCount ?? 0)枚")
                        .accessibilityIdentifier("libraryTotalCounts")
                    if !search.isEmpty {
                        Text("表示中: \(results.noteCount)ノート / \(results.cardCount)枚")
                            .accessibilityIdentifier("libraryFilteredCounts")
                    }
                    Text("ノートは問題と解答のまとまり、カードは出題単位です。反転・穴埋め番号・画像マスクにより1ノートから複数枚を作成します。登録枚数は今日のユニーク学習枚数や延べ回答回数とは別です。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !editMode.isEditing {
                    Section {
                        NavigationLink("苦手カード・重点練習") { WeakCardListView(store: store) }
                            .accessibilityIdentifier("openWeakCards")
                    }
                }
                if let libraryFailure {
                    Section {
                        Label(libraryFailure, systemImage: "exclamationmark.triangle")
                        Button("再読み込み") { loadAttempt += 1 }
                    }
                }
                if loading { ProgressView("カードを読み込み中") }
                if results.cardCount == 0 && !loading && libraryFailure == nil {
                    emptyLibrary
                }
                ForEach(tree?.rows(expanded: LibraryTreeProjection.expandedIDs(savedExpansion)) ?? []) { row in
                    if let deck = row.deck {
                        Button {
                            guard row.expandable, search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            var expanded = LibraryTreeProjection.expandedIDs(savedExpansion)
                            if !expanded.insert(deck.id).inserted { expanded.remove(deck.id) }
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                                savedExpansion = LibraryTreeProjection.saveExpanded(expanded)
                            }
                            store.haptics.play(.reveal, mode: store.settings.hapticsMode)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: row.expandable ? (row.expanded ? "chevron.down" : "chevron.right") : "minus")
                                    .font(.caption).frame(width: 12).accessibilityHidden(true)
                                Image(systemName: row.expanded ? "folder.fill" : "folder").foregroundStyle(.secondary).accessibilityHidden(true)
                                Text(deck.name).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                Text(row.cardCount == 0 ? "空" : "\(row.cardCount)枚").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.leading, CGFloat(min(row.depth, 5)) * 12)
                            .frame(minHeight: 36).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("階層\(row.depth + 1)、\(deck.name)、配下\(row.cardCount)枚")
                        .accessibilityValue(row.expandable ? (row.expanded ? "展開中" : "折り畳み中") : "空のデッキ")
                        .accessibilityHint(row.expandable ? (row.expanded ? "折り畳む" : "展開する") : "")
                        .accessibilityIdentifier("libraryDeck-\(deck.id.uuidString)")
                    } else if let note = row.note {
                        if editMode.isEditing {
                            Button {
                                if note.cardIDs.isSubset(of: selection) { selection.subtract(note.cardIDs) }
                                else { selection.formUnion(note.cardIDs) }
                            } label: {
                                HStack {
                                    Image(systemName: note.cardIDs.isSubset(of: selection) ? "checkmark.circle.fill" : (selection.isDisjoint(with: note.cardIDs) ? "circle" : "minus.circle.fill"))
                                    LibraryCardRow(card: note.card, index: index, flag: cardMarks[note.card.id]?.flag)
                                }.foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(note.cardIDs.isSubset(of: selection) ? "選択中" : "未選択")
                            .padding(.leading, CGFloat(min(row.depth, 5)) * 12)
                        } else {
                            NavigationLink { NoteDetailView(store: store, cardID: note.card.id) } label: {
                                LibraryCardRow(card: note.card, index: index, flag: cardMarks[note.card.id]?.flag)
                            }.padding(.leading, CGFloat(min(row.depth, 5)) * 12)
                        }
                    }
                }
            }
            .task(id: Request(revision: store.dataRevision, query: search, deck: activeDeckFilter, tab: store.selectedTab, attempt: loadAttempt, expansion: savedExpansion)) {
                guard store.selectedTab == 1 else { return }
                let revision = store.dataRevision, query = search
                loading = true
                defer { if !Task.isCancelled { loading = false } }
                do {
                    if !query.isEmpty { try await Task.sleep(for: .milliseconds(150)) }
                    let allowed = try activeDeckFilter.map { try store.repository.descendants(of: $0) }
                    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    let metadata = try await store.libraryReader.load(revision: revision)
                    let found = query.isEmpty ? metadata.results(deckIDs: allowed) : try await store.libraryReader.search(query, revision: revision, deckIDs: allowed)
                    let decks = store.decks.filter { allowed?.contains($0.id) ?? true }
                    let projection = LibraryTreeProjection(decks: decks, index: metadata, results: found, search: query)
                    let expanded = LibraryTreeProjection.expandedIDs(savedExpansion)
                    let visibleExpanded = Set(projection.rows(expanded: expanded).filter(\.expanded).compactMap { $0.deck?.id })
                    let requested = query.isEmpty ? visibleExpanded : Set(found.cardsByDeck.keys)
                    let loaded = try await store.libraryReader.contents(revision: revision, deckIDs: requested)
                    try Task.checkCancellation()
                    guard revision == store.dataRevision else { return }
                    cardMarks = Dictionary(uniqueKeysWithValues: (try store.repository.options().cardMarks ?? []).map { ($0.cardID, $0) })
                    index = loaded; results = found; tree = projection; libraryFailure = nil
                    let valid = expanded.intersection(Set(store.decks.map(\.id)))
                    if valid != expanded { savedExpansion = LibraryTreeProjection.saveExpanded(valid) }
                    selection.formIntersection(found.cardIDs)
                } catch is CancellationError { }
                catch { if !Task.isCancelled { libraryFailure = error.localizedDescription } }
            }
            .environment(\.editMode, $editMode)
            .onChange(of: deckFilter) { _, _ in clearedDeckFilter = false; selection.removeAll(); editMode = .inactive }
            .onChange(of: search) { _, _ in selection.removeAll() }
            .onChange(of: editMode) { _, mode in if !mode.isEditing { selection.removeAll() } }
            .safeAreaInset(edge: .bottom) {
                if editMode.isEditing {
                    HStack {
                        Button("検索して置換") { replacing = true }.disabled(loading || libraryFailure != nil)
                        Menu("選択", systemImage: "checkmark.circle") {
                            Button("表示中を全選択") { selection = results.cardIDs }
                                .disabled(loading || libraryFailure != nil).accessibilityIdentifier("selectAllLibraryCards")
                            Button("選択を解除") { selection.removeAll() }
                                .disabled(selection.isEmpty)
                        }
                        Spacer()
                        Button("一括操作") { bulkCommitted = false; bulkEditing = true }
                            .buttonStyle(.borderedProminent).tint(Color("PrimaryAction")).foregroundStyle(Color.white)
                            .disabled(selection.isEmpty || loading || libraryFailure != nil).accessibilityIdentifier("openBulkManagement")
                    }.padding().background(.regularMaterial)
                }
            }
            .searchable(text: $search, prompt: "問題・解答・デッキ・タグを検索")
            .navigationTitle(editMode.isEditing ? "カードを選択" : (activeDeckFilter.flatMap { id in store.decks.first { $0.id == id }?.shortName } ?? "ライブラリ"))
            .onDisappear { selection.removeAll(); editMode = .inactive }
            .navigationDestination(item: $shortcutDeck) { destination in
                ShortcutDeckContentsView(store: store, deckID: destination.id)
            }
            .toolbar {
                if editMode.isEditing {
                    ToolbarItem(placement: .topBarLeading) {
                        Text("選択: \(selection.count)枚").accessibilityIdentifier("bulkSelectionCount")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完了") { selection.removeAll(); editMode = .inactive }
                            .accessibilityIdentifier("finishLibrarySelection")
                    }
                } else {
                    ToolbarItem(placement: .topBarLeading) { Button("デッキ管理") { addingDeck = true } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("ライブラリ操作", systemImage: "ellipsis.circle") {
                            Button("検索して置換", systemImage: "text.magnifyingglass") { replacing = true }
                                .disabled(loading || libraryFailure != nil)
                            Button("カードを選択", systemImage: "checkmark.circle") {
                                selection.removeAll(); editMode = .active
                            }.disabled(results.cardCount == 0 || loading || libraryFailure != nil).accessibilityIdentifier("selectLibraryCards")
                        }.accessibilityIdentifier("libraryActions")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("文字認識", systemImage: "text.viewfinder") { ocr = true }.accessibilityIdentifier("openOCR")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("一括登録", systemImage: "square.and.arrow.down") { importing = true }.accessibilityIdentifier("openImport")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("カード追加", systemImage: "plus") { adding = true }.keyboardShortcut("n", modifiers: .command).accessibilityIdentifier("addNote")
                    }
                }
            }
            .sheet(isPresented: $bulkEditing, onDismiss: {
                if bulkCommitted { selection.removeAll(); editMode = .inactive }
            }) {
                BulkManagementView(store: store, selection: selection, didCommit: { bulkCommitted = true }) { committed in
                    if committed { selection.removeAll(); editMode = .inactive }
                    bulkEditing = false
                }
            }
            .sheet(isPresented: $replacing) {
                TextReplacementView(store: store, resultIDs: results.cardIDs, selectedIDs: selection, initialDeckID: activeDeckFilter)
            }
            .sheet(isPresented: $adding) { NoteEditorView(store: store, item: nil, initialDeckID: activeDeckFilter) }
            .sheet(isPresented: $addingDeck) { DeckManagerView(store: store) }
            .sheet(isPresented: $importing) { ImportView(store: store) }
            .sheet(isPresented: $ocr) { OCRImportView(store: store) }

        }
    }
}

/// List creates row bodies on demand; hidden decks never render generated text.
struct LibraryCardRow: View {
    let card: LibraryCard
    let index: LibraryIndex?
    var flag: CardFlag? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let flag { CardFlagLabel(flag: flag) }
            Text((try? index?.displayed(card).question) ?? "カードを表示できません").lineLimit(2)
            if let count = index?.siblingCounts[card.noteID], count > 1 {
                Text("同じノートから\(count)枚").font(.caption).foregroundStyle(.secondary)
            }
            Text((index?.notes[card.noteID]?.kind.title ?? "") + (card.isSuspended ? " · 停止中" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct NoteDetailView: View {
    @Bindable var store: StudyStore
    let cardID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var item: NoteItem?
    @State private var siblingCount = 0
    @State private var detailFailure: String?

    var body: some View {
        Group {
            if let item {
                List {
                    Section("問題") { Text(item.content.question).textSelection(.enabled) }
                    if let id = item.sourceContent.imageID {
                        Section("画像") {
                            if let url = try? store.repository.assetURL(id: id), let image = UIImage(contentsOfFile: url.path) {
                                StudyImageView(image: image, masks: item.kind == .imageOcclusion ? (item.sourceContent.masks ?? []) : [],
                                               targetID: UUID(uuidString: String(item.variantKey.dropFirst("image:".count))),
                                               hideAll: item.sourceContent.hideAllMasks ?? true, revealed: true)
                            } else { Label("画像を読み込めません。編集から写真を再選択してください。", systemImage: "exclamationmark.triangle") }
                        }
                    }
                    Section("解答") { Text(item.content.answer).textSelection(.enabled) }
                    if !item.content.explanation.isEmpty { Section("解説") { Text(item.content.explanation) } }
                    if !item.tagNames.isEmpty { Section("タグ") { Text(item.tagNames.joined(separator: "、")) } }
                    Section("学習状態") {
                        LabeledContent("形式", value: item.kind.title)
                        LabeledContent("回答方法", value: item.responseMode.title)
                        LabeledContent("状態", value: LearningStatePresentation(state: item.summary.state).title)
                            .accessibilityIdentifier("noteState")
                        Text(LearningStatePresentation(state: item.summary.state).explanation)
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(LearningStatePresentation(state: item.summary.state).availability(suspended: item.isSuspended, due: item.summary.dueDate, now: store.clock()))
                            .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("noteAvailability")
                        LabeledContent("このノートのカード", value: "\(siblingCount)枚")
                        LabeledContent("このカードの延べ回答回数", value: "\(item.summary.repetitions)回")
                        LabeledContent("忘却回数", value: "\(item.summary.lapses)")
                        if item.summary.state != "new" {
                            LabeledContent("次回復習", value: item.summary.dueDate.formatted())
                                .accessibilityIdentifier("noteDue")
                        }
                        CardMarkControls(store: store, item: item)
                        Toggle("無期限で停止", isOn: Binding(get: { item.isSuspended }, set: { value in
                            store.perform { try store.repository.setSuspended(cardID: cardID, value: value, now: store.clock()) }
                        }))
                    }
                    Section { Button("カードを削除", role: .destructive) { confirmingDelete = true } }
                }
                .navigationTitle(item.kind.title)
                .toolbar { Button("編集") { editing = true }.accessibilityIdentifier("editNote") }
                .sheet(isPresented: $editing) { NoteEditorView(store: store, item: item) }
                .confirmationDialog("このノートの\(siblingCount)枚のカードを削除しますか？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("削除", role: .destructive) {
                        if store.perform({ try store.repository.deleteNote(id: item.noteID) }) { dismiss() }
                    }
                } message: { Text("同じノートの問題・解答とすべての兄弟カードを削除します。過去の回答履歴は残ります。") }
            } else if let detailFailure {
                ContentUnavailableView("カードを読み込めません", systemImage: "exclamationmark.triangle", description: Text(detailFailure))
            } else { ContentUnavailableView("カードがありません", systemImage: "rectangle") }
        }
        .task(id: store.dataRevision) {
            do {
                let loaded = try store.repository.noteItems(cardID: cardID).first
                let count = try loaded.map { try store.repository.siblingCardCount(noteID: $0.noteID) } ?? 0
                item = loaded; siblingCount = count; detailFailure = nil
            } catch { detailFailure = error.localizedDescription; item = nil }
        }
    }
}


private enum BulkOperation: String, CaseIterable {
    case move, addTags, removeTags, suspend, resume, delete
    var title: String {
        switch self {
        case .move: return "デッキ移動"
        case .addTags: return "タグ追加"
        case .removeTags: return "タグ除去"
        case .suspend: return "停止"
        case .resume: return "再開"
        case .delete: return "ノート削除"
        }
    }
}

private struct BulkManagementView: View {
    @Bindable var store: StudyStore
    let selection: Set<UUID>
    let didCommit: () -> Void
    let close: (Bool) -> Void
    @State private var operation = BulkOperation.move
    @State private var destination: UUID?
    @State private var tagText = ""
    @State private var removedTags = Set<UUID>()
    @State private var preview: BulkEditPreview?
    @State private var result: LibraryOperationCompletion?
    @State private var failure: String?
    @State private var confirmDelete = false
    @State private var checkpointWorking = false
    private var action: BulkEditAction? {
        switch operation {
        case .move: return destination.map(BulkEditAction.move)
        case .addTags: return .addTags(tagText.components(separatedBy: CharacterSet(charactersIn: ",、\n")))
        case .removeTags: return .removeTags(removedTags)
        case .suspend: return .suspended(true)
        case .resume: return .suspended(false)
        case .delete: return .deleteNotes
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                if let result {
                    LibraryOperationCompletionSection(store: store, result: result, identifier: "bulkResult")
                    Button("ライブラリへ戻る") { close(true) }.accessibilityIdentifier("closeBulkResult")
                } else {
                    Section {
                        Text("選択カード: \(selection.count)枚")
                        Picker("操作", selection: $operation) {
                            ForEach(BulkOperation.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.accessibilityIdentifier("bulkOperation")
                        if operation == .move {
                            DeckSelectionField("移動先", decks: store.decks, selection: $destination).accessibilityIdentifier("bulkDestination")
                        } else if operation == .addTags {
                            TextField("追加タグ（カンマ区切り）", text: $tagText).accessibilityIdentifier("bulkTagInput")
                        } else if operation == .removeTags {
                            if store.tags.isEmpty { Text("登録済みのタグがありません。") }
                            ForEach(store.tags) { tag in
                                Toggle(tag.name, isOn: Binding(get: { removedTags.contains(tag.id) }, set: { value in
                                    if value { removedTags.insert(tag.id) } else { removedTags.remove(tag.id) }
                                }))
                            }
                        }
                        Button("変更プレビュー") { prepare() }.disabled(action == nil).accessibilityIdentifier("previewBulkEdit")
                    }
                    if let preview {
                        Section("変更プレビュー") {
                            Text("選択 \(preview.selectedCount)枚 / 対象 \(preview.notes.count)ノート・\(preview.cards.count)枚")
                                .accessibilityIdentifier("bulkTargetCounts")
                            Text("変更: \(preview.changedNotes.count)ノート・\(preview.changedCount)枚").accessibilityIdentifier("bulkChangeCounts")
                            Text(preview.detail)
                            if case .suspended = preview.action {} else {
                                Text("選択カードが属するノート単位で変更します。選んでいない兄弟カードも含まれます。")
                                    .font(.footnote).fixedSize(horizontal: false, vertical: true)
                            }
                            if preview.changedCount == 0 { Text("変更対象はありません。すでに指定した状態です。") }
                            DisclosureGroup("対象ノートを確認（\(preview.rows.count)件）") {
                                ForEach(preview.rows) { row in
                                    VStack(alignment: .leading) {
                                        Text(row.question).lineLimit(3)
                                        Text("\(row.deck) · \(row.cardCount)枚").font(.caption)
                                    }
                                }
                            }
                            Button(preview.action.title, role: preview.action == .deleteNotes ? .destructive : nil) {
                                if preview.action == .deleteNotes { confirmDelete = true } else { commit(preview) }
                            }.disabled(preview.changedCount == 0).accessibilityIdentifier("applyBulkEdit")
                        }
                    }
                }
            }
            .disabled(checkpointWorking)
            .interactiveDismissDisabled(checkpointWorking)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("一括操作")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { close(result != nil) }.disabled(checkpointWorking).accessibilityIdentifier("closeBulkManagement") }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完了") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }.accessibilityIdentifier("dismissBulkKeyboard") }
            }
            .onChange(of: operation) { _, _ in preview = nil }
            .onChange(of: destination) { _, _ in preview = nil }
            .onChange(of: tagText) { _, _ in preview = nil }
            .onChange(of: removedTags) { _, _ in preview = nil }
            .confirmationDialog("対象ノートと兄弟カードを削除しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("ノートを削除", role: .destructive) { if let preview { commit(preview) } }.accessibilityIdentifier("confirmBulkDelete")
                Button("キャンセル", role: .cancel) {}
            } message: { Text("\(preview?.notes.count ?? 0)ノート・\(preview?.cards.count ?? 0)枚と関連編集下書きが削除されます。過去の回答履歴は残ります。") }
            .alert("一括操作を確定できません", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("閉じる", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }
    }
    private func prepare() {
        guard let action else { return }
        do { preview = try store.repository.previewBulkEdit(cardIDs: selection, action: action) }
        catch { preview = nil; failure = error.localizedDescription }
    }
    private func commit(_ value: BulkEditPreview) {
        guard result == nil, !checkpointWorking else { return }
        checkpointWorking = true
        Task {
            defer { checkpointWorking = false }
            do { try await store.createRestorePoint("ライブラリの一括操作") }
            catch { failure = error.localizedDescription; return }
            let targetName = operation == .move ? store.decks.first(where: { $0.id == destination })?.name : nil
            var receipt: BulkEditResult?
            let refreshed = store.perform { receipt = try store.repository.applyBulkEdit(value, now: store.clock()) }
            if let receipt {
                didCommit()
                result = LibraryOperationCompletion(operation: operation.title, notes: receipt.changedNotes,
                    cards: receipt.changedCards, targetName: targetName,
                    destinationID: operation == .move ? destination : nil,
                    warning: refreshed ? nil : "変更は保存済みですが、画面を更新できません。アプリを開き直してください。再実行は不要です。")
                if result?.isSuccess == true { store.haptics.play(.noteSaved, mode: store.settings.hapticsMode) }
                preview = nil
            } else { preview = nil; failure = store.failure ?? "変更は確定されていません。" }
            }
            store.failure = nil
        }
    }


    private struct WeakCardListView: View {
        @Bindable var store: StudyStore
        @State private var scope = LearningScope()
        @State private var days = 30
        @State private var rows: [WeakCardItem] = []
        @State private var failure: String?
        @State private var practice: WeakPracticeSession?

        var body: some View {
            List {
                Section("絞り込み") {
                    DeckSelectionField("デッキ（子孫を含む）", decks: store.decks, selection: $scope.deckID, nilTitle: "すべてのデッキ", includesDescendants: true)
                    Picker("履歴の期間", selection: $days) {
                        ForEach([7, 30, 90, 0], id: \.self) { Text($0 == 0 ? "全期間" : "\($0)日").tag($0) }
                    }

                }
                ContextualTagFilterSections(store: store, scope: $scope)
                Section {
                    Text("直近Again、Again2回以上、3回答以上でAgain割合30%以上・難易度8以上・推定想起確率75%未満を基準に抽出します。停止中・未学習は除外します。タグはすべて含む条件です。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("重点練習では復習予定・FSRS・回答履歴・今日の学習枚数を変更しません。正式な評価はホームの通常学習で行います。")
                        .font(.footnote)
                    Button("重点練習を始める") {
                        do {
                            practice = try store.repository.weakPractice(scope: scope, days: days == 0 ? nil : days, now: store.clock())
                            failure = nil
                        } catch { failure = error.localizedDescription }
                    }.disabled(rows.isEmpty).accessibilityIdentifier("startWeakPractice")
                    Text("兄弟カードは通常の同日抑制に加え、練習内でも1ノート1枚に制限します（短期学習は例外）。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let failure { Section { Text(failure).foregroundStyle(.red); Button("再試行") { refresh() } } }
                if rows.isEmpty && failure == nil { Text("この条件の苦手カードはありません。期間やデッキ・タグを変更してください。") }
                Section("苦手カード：\(rows.count)枚") {
                    ForEach(rows) { row in
                        NavigationLink { NoteDetailView(store: store, cardID: row.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(row.card.content.question).lineLimit(2)
                                Text(row.card.deckName).font(.caption).foregroundStyle(.secondary)
                                ForEach(row.evidence.reasons, id: \.self) { Text($0).font(.footnote) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("苦手カード")
            .task { refresh() }
            .onChange(of: scope) { _, _ in refresh() }
            .onChange(of: days) { _, _ in refresh() }
            .sheet(item: $practice, onDismiss: { refresh() }) { session in
                WeakPracticeView(store: store, initial: session, conditions: practiceConditions)
        }
    }
    private var practiceConditions: String {
        let deck = scope.deckID.flatMap { id in store.decks.first { $0.id == id }?.name } ?? "すべてのデッキ"
        let period = days == 0 ? "全期間" : "直近\(days)日"
        let tags = scope.tagIDs.compactMap { id in store.tags.first { $0.id == id }?.name }
        let tagDescription = tags.isEmpty ? "タグ指定なし" : "タグ：" + tags.joined(separator: "、") + "（すべて含む）"
        return "\(deck)（子孫を含む）・\(period)・\(tagDescription)"
    }
    private func refresh() {
        do { rows = try store.repository.weakCards(scope: scope, days: days == 0 ? nil : days, now: store.clock()); failure = nil }
        catch { rows = []; failure = error.localizedDescription }
    }
}

private struct WeakPracticeView: View {
    @Bindable var store: StudyStore
    @Environment(\.dismiss) private var dismiss
    @State private var session: WeakPracticeSession
    let conditions: String
    init(store: StudyStore, initial: WeakPracticeSession, conditions: String) {
        self.conditions = conditions
        self.store = store; _session = State(initialValue: initial)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("練習のみ・復習予定と学習履歴は変更しません")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let item = session.current {
                        Text("\(session.index + 1)／\(session.cards.count)枚")
                        Text(item.content.question).font(.title2).accessibilityIdentifier("weakPracticeQuestion")
                        if let id = item.sourceContent.imageID {
                            if let url = try? store.repository.assetURL(id: id), let image = UIImage(contentsOfFile: url.path) {
                                StudyImageView(image: image, masks: item.kind == .imageOcclusion ? item.sourceContent.masks ?? [] : [],
                                    targetID: UUID(uuidString: String(item.variantKey.dropFirst("image:".count))),
                                    hideAll: item.sourceContent.hideAllMasks ?? true, revealed: session.revealed)
                            } else { Text("画像を読み込めません。ライブラリで画像を確認してください。") }
                        }
                        if session.revealed {
                            Text(item.content.answer).accessibilityIdentifier("weakPracticeAnswer")
                            if !item.content.explanation.isEmpty { Text(item.content.explanation).foregroundStyle(.secondary) }
                            Button("次のカード") {
                                session.next()
                                if session.phase == .completed { store.haptics.play(.reveal, mode: store.settings.hapticsMode) }
                            }.accessibilityIdentifier("nextWeakPractice")
                        } else {
                            StudyHintView(hint: item.content.hint).id(item.cardID)
                            Button("答えを表示") { session.reveal() }.accessibilityIdentifier("revealWeakPractice")
                        }
                        if session.index > 0 { Button("前のカード") { session.previous() } }
                    } else if session.phase == .completed {
                        VStack(spacing: 24) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 68)).foregroundStyle(.green).accessibilityHidden(true)
                            Text("重点練習が完了しました").font(.title2.bold())
                                .accessibilityIdentifier("weakPracticeCompleted")
                            Text("練習したカード：\(session.completedCount)枚")
                                .accessibilityIdentifier("weakPracticeCompletedCount")
                            Text(conditions).font(.footnote).foregroundStyle(.secondary)
                            Text("練習のみです。FSRS・回答履歴・復習予定は変更されていません。正式な復習はホームから行えます。")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("同じカードをもう一度練習する") { session.restart() }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                                .accessibilityIdentifier("restartWeakPractice")
                            Button("苦手カード一覧に戻る") { dismiss() }.accessibilityIdentifier("finishWeakPractice")
                        }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else {
                        ContentUnavailableView("練習するカードがありません", systemImage: "rectangle.on.rectangle",
                                               description: Text("苦手カード一覧で対象条件を変更してください。"))
                        Button("苦手カード一覧に戻る") { dismiss() }.accessibilityIdentifier("finishWeakPractice")
                    }
                }.padding()
            }
            .navigationTitle("重点練習")
            .toolbar { Button("終了") { dismiss() } }
        }
    }
}

/// Shared completion layout. Feedback belongs to commit, never view appearance.
struct LibraryOperationCompletionSection: View {
    let store: StudyStore
    let result: LibraryOperationCompletion
    let identifier: String
    @State private var announced = false
    var body: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "info.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(result.isSuccess ? Color.green : Color.orange)
                    .accessibilityHidden(true)
                Text(result.title).font(.headline)
                Text(result.summary).accessibilityIdentifier(identifier)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .accessibilityElement(children: .combine)
            if result.operation == "削除" || result.operation == "ノート削除" {
                Text("削除したカードは元に戻せません。過去の回答履歴は残ります。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let warning = result.warning {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let destination = result.destinationID {
                NavigationLink("移動先を見る") { ShortcutDeckContentsView(store: store, deckID: destination) }
            }
        }
        .task {
            guard !announced else { return }
            announced = true
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement,
                    argument: result.title + "。" + result.summary + "。" + (result.warning ?? ""))
            }
        }
    }
}

struct CardFlagLabel: View {
    let flag: CardFlag
    var body: some View {
        Label("フラグ: " + flag.title, systemImage: "flag.fill")
            .foregroundStyle(flag == .red ? Color.red : (flag == .blue ? Color.blue : Color.orange))
    }
}
struct CardMarkControls: View {
    @Bindable var store: StudyStore
    let item: NoteItem
    var body: some View {
        Picker("フラグ", selection: Binding<CardFlag?>(get: { item.flag }, set: { flag in
            store.perform { try store.repository.setFlags(cardIDs: [item.cardID], flag: flag) }
        })) {
            Text("なし").tag(Optional<CardFlag>.none)
            ForEach(CardFlag.allCases) { Text($0.title).tag(Optional($0)) }
        }
        if let flag = item.flag { CardFlagLabel(flag: flag) }
        if let until = item.hiddenUntil, store.clock() < until {
            Text("今日の出題対象外（" + until.formatted() + "まで）")
            Button("今日の出題対象に戻す") { store.perform { try store.repository.showToday(cardID: item.cardID) } }
        } else {
            Button("今日は表示しない") { store.perform { try store.repository.hideToday(cardID: item.cardID, now: store.clock()) } }
        }
        Text("フラグと当日非表示は評価を保存せず、復習予定を変更しません。")
            .font(.footnote).foregroundStyle(.secondary)
    }
}
struct FlaggedCardsView: View {
    @Bindable var store: StudyStore
    @State private var items: [NoteItem] = []
    @State private var search = ""
    @State private var flag: CardFlag?
    @State private var selection: Set<UUID> = []
    @State private var failure: String?
    private var visible: [NoteItem] {
        items.filter { item in
            (flag == nil || item.flag == flag) && (search.isEmpty ||
                [item.content.question, item.content.answer, item.deckName].joined(separator: " ").localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        List(selection: $selection) {
            Section {
                Picker("フラグ", selection: $flag) {
                    Text("すべて").tag(Optional<CardFlag>.none)
                    ForEach(CardFlag.allCases) { Text($0.title).tag(Optional($0)) }
                }
                Text("フラグは色の目印です。色の用途は自由に決められます。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let failure { Text(failure).foregroundStyle(.red) }
            if visible.isEmpty { Text("該当するフラグ付きカードはありません") }
            ForEach(visible) { item in
                NavigationLink { NoteDetailView(store: store, cardID: item.cardID) } label: {
                    VStack(alignment: .leading) {
                        Text(item.content.question).lineLimit(2)
                        if let flag = item.flag { CardFlagLabel(flag: flag) }
                        Text(item.deckName).font(.caption).foregroundStyle(.secondary)
                    }
                }.tag(item.cardID)
            }
        }
        .navigationTitle("フラグ付きカード")
        .searchable(text: $search, prompt: "問題・解答・デッキを検索")
        .toolbar { EditButton() }
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                Button("選択した\(selection.count)枚のフラグを解除") {
                    if store.perform({ try store.repository.setFlags(cardIDs: selection, flag: nil) }) { selection.removeAll() }
                }.buttonStyle(.bordered).padding().background(.regularMaterial)
            }
        }
        .task(id: store.dataRevision) {
            do {
                let ids = (try store.repository.options().cardMarks ?? []).filter { $0.flag != nil }.map(\.cardID)
                items = try store.repository.noteItems(cardIDs: Set(ids))
                selection.formIntersection(Set(visible.map(\.cardID)))
                failure = nil
            } catch { failure = error.localizedDescription }
        }
        .onChange(of: search) { _, _ in selection.removeAll() }
        .onChange(of: flag) { _, _ in selection.removeAll() }
    }
}
