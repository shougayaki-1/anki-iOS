import SwiftUI

struct LibraryView: View {
    @Bindable var store: StudyStore
    @State private var adding = false
    @State private var ocr = false
    @State private var importing = false
    @State private var addingDeck = false
    @State private var deckName = ""
    @State private var search = ""

    var filtered: [NoteItem] {
        store.notes.filter {
            search.isEmpty || "\($0.content.question) \($0.content.answer) \($0.deckName) \($0.tagNames.joined(separator: " "))".localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    ContentUnavailableView("カードがありません", systemImage: "rectangle.on.rectangle",
                                           description: Text("＋から一問一答・記述式カードを追加できます。"))
                }
                ForEach(store.decks) { deck in
                    Section(deck.name) {
                        ForEach(filtered.filter { $0.deckID == deck.id }) { item in
                            NavigationLink {
                                NoteDetailView(store: store, cardID: item.cardID)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.content.question).lineLimit(2)
                                    Text(item.kind.title + (item.isSuspended ? " · 停止中" : ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "問題・解答・デッキを検索")
            .navigationTitle("ライブラリ")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("デッキ管理") { addingDeck = true } }
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
            .sheet(isPresented: $adding) { NoteEditorView(store: store, item: nil) }
            .sheet(isPresented: $addingDeck) { DeckManagerView(store: store) }
            .sheet(isPresented: $importing) { ImportView(store: store) }
            .sheet(isPresented: $ocr) { OCRImportView(store: store) }

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
