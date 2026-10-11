import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @Bindable var store: StudyStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var text = ""
    @State private var filePicker = false
    @State private var imagePackage: ImageImportPackage?
    @State private var source = "貼り付け"
    @State private var format = "Q/A"
    @State private var hasHeader = true
    @State private var questionColumn = 0
    @State private var modeColumn = -2
    @State private var hintColumn = -2 // -2: header detection, -1: no hint column
    @State private var answerColumn = 1
    @State private var columnCount = 2
    @State private var rows: [ImportRow] = []
    @State private var previewPage = 0
    private let pageSize = 20
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
                        Button("CSV / TSV / TXT / 画像ZIPを選択") { filePicker = true }.accessibilityIdentifier("selectImportFile")
                        TextEditor(text: $text).focused($focused).frame(height: 160).accessibilityIdentifier("importText")
                        Picker("形式", selection: $format) {
                            Text("Q: / A: または文章").tag("Q/A")
                            Text("CSV（カンマ）").tag("CSV")
                            Text("TSV（タブ）").tag("TSV")
                        }
                        .accessibilityIdentifier("importFormat")
                        if format != "Q/A" {
                            Toggle("先頭行はヘッダー", isOn: $hasHeader)
                            Picker("問題の列", selection: $questionColumn) {
                                ForEach(0..<columnCount, id: \.self) { Text("列\($0 + 1)").tag($0) }
                            }
                            Picker("解答の列", selection: $answerColumn) {
                                ForEach(0..<columnCount, id: \.self) { Text("列\($0 + 1)").tag($0) }
                            }
                            Picker("ヒントの列", selection: $hintColumn) {
                                Text("ヘッダーから自動判定").tag(-2)
                                Text("指定しない（既存ヒントを保持）").tag(-1)
                                ForEach(0..<columnCount, id: \.self) { Text("列\($0 + 1)").tag($0) }
                            }.accessibilityIdentifier("importHintColumn")
                            Picker("回答方式の列", selection: $modeColumn) {
                                Text("ヘッダーから自動判定").tag(-2)
                                Text("指定しない（既存方式を保持）").tag(-1)
                                ForEach(0..<columnCount, id: \.self) { Text("列\($0 + 1)").tag($0) }
                            }.accessibilityIdentifier("importModeColumn")
                            Text("responseMode / 回答方式：mental・typing・ordering（並び替え）。未知の値・空欄・並び替え不可は頭の中で回答になります。")
                                .font(.footnote).foregroundStyle(.secondary)
                            Text("hint / ヒントのヘッダーを認識します。指定したヒント列が空欄の場合、重複更新で既存ヒントを消去します。列を指定しない場合は保持します。")
                                .font(.footnote).foregroundStyle(.secondary)
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
                    if !rows.isEmpty {
                        Section {
                            Text("プレビュー \(previewStart + 1)〜\(previewEnd) / \(rows.count)行")
                                .accessibilityIdentifier("importPageSummary")
                            HStack {
                                Button("前の20行") { previewPage = currentPage - 1 }
                                    .disabled(currentPage == 0)
                                    .accessibilityIdentifier("previousImportPage")
                                Spacer()
                                Button("次の20行") { previewPage = currentPage + 1 }
                                    .disabled(currentPage + 1 >= pageCount)
                                    .accessibilityIdentifier("nextImportPage")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                    }
                    ForEach(previewStart..<previewEnd, id: \.self) { index in
                        let row = rows[index]
                        Section("\(row.line)行目") {
                            Toggle("取り込む", isOn: $rows[index].included)
                            TextField("問題", text: $rows[index].question, axis: .vertical)
                            TextField("解答", text: $rows[index].answer, axis: .vertical)
                            TextField("ヒント（任意）", text: Binding(get: { rows[index].hint ?? "" }, set: { rows[index].hint = $0 }), axis: .vertical)
                                .accessibilityIdentifier("importHint-\(row.line)")
                            Text(row.hint == nil ? "重複更新時：既存ヒントを保持" :
                                 (ImportParser.normalized(row.hint ?? "").isEmpty ? "重複更新時：既存ヒントを消去" : "重複更新時：ヒントを置き換え"))
                                .font(.footnote).foregroundStyle(.secondary)
                            if row.hint != nil {
                                Button("ヒントの変更を取り消し、既存を保持") { rows[index].hint = nil }
                                    .font(.footnote)
                            }
                            Picker("回答方式", selection: Binding(get: { rows[index].responseMode?.rawValue ?? "keep" }, set: {
                                rows[index].responseMode = ResponseMode(rawValue: $0); rows[index].modeWarning = nil
                            })) {
                                Text("未指定（既存方式を保持）").tag("keep")
                                ForEach(ResponseMode.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                            }.accessibilityIdentifier("importMode-\(row.line)")
                            if let warning = row.modeWarning { Text(warning).font(.footnote).foregroundStyle(.secondary) }
                            if row.responseMode == .ordering, let reason = OrderingAnswer.reason(kind: kind, answer: row.answer) {
                                Text("頭の中で回答として取り込みます。" + reason).font(.footnote).foregroundStyle(.secondary)
                            }
                            if incomplete(row) { Text("問題または解答を入力してください。確定時はエラーとして除外します。")
                                    .font(.footnote).foregroundStyle(.red) }
                            if isDuplicate(row) { Label("同じデッキに重複候補があります", systemImage: "doc.on.doc")
                                    .font(.footnote).foregroundStyle(.orange) }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if result == nil && !rows.isEmpty {
                    VStack(spacing: 8) {
                        Text("選択 \(rows.filter(\.included).count)件 / 全\(rows.count)行")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button { focused = false; confirming = true } label: {
                            Text("取り込みを確定").font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color("PrimaryAction")).foregroundStyle(Color.white)
                        .accessibilityIdentifier("confirmImport")
                        .disabled(!rows.contains(where: \.included))
                    }
                    .padding(.horizontal).padding(.vertical, 10)
                    .background(.regularMaterial)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: text) { _, _ in refreshColumnCount() }
            .onChange(of: format) { _, _ in refreshColumnCount() }
            .navigationTitle("一括登録")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() }.accessibilityIdentifier("closeImport") }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完了") { focused = false } }
            }
            .fileImporter(isPresented: $filePicker, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText, .zip]) { result in
                do {
                    let url = try result.get()
                    guard ["csv", "tsv", "txt", "zip"].contains(url.pathExtension.lowercased()) else { throw StudyError.unsupportedContent }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let limit = url.pathExtension.lowercased() == "zip" ? 200_000_000 : 10_000_000
                    if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit { throw LibraryError.fileTooLarge }
                    let data = try Data(contentsOf: url)
                    guard data.count <= limit else { throw LibraryError.fileTooLarge }
                    if url.pathExtension.lowercased() == "zip" { imagePackage = try ImageImportPackage.read(data); return }
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
            .sheet(item: $imagePackage) { package in ImageZIPImportView(store: store, package: package, deckID: deckID) }
            .confirmationDialog("\(rows.filter(\.included).count)件の取り込みを確定しますか？", isPresented: $confirming, titleVisibility: .visible) {
                Button("確定して保存") { commit() }.accessibilityIdentifier("commitImport")
            } message: { Text("重複は「\(action.title)」。\(resetHistory && action == .update ? "更新対象の復習予定を初期化します。" : "既存の学習履歴を保持します。")") }
            .alert("取り込めませんでした", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("閉じる", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }
    }
    private var pageCount: Int { max(1, (rows.count + pageSize - 1) / pageSize) }
    private var currentPage: Int { min(max(0, previewPage), pageCount - 1) }
    private var previewStart: Int { min(currentPage * pageSize, rows.count) }
    private var previewEnd: Int { min(previewStart + pageSize, rows.count) }

    private func incomplete(_ row: ImportRow) -> Bool {
        ImportParser.normalized(row.question).isEmpty || (kind != .cloze && ImportParser.normalized(row.answer).isEmpty)
    }
    private func isDuplicate(_ row: ImportRow) -> Bool {
        (try? store.repository.duplicate(of: NoteInput(deckID: deckID, kind: kind, question: row.question, answer: row.answer))) != nil
    }
    private func preview() {
        do {
            previewPage = 0
            if format == "Q/A" {
                rows = try ImportParser.pasted(text)
                if text.contains("{{c") { kind = .cloze }
            }
            else {
                let table = try ImportParser.table(text, delimiter: format == "CSV" ? "," : "\t")
                columnCount = max(2, table.rows.map(\.count).max() ?? 2)
                let selectedHint = hintColumn >= 0 ? hintColumn :
                    (hintColumn == -2 && hasHeader ? ImportParser.hintColumn(in: table) : nil)
                rows = ImportParser.map(table, header: hasHeader, questionColumn: questionColumn,
                                        answerColumn: answerColumn, hintColumn: selectedHint,
                                        modeColumn: modeColumn >= 0 ? modeColumn :
                                            (modeColumn == -2 && hasHeader ? ImportParser.responseModeColumn(in: table) : nil))
            }
        } catch { failure = error.localizedDescription }
    }
    private func refreshColumnCount() {
        guard format != "Q/A", let table = try? ImportParser.table(text, delimiter: format == "CSV" ? "," : "\t") else { return }
        columnCount = max(2, table.rows.map(\.count).max() ?? 2)
        questionColumn = min(questionColumn, columnCount - 1)
        answerColumn = min(answerColumn, columnCount - 1)
        if hintColumn >= columnCount { hintColumn = -2 }
        if modeColumn >= columnCount { modeColumn = -2 }
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


struct ImageZIPImportView: View {
    @Bindable var store: StudyStore
    @State var package: ImageImportPackage
    @State var deckID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var duplicates = Set<UUID>()
    @State private var action = DuplicateAction.skip
    @State private var confirming = false
    @State private var failure: String?
    @State private var result: ImportResult?
    var body: some View {
        NavigationStack {
            Form {
                if let result {
                    Section("取り込み結果") {
                        Text("成功 \(result.imported)件 / スキップ \(result.skipped)件 / エラー \(result.errors.count)件").accessibilityIdentifier("imageImportResult")
                        ForEach(result.errors, id: \.self) { Text($0).foregroundStyle(.red) }
                    }
                } else {
                    Section("画像ZIP") {
                        Text("\(package.rows.count)行 / 重複 \(duplicates.count)行 / エラー \(package.rows.filter { $0.error != nil }.count)行。確定するまで保存されません。")
                        Text("問題が空欄の行には「画像を見て答えてください」を補います。プレビューで変更できます。")
                        Picker("デッキ指定がない行の登録先", selection: $deckID) {
                            ForEach(store.decks) { Text($0.name).tag($0.id) }
                        }
                        Picker("同じデッキ・問題・解答・画像の重複", selection: $action) {
                            ForEach(DuplicateAction.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Text("更新は解説とタグを変更します。学習履歴・復習予定・カードIDは保持されます。デッキ列は / で階層を指定します。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("プレビュー") {
                        ForEach(page * 20..<min((page + 1) * 20, package.rows.count), id: \.self) { index in
                            VStack(alignment: .leading) {
                                Toggle("\(package.rows[index].line)行を取り込む", isOn: $package.rows[index].included)
                                if let data = package.images[package.rows[index].imagePath], let image = UIImage(data: data) {
                                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 140)
                                }
                                Text(package.rows[index].imagePath).font(.caption)
                                if !package.rows[index].tags.isEmpty { Text("タグ: " + package.rows[index].tags.joined(separator: "、")).font(.caption) }
                                TextField("問題", text: $package.rows[index].question, axis: .vertical)
                                TextField("解答", text: $package.rows[index].answer, axis: .vertical)
                                if !package.rows[index].deckPath.isEmpty { Text("デッキ: \(package.rows[index].deckPath)") }
                                if duplicates.contains(package.rows[index].id) { Text("重複候補（選択した方針で処理）").foregroundStyle(.orange) }
                                if let error = package.rows[index].error { Text(error).foregroundStyle(.red) }
                            }
                        }
                        HStack {
                            Button("前へ") { page -= 1 }.disabled(page == 0)
                            Spacer(); Text("\(page + 1) / \(max(1, (package.rows.count + 19) / 20))"); Spacer()
                            Button("次へ") { page += 1 }.disabled((page + 1) * 20 >= package.rows.count)
                        }

                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if result == nil {
                    Button("確認して取り込む") { confirming = true }
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity).padding()
                        .background(.bar)
                        .disabled(!package.rows.contains { $0.included && $0.error == nil })
                        .accessibilityIdentifier("confirmImageImport")
                }
            }
            .onAppear { refreshDuplicates() }
            .onChange(of: deckID) { refreshDuplicates() }
            .onChange(of: package.rows.map { $0.question + "\u{1f}" + $0.answer }) { refreshDuplicates() }
            .navigationTitle("画像ZIPの取り込み")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() }.accessibilityIdentifier("closeImageImport") } }
            .confirmationDialog("選択した行を保存しますか？", isPresented: $confirming, titleVisibility: .visible) {
                Button("確定して保存") {
                    do { result = try store.repository.importImagePackage(package, deckID: deckID, action: action, now: store.clock()); try store.reload() }
                    catch { failure = error.localizedDescription }
                }
            }
            .alert("取り込めませんでした", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("閉じる", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }
    }
    private func refreshDuplicates() {
        duplicates = (try? store.repository.imageImportDuplicates(package, deckID: deckID)) ?? []
    }

}
