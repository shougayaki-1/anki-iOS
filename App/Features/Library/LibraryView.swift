import SwiftUI

struct LibraryView: View {
    @Bindable var store: StudyStore
    @Binding var shortcutDeck: ShortcutDeckDestination?
    var deckFilter: UUID? = nil
    @State private var adding = false
    @State private var ocr = false
    @State private var importing = false
    @State private var addingDeck = false
    @State private var deckName = ""
    @State private var search = ""
    @State private var editMode = EditMode.inactive
    @State private var selection = Set<UUID>()
    @State private var bulkEditing = false

    var filtered: [NoteItem] {
        let decks = deckFilter.map { (try? store.repository.descendants(of: $0)) ?? Set([$0]) }
        return store.notes.filter {
            (decks?.contains($0.deckID) ?? true) && (search.isEmpty || "\($0.content.question) \($0.content.answer) \($0.deckName) \($0.tagNames.joined(separator: " "))".localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                if filtered.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "カードがありません" : "検索結果がありません", systemImage: search.isEmpty ? "rectangle.on.rectangle" : "magnifyingglass",
                                           description: Text(search.isEmpty ? "＋からカードを追加できます。写真の文字認識やファイルの一括登録も使えます。" : "問題・解答・デッキ・タグのキーワードを変えて検索してください。"))
                }
                ForEach(store.decks) { deck in
                    Section(deck.name) {
                        ForEach(filtered.filter { $0.deckID == deck.id }) { item in
                            if editMode.isEditing {
                                cardRow(item).tag(item.cardID)
                            } else {
                                NavigationLink { NoteDetailView(store: store, cardID: item.cardID) } label: { cardRow(item) }
                            }
                        }
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .onChange(of: deckFilter) { _, _ in selection.removeAll(); editMode = .inactive }
            .onChange(of: search) { _, _ in selection.removeAll() }
            .onChange(of: editMode) { _, mode in if !mode.isEditing { selection.removeAll() } }
            .safeAreaInset(edge: .bottom) {
                if !store.notes.isEmpty {
                    VStack(spacing: 8) {
                        HStack {
                            if editMode.isEditing {
                                Text("選択: \(selection.count)枚").accessibilityIdentifier("bulkSelectionCount")
                            } else { Text("一括操作").font(.subheadline) }
                            Spacer()
                            EditButton().environment(\.editMode, $editMode).accessibilityIdentifier("selectLibraryCards")
                        }
                        if editMode.isEditing {
                            HStack {
                                Button("表示中を全選択") { selection = Set(filtered.map(\.cardID)) }.accessibilityIdentifier("selectAllLibraryCards")
                                Spacer()
                                Button("解除") { selection.removeAll() }
                            }
                            Button("一括操作") { bulkEditing = true }
                                .buttonStyle(.borderedProminent).tint(Color("PrimaryAction")).foregroundStyle(Color.white)
                                .disabled(selection.isEmpty).accessibilityIdentifier("openBulkManagement")
                        }
                    }.padding().background(.regularMaterial)
                }
            }
            .searchable(text: $search, prompt: "問題・解答・デッキ・タグを検索")
            .navigationTitle(deckFilter.flatMap { id in store.decks.first { $0.id == id }?.shortName } ?? "ライブラリ")
            .navigationDestination(item: $shortcutDeck) { destination in
                ShortcutDeckContentsView(store: store, deckID: destination.id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("デッキ管理") { addingDeck = true } }
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
            .sheet(isPresented: $bulkEditing, onDismiss: { selection.removeAll(); editMode = .inactive }) {
                BulkManagementView(store: store, selection: selection) {
                    selection.removeAll(); editMode = .inactive; bulkEditing = false
                }
            }
            .sheet(isPresented: $adding) { NoteEditorView(store: store, item: nil, initialDeckID: deckFilter) }
            .sheet(isPresented: $addingDeck) { DeckManagerView(store: store) }
            .sheet(isPresented: $importing) { ImportView(store: store) }
            .sheet(isPresented: $ocr) { OCRImportView(store: store) }

        }
    }
    private func cardRow(_ item: NoteItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.content.question).lineLimit(2)
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
                        LabeledContent("状態", value: item.summary.state)
                        LabeledContent("回答回数", value: "\(item.summary.repetitions)")
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
                .confirmationDialog("このカードを削除しますか？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("削除", role: .destructive) {
                        if store.perform({ try store.repository.deleteNote(id: item.noteID) }) { dismiss() }
                    }
                } message: { Text("問題と解答は削除されます。過去の回答履歴は残ります。") }
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
    let close: () -> Void
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
                    Button("閉じる") { close() }.accessibilityIdentifier("closeBulkResult")
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
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { close() }.accessibilityIdentifier("closeBulkManagement") }
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
            result = "変更済み: \(receipt.changedNotes)ノート・\(receipt.changedCards)枚"
            if !refreshed { result! += "。表示を更新できません。閉じてアプリを開き直してください。" }
            preview = nil
        } else { preview = nil; failure = store.failure ?? "変更は確定されていません。" }
        store.failure = nil
    }
}
