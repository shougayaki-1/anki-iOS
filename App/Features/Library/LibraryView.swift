import SwiftUI

struct LibraryView: View {
    @Bindable var store: StudyStore
    @Binding var shortcutDeck: ShortcutDeckDestination?
    @State private var adding = false
    @State private var ocr = false
    @State private var importing = false
    @State private var addingDeck = false
    @State private var deckName = ""
    @State private var search = ""
    @State private var editMode = EditMode.inactive
    @State private var selection = Set<UUID>()
    @State private var bulkEditing = false
    @State private var bulkCommitted = false

    var filtered: [NoteItem] {
        store.notes.filter {
            search.isEmpty || "\($0.content.question) \($0.content.answer) \($0.deckName) \($0.tagNames.joined(separator: " "))".localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        let counts = Dictionary(grouping: store.notes, by: \.noteID).mapValues(\.count)
        NavigationStack {
            List(selection: $selection) {
                Section("登録数") {
                    Text("登録全体: \(counts.count)ノート / \(store.notes.count)枚")
                        .accessibilityIdentifier("libraryTotalCounts")
                    if !search.isEmpty {
                        Text("表示中: \(Set(filtered.map(\.noteID)).count)ノート / \(filtered.count)枚")
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
                if filtered.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "カードがありません" : "検索結果がありません", systemImage: search.isEmpty ? "rectangle.on.rectangle" : "magnifyingglass",
                                           description: Text(search.isEmpty ? "＋からカードを追加できます。写真の文字認識やファイルの一括登録も使えます。" : "問題・解答・デッキ・タグのキーワードを変えて検索してください。"))
                }
                ForEach(store.decks) { deck in
                    Section(deck.name) {
                        ForEach(filtered.filter { $0.deckID == deck.id }) { item in
                            if editMode.isEditing {
                                cardRow(item, siblingCount: counts[item.noteID] ?? 1).tag(item.cardID)
                            } else {
                                NavigationLink { NoteDetailView(store: store, cardID: item.cardID) } label: { cardRow(item, siblingCount: counts[item.noteID] ?? 1) }
                            }
                        }
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .onChange(of: search) { _, _ in selection.removeAll() }
            .onChange(of: editMode) { _, mode in if !mode.isEditing { selection.removeAll() } }
            .safeAreaInset(edge: .bottom) {
                if editMode.isEditing {
                    HStack {
                        Menu("選択", systemImage: "checkmark.circle") {
                            Button("表示中を全選択") { selection = Set(filtered.map(\.cardID)) }
                                .accessibilityIdentifier("selectAllLibraryCards")
                            Button("選択を解除") { selection.removeAll() }
                                .disabled(selection.isEmpty)
                        }
                        Spacer()
                        Button("一括操作") { bulkCommitted = false; bulkEditing = true }
                            .buttonStyle(.borderedProminent).tint(Color("PrimaryAction")).foregroundStyle(Color.white)
                            .disabled(selection.isEmpty).accessibilityIdentifier("openBulkManagement")
                    }.padding().background(.regularMaterial)
                }
            }
            .searchable(text: $search, prompt: "問題・解答・デッキ・タグを検索")
            .navigationTitle(editMode.isEditing ? "カードを選択" : "ライブラリ")
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
                            Button("カードを選択", systemImage: "checkmark.circle") {
                                selection.removeAll(); editMode = .active
                            }.disabled(filtered.isEmpty).accessibilityIdentifier("selectLibraryCards")
                        }.accessibilityIdentifier("libraryActions")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("文字認識", systemImage: "text.viewfinder") { ocr = true }.accessibilityIdentifier("openOCR")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("一括登録", systemImage: "square.and.arrow.down") { importing = true }.accessibilityIdentifier("openImport")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("カード追加", systemImage: "plus") { adding = true }.accessibilityIdentifier("addNote")
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
            .sheet(isPresented: $adding) { NoteEditorView(store: store, item: nil) }
            .sheet(isPresented: $addingDeck) { DeckManagerView(store: store) }
            .sheet(isPresented: $importing) { ImportView(store: store) }
            .sheet(isPresented: $ocr) { OCRImportView(store: store) }

        }
    }
    private func cardRow(_ item: NoteItem, siblingCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.content.question).lineLimit(2)
            if siblingCount > 1 { Text("同じノートから\(siblingCount)枚").font(.caption).foregroundStyle(.secondary) }
            Text(item.kind.title + (item.isSuspended ? " · 停止中" : ""))
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
    var item: NoteItem? { store.notes.first { $0.cardID == cardID } }

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
                        LabeledContent("このノートのカード", value: "\(store.notes.filter { $0.noteID == item.noteID }.count)枚")
                        LabeledContent("このカードの延べ回答回数", value: "\(item.summary.repetitions)回")
                        LabeledContent("忘却回数", value: "\(item.summary.lapses)")
                        if item.summary.state != "new" {
                            LabeledContent("次回復習", value: item.summary.dueDate.formatted())
                                .accessibilityIdentifier("noteDue")
                        }
                        Toggle("学習を一時停止", isOn: Binding(get: { item.isSuspended }, set: { value in
                            store.perform { try store.repository.setSuspended(cardID: cardID, value: value, now: store.clock()) }
                        }))
                    }
                    Section { Button("カードを削除", role: .destructive) { confirmingDelete = true } }
                }
                .navigationTitle(item.kind.title)
                .toolbar { Button("編集") { editing = true }.accessibilityIdentifier("editNote") }
                .sheet(isPresented: $editing) { NoteEditorView(store: store, item: item) }
                .confirmationDialog("このノートの\(store.notes.filter { $0.noteID == item.noteID }.count)枚のカードを削除しますか？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("削除", role: .destructive) {
                        if store.perform({ try store.repository.deleteNote(id: item.noteID) }) { dismiss() }
                    }
                } message: { Text("同じノートの問題・解答とすべての兄弟カードを削除します。過去の回答履歴は残ります。") }
            } else { ContentUnavailableView("カードがありません", systemImage: "rectangle") }
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
    @State private var result: String?
    @State private var failure: String?
    @State private var confirmDelete = false
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
                    Section("結果") { Text(result).accessibilityIdentifier("bulkResult") }
                    Button("閉じる") { close(true) }.accessibilityIdentifier("closeBulkResult")
                } else {
                    Section {
                        Text("選択カード: \(selection.count)枚")
                        Picker("操作", selection: $operation) {
                            ForEach(BulkOperation.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.accessibilityIdentifier("bulkOperation")
                        if operation == .move {
                            Picker("移動先", selection: $destination) {
                                Text("選択してください").tag(UUID?.none)
                                ForEach(store.decks) { Text($0.name).tag(Optional($0.id)) }
                            }.accessibilityIdentifier("bulkDestination")
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
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("一括操作")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { close(result != nil) }.accessibilityIdentifier("closeBulkManagement") }
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
        var receipt: BulkEditResult?
        let refreshed = store.perform { receipt = try store.repository.applyBulkEdit(value, now: store.clock()) }
        if let receipt {
            didCommit()
            result = "変更済み: \(receipt.changedNotes)ノート・\(receipt.changedCards)枚"
            if !refreshed { result! += "。表示を更新できません。閉じてアプリを開き直してください。" }
            preview = nil
        } else { preview = nil; failure = store.failure ?? "変更は確定されていません。" }
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
                Picker("デッキ（子孫を含む）", selection: $scope.deckID) {
                    Text("すべて").tag(UUID?.none)
                    ForEach(store.decks) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("履歴の期間", selection: $days) {
                    ForEach([7, 30, 90, 0], id: \.self) { Text($0 == 0 ? "全期間" : "\($0)日").tag($0) }
                }
                ForEach(store.tags) { tag in
                    Toggle(tag.name, isOn: Binding(get: { scope.tagIDs.contains(tag.id) }, set: { value in
                        if value { scope.tagIDs.append(tag.id) } else { scope.tagIDs.removeAll { $0 == tag.id } }
                    }))
                }
            }
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
            WeakPracticeView(store: store, initial: session)
        }
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
    init(store: StudyStore, initial: WeakPracticeSession) {
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
                            Button("次のカード") { session.next() }.accessibilityIdentifier("nextWeakPractice")
                        } else {
                            StudyHintView(hint: item.content.hint).id(item.cardID)
                            Button("答えを表示") { session.reveal() }.accessibilityIdentifier("revealWeakPractice")
                        }
                        if session.index > 0 { Button("前のカード") { session.previous() } }
                    } else {
                        Text("重点練習を完了しました")
                        Button("閉じる") { dismiss() }.accessibilityIdentifier("finishWeakPractice")
                    }
                }.padding()
            }
            .navigationTitle("重点練習")
            .toolbar { Button("終了") { dismiss() } }
        }
    }
}
