import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @Bindable var store: StudyStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var text = ""
    @State private var filePicker = false
    @State private var source = "貼り付け"
    @State private var format = "Q/A"
    @State private var hasHeader = true
    @State private var questionColumn = 0
    @State private var answerColumn = 1
    @State private var columnCount = 2
    @State private var rows: [ImportRow] = []
    @State private var deckID: UUID
    @State private var kind = NoteKind.basic
    @State private var tagText = ""
    @State private var action = DuplicateAction.skip
    @State private var resetHistory = false
    @State private var confirming = false
    @State private var failure: String?
    @State private var result: ImportResult?

    init(store: StudyStore, initialText: String = "", sourceName: String = "貼り付け") {
        self.store = store
        _text = State(initialValue: initialText)
        _source = State(initialValue: sourceName)
        _deckID = State(initialValue: store.decks.first?.id ?? UUID())
    }

    var body: some View {
        NavigationStack {
            Form {
                if let result {
                    Section("取り込み結果") {
                        Text("成功 \(result.imported)件 / スキップ \(result.skipped)件 / エラー \(result.errors.count)件")
                            .accessibilityIdentifier("importResult")
                        ForEach(result.errors, id: \.self) { Text($0).foregroundStyle(.red) }
                        Button("新しい取り込み") { self.result = nil; rows = []; text = "" }
                    }
                } else {
                    Section {
                        Button("CSV / TSV / TXTファイルを選択") { filePicker = true }
                        TextEditor(text: $text).focused($focused).frame(minHeight: 130).accessibilityIdentifier("importText")
                        Picker("形式", selection: $format) {
                            Text("Q: / A: または文章").tag("Q/A")
                            Text("CSV（カンマ）").tag("CSV")
                            Text("TSV（タブ）").tag("TSV")
                        }
                        if format != "Q/A" {
                            Toggle("先頭行はヘッダー", isOn: $hasHeader)
                            Picker("問題の列", selection: $questionColumn) {
                                ForEach(0..<columnCount, id: \.self) { Text("列\($0 + 1)").tag($0) }
                            }
                            Picker("解答の列", selection: $answerColumn) {
                                ForEach(0..<columnCount, id: \.self) { Text("列\($0 + 1)").tag($0) }
                            }
                        }
                        Button("プレビューを作成", action: preview).accessibilityIdentifier("previewImport")
                            .disabled(text.isEmpty)
                    } header: { Text("入力") } footer: { Text("通常の文章から問いや解答を自動生成しません。プレビューで編集できます。") }
                    Section("登録先") {
                        Picker("デッキ", selection: $deckID) { ForEach(store.decks) { Text($0.name).tag($0.id) } }
                        Picker("カード形式", selection: $kind) {
                            ForEach([NoteKind.basic, .written, .cloze], id: \.self) { Text($0.title).tag($0) }
                        }
                        TextField("タグ（カンマ区切り）", text: $tagText).accessibilityIdentifier("importTags")
                        Picker("重複の扱い", selection: $action) {
                            ForEach(DuplicateAction.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        if action == .update { Toggle("更新対象を未学習に戻す", isOn: $resetHistory) }
                    }
                    ForEach($rows) { $row in
                        Section("\(row.line)行目") {
                            Toggle("取り込む", isOn: $row.included)
                            TextField("問題", text: $row.question, axis: .vertical)
                            TextField("解答", text: $row.answer, axis: .vertical)
                            if incomplete(row) { Text("問題または解答を入力してください。確定時はエラーとして除外します。")
                                    .font(.footnote).foregroundStyle(.red) }
                            if isDuplicate(row) { Label("同じデッキに重複候補があります", systemImage: "doc.on.doc")
                                    .font(.footnote).foregroundStyle(.orange) }
                        }
                    }
                    if !rows.isEmpty {
                        Section { Button("取り込みを確定") { confirming = true }.accessibilityIdentifier("confirmImport") }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("一括登録")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() }.accessibilityIdentifier("closeImport") }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完了") { focused = false } }
            }
            .fileImporter(isPresented: $filePicker, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText]) { result in
                do {
                    let url = try result.get()
                    guard ["csv", "tsv", "txt"].contains(url.pathExtension.lowercased()) else { throw StudyError.unsupportedContent }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 10_000_000 { throw LibraryError.fileTooLarge }
                    let data = try Data(contentsOf: url)
                    guard data.count <= 10_000_000 else { throw LibraryError.fileTooLarge }
                    guard let value = String(data: data, encoding: .utf8) else { throw LibraryError.invalidUTF8 }
                    text = value.hasPrefix("\u{feff}") ? String(value.dropFirst()) : value
                    source = url.pathExtension.lowercased()
                    format = source == "csv" ? "CSV" : source == "tsv" ? "TSV" : "Q/A"
                    if format != "Q/A" {
                        let table = try ImportParser.table(text, delimiter: format == "CSV" ? "," : "\t")
                        columnCount = max(2, table.rows.map(\.count).max() ?? 2)
                    }
                    rows = []
                } catch { failure = error.localizedDescription }
            }
            .confirmationDialog("\(rows.filter(\.included).count)件の取り込みを確定しますか？", isPresented: $confirming, titleVisibility: .visible) {
                Button("確定して保存") { commit() }.accessibilityIdentifier("commitImport")
            } message: { Text("重複は「\(action.title)」。\(resetHistory && action == .update ? "更新対象の復習予定を初期化します。" : "既存の学習履歴を保持します。")") }
            .alert("取り込めませんでした", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("閉じる", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }
    }
    private func incomplete(_ row: ImportRow) -> Bool {
        ImportParser.normalized(row.question).isEmpty || (kind != .cloze && ImportParser.normalized(row.answer).isEmpty)
    }
    private func isDuplicate(_ row: ImportRow) -> Bool {
        (try? store.repository.duplicate(of: NoteInput(deckID: deckID, kind: kind, question: row.question, answer: row.answer))) != nil
    }
    private func preview() {
        do {
            if format == "Q/A" {
                rows = try ImportParser.pasted(text)
                if text.contains("{{c") { kind = .cloze }
            }
            else {
                let table = try ImportParser.table(text, delimiter: format == "CSV" ? "," : "\t")
                columnCount = max(2, table.rows.map(\.count).max() ?? 2)
                rows = ImportParser.map(table, header: hasHeader, questionColumn: questionColumn, answerColumn: answerColumn)
            }
        } catch { failure = error.localizedDescription }
    }
    private func commit() {
        do {
            result = try store.repository.importRows(rows, deckID: deckID, kind: kind,
                                                    tagNames: tagText.components(separatedBy: ","), action: action,
                                                    resetHistory: resetHistory, source: source, now: store.clock())
            try store.reload()
        } catch { failure = error.localizedDescription }
    }
}
