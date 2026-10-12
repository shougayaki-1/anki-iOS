import SwiftUI

struct TextReplacementView: View {
    @Bindable var store: StudyStore
    let resultIDs: Set<UUID>, selectedIDs: Set<UUID>
    let initialDeckID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var scope = 0
    @State private var deckID: UUID?
    @State private var descendants = true
    @State private var find = ""
    @State private var replacement = ""
    @State private var fields: Set<ReplacementField> = [.question]
    @State private var caseSensitive = false
    @State private var wholeField = false
    @State private var preview: ReplacementPreview?
    @State private var work: Task<Void, Never>?
    @State private var busy = false
    @State private var confirming = false
    @State private var completed = false
    @State private var saving = false
    @State private var message: String?
    @State private var page = 0

    private var request: ReplacementRequest {
        let target: ReplacementRequest.Scope = scope == 2 && deckID != nil ? .deck(deckID!, descendants: descendants) : .cards(scope == 1 ? selectedIDs : resultIDs)
        return ReplacementRequest(scope: target, find: find, replacement: replacement, fields: fields, caseSensitive: caseSensitive, wholeField: wholeField)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !completed {
                    Section("対象") {
                        Picker("範囲", selection: $scope) {
                            Text("現在の検索結果（\(resultIDs.count)枚）").tag(0)
                            Text("選択カード（\(selectedIDs.count)枚）").tag(1)
                            Text("デッキ").tag(2)
                        }
                        if scope == 2 {
                            DeckSelectionField("デッキ", decks: store.decks, selection: $deckID, includesDescendants: descendants)
                            Toggle("子デッキも含める", isOn: $descendants)
                        }
                        Text("選択カードの本文は同じノートの兄弟カードにも反映されます。実行前に設定の手動バックアップを保存できます。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("文字列とフィールド") {
                        TextField("検索文字列", text: $find, axis: .vertical).autocorrectionDisabled()
                        TextField("置換後（空欄で削除）", text: $replacement, axis: .vertical).autocorrectionDisabled()
                        ForEach(ReplacementField.allCases) { field in
                            Toggle(field.title, isOn: Binding(get: { fields.contains(field) }, set: { enabled in
                                if enabled { fields.insert(field) } else { fields.remove(field) }
                            }))
                        }
                        Toggle("大文字小文字を区別", isOn: $caseSensitive)
                        Toggle("フィールド全体が完全一致", isOn: $wholeField)
                    }
                    Section {
                        Button("変更前プレビュー") { loadPreview() }
                            .disabled(busy || find.isEmpty || fields.isEmpty || (scope == 2 && deckID == nil))
                        if busy {
                            ProgressView("プレビューを作成中")
                            Button("中断") { work?.cancel(); busy = false; message = "プレビューを中断しました。変更はありません。" }
                        }
                    }
                }
                if saving { Section { ProgressView("置換を保存中") } }
                if let message { Section { Text(message) } }
                if let preview {
                    Section(completed ? "変更記録" : "確定前プレビュー") {
                        Text("変更: \(preview.changedRows.count)ノート / \(preview.changedCards)枚 / \(preview.occurrences)箇所")
                        Text("スキップ: \(preview.skipped)ノート")
                        Text("穴埋め・画像・未対応テンプレート・編集下書きのあるノートはスキップします。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if !completed {
                            Button("\(preview.changedRows.count)ノートを置換", role: .destructive) { confirming = true }
                                .disabled(preview.changedRows.isEmpty || busy)
                        }
                    }
                    ForEach(Array(preview.rows.dropFirst(page * 50).prefix(50))) { row in
                        Section {
                            Text(row.title).font(.headline).lineLimit(2)
                            if let reason = row.skipReason { Label("スキップ: " + reason, systemImage: "exclamationmark.triangle") }
                            ForEach(row.changes, id: \.field) { change in
                                Text("\(change.field.title)・\(change.count)箇所").font(.subheadline)
                                Text("変更前: " + change.before).textSelection(.enabled)
                                Text("変更後: " + change.after).textSelection(.enabled).foregroundStyle(.tint)
                            }
                        }
                    }
                    Section {
                        HStack {
                            Button("前の50ノート") { page -= 1 }.disabled(page == 0)
                            Spacer()
                            Text("\(page + 1) / \(max(1, (preview.rows.count + 49) / 50))")
                            Spacer()
                            Button("次の50ノート") { page += 1 }.disabled((page + 1) * 50 >= preview.rows.count)
                        }
                    }
                }
            }
            .disabled(saving)
            .interactiveDismissDisabled(saving)
            .navigationTitle("検索して置換")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if saving { Button("中断") { work?.cancel() } }
                    else { Button(completed ? "完了" : "閉じる") { work?.cancel(); dismiss() } }
                }
            }
            .confirmationDialog("\(preview?.changedRows.count ?? 0)ノートの本文を置換します。元に戻すにはバックアップの復元が必要です。", isPresented: $confirming, titleVisibility: .visible) {
                Button("確認して置換", role: .destructive) { apply() }
                Button("キャンセル", role: .cancel) {}
            }
            .onAppear { deckID = initialDeckID ?? store.decks.first?.id; if !selectedIDs.isEmpty { scope = 1 } }
            .onChange(of: request) { _, _ in work?.cancel(); preview = nil; message = nil; busy = false }
            .onDisappear { work?.cancel() }
        }
    }

    private func loadPreview() {
        work?.cancel(); busy = true; preview = nil; message = nil; page = 0
        let request = request
        let reader = TextReplacementReader(container: store.repository.context.container)
        work = Task { @MainActor in
            do {
                let result = try await reader.textReplacementPreview(request)
                try Task.checkCancellation()
                preview = result; busy = false
                if result.changedRows.isEmpty { message = "置換できる一致がありません。条件またはスキップ理由を確認してください。" }
            } catch {
                if !Task.isCancelled { message = error.localizedDescription; busy = false }
            }
        }
    }

    private func apply() {
        guard let preview, !completed else { return }
        // The actor writes with its own context, keeping 3,000-note commits off the UI actor.
        saving = true
        let reader = TextReplacementReader(container: store.repository.context.container), now = store.clock()
        work = Task { @MainActor in
            do {
                try await store.createRestorePoint("本文の一括置換")
                try Task.checkCancellation()
                let result = try await reader.apply(preview, now: now)
                // No cancellation check after commit: always report a saved operation.
                completed = true; saving = false
                message = "完了: \(result.changedNotes)ノート / \(result.changedCards)枚を変更しました。\(preview.skipped)ノートはスキップしました。"
                // A fresh context prevents cached models from overwriting the actor's save.
                let old = store.repository
                store.repository = StudyRepository(container: old.context.container, calendar: old.calendar, mediaStore: old.mediaStore)
                if !store.perform({}) {
                    message = (message ?? "保存しました。") + "\n画面の再読み込みに失敗しました。再表示してください。"
                }
            } catch {
                saving = false; message = error.localizedDescription; self.preview = nil
            }
        }
    }
}
