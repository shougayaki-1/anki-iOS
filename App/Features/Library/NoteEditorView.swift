import SwiftUI

struct NoteEditorView: View {
    @Bindable var store: StudyStore
    let item: NoteItem?
    @Environment(\.dismiss) private var dismiss
    @State private var input: NoteInput
    @State private var historyChoice = false
    @State private var failure: String?
    @State private var pendingReset = false

    init(store: StudyStore, item: NoteItem?) {
        self.store = store; self.item = item
        _input = State(initialValue: NoteInput(deckID: item?.deckID ?? store.decks.first?.id ?? UUID(),
                                               kind: item?.kind ?? .basic,
                                               question: item?.content.question ?? "",
                                               answer: item?.content.answer ?? "",
                                               explanation: item?.content.explanation ?? "",
                                               responseMode: item?.responseMode ?? .mental))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("デッキ", selection: $input.deckID) {
                        ForEach(store.decks) { Text($0.name).tag($0.id) }
                    }
                    Picker("形式", selection: $input.kind) {
                        ForEach([NoteKind.basic, .written], id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("標準の回答方法", selection: $input.responseMode) {
                        ForEach(ResponseMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section("問題") {
                    TextField("問題文", text: $input.question, axis: .vertical).lineLimit(3...10)
                        .accessibilityIdentifier("questionInput")
                }
                Section("解答") {
                    TextField("解答・模範解答", text: $input.answer, axis: .vertical).lineLimit(3...10)
                        .accessibilityIdentifier("answerInput")
                }
                Section("解説（任意）") {
                    TextField("解説", text: $input.explanation, axis: .vertical).lineLimit(2...8)
                }
            }
            .navigationTitle(item == nil ? "カード追加" : "カード編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let item, (item.content.question != input.question || item.content.answer != input.answer || item.kind != input.kind),
                           item.summary.repetitions > 0 { historyChoice = true }
                        else { save(reset: false) }
                    }.accessibilityIdentifier("saveNote")
                    .disabled(input.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || input.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("学習済みの内容を変更します", isPresented: $historyChoice, titleVisibility: .visible) {
                Button("復習予定を維持して保存") { save(reset: false) }
                Button("未学習に戻して保存", role: .destructive) { save(reset: true) }
            } message: { Text("学習の意味が変わる場合は未学習に戻せます。過去の履歴は残ります。") }
            .alert("保存できませんでした", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("再試行") { save(reset: pendingReset) }
                Button("閉じる", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }
    }

    private func save(reset: Bool) {
        pendingReset = reset
        do {
            if let item { try store.repository.updateNote(id: item.id, input: input, resetHistory: reset, now: store.clock()) }
            else { try store.repository.createNote(input, now: store.clock()) }
            try store.reload(); dismiss()
        } catch { failure = error.localizedDescription }
    }
}
