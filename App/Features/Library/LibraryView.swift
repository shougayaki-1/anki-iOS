import SwiftUI

struct LibraryView: View {
    @Bindable var store: StudyStore
    @State private var adding = false
    @State private var addingDeck = false
    @State private var deckName = ""
    @State private var search = ""

    var filtered: [NoteItem] {
        store.notes.filter {
            search.isEmpty || "\($0.content.question) \($0.content.answer) \($0.deckName)".localizedCaseInsensitiveContains(search)
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
                ToolbarItem(placement: .topBarLeading) { Button("デッキ追加") { addingDeck = true } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("カード追加", systemImage: "plus") { adding = true }.accessibilityIdentifier("addNote")
                }
            }
            .sheet(isPresented: $adding) { NoteEditorView(store: store, item: nil) }
            .alert("デッキ追加", isPresented: $addingDeck) {
                TextField("デッキ名", text: $deckName)
                Button("追加") {
                    if store.perform({ try store.repository.createDeck(name: deckName, now: store.clock()) }) { deckName = "" }
                }
                Button("キャンセル", role: .cancel) { deckName = "" }
            }
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
                    Section("解答") { Text(item.content.answer).textSelection(.enabled) }
                    if !item.content.explanation.isEmpty { Section("解説") { Text(item.content.explanation) } }
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
                        if store.perform({ try store.repository.deleteNote(id: item.id) }) { dismiss() }
                    }
                } message: { Text("問題と解答は削除されます。過去の回答履歴は残ります。") }
            } else { ContentUnavailableView("カードがありません", systemImage: "rectangle") }
        }
    }
}
