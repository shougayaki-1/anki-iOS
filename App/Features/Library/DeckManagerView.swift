import SwiftUI

struct DeckManagerView: View {
    @Bindable var store: StudyStore
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    var body: some View {
        NavigationStack {
            List {
                ForEach(store.decks) { deck in
                    NavigationLink(deck.name) { DeckEditorView(store: store, deckID: deck.id) }
                }
            }
            .navigationTitle("デッキ管理")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("デッキ追加", systemImage: "plus") { adding = true } }
            }
            .sheet(isPresented: $adding) { NavigationStack { DeckEditorView(store: store, deckID: nil) } }
        }
    }
}

struct DeckEditorView: View {
    @Bindable var store: StudyStore
    let deckID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var parentID: UUID?
    @State private var destination: UUID?
    @State private var deleting = false
    @State private var excluded: Set<UUID> = []
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                TextField("デッキ名", text: $name).accessibilityIdentifier("deckNameInput")
                Picker("親デッキ", selection: $parentID) {
                    Text("なし（最上位）").tag(UUID?.none)
                    ForEach(store.decks.filter { !excluded.contains($0.id) }) { Text($0.name).tag(Optional($0.id)) }
                }.accessibilityIdentifier("deckParentPicker")
            }
            if deckID != nil {
                Section {
                    Picker("ノート移動先", selection: $destination) {
                        Text("選択してください").tag(UUID?.none)
                        ForEach(store.decks.filter { !excluded.contains($0.id) }) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Button("デッキを削除", role: .destructive) { deleting = true }
                } header: { Text("削除時の移動先") } footer: { Text("子孫デッキも削除します。ノートを別のデッキへ移すか、カードと一緒に削除するか選べます。回答履歴は保持します。") }
            }
        }
        .navigationTitle(deckID == nil ? "デッキ追加" : "デッキ編集")
        .toolbar {
            if deckID == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }.accessibilityIdentifier("cancelDeckEditor")
                }
            }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
        .task {
            do {
                if let id = deckID, let deck = try store.repository.decks().first(where: { $0.id == id }) {
                    name = deck.name; parentID = deck.parentID; excluded = try store.repository.descendants(of: id)
                }
            } catch { failure = error.localizedDescription }
        }
        .confirmationDialog("デッキと子孫を削除しますか？", isPresented: $deleting, titleVisibility: .visible) {
            Button("ノートを移動して削除") { remove(move: destination) }.disabled(destination == nil)
            Button("ノート・カードも削除", role: .destructive) { remove(move: nil) }
        }
        .alert("処理できませんでした", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("閉じる", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }
    private func save() {
        do {
            if let id = deckID { try store.repository.moveDeck(id: id, name: name, parentID: parentID, now: store.clock()) }
            else { try store.repository.createDeck(name: name, parentID: parentID, now: store.clock()) }
            try store.reload(); dismiss()
        } catch { failure = error.localizedDescription }
    }
    private func remove(move: UUID?) {
        guard let id = deckID else { return }
        do { try store.repository.deleteDeck(id: id, moveNotesTo: move, now: store.clock()); try store.reload(); dismiss() }
        catch { failure = error.localizedDescription }
    }
}
