import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @Bindable var store: StudyStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var text = ""
    @State private var filePicker = false
    @State private var acceptingFiles = true
    @State private var fileOperation: Task<Void, Never>?
    @State private var fileGeneration = UUID()
    @State private var readingFile = false
    @State private var dropTarget = false
    @State private var pendingFile: (url: URL, contents: LocalFileInput.ImportContents)?
    @State private var deckPackage: ValidatedDeckPackage?
    @State private var ankiPackage: AnkiImportPreview?
    @State private var packageIdentity = UUID()
    @State private var childWorking = false
    @State private var replaceInput = false
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
    @State private var reloadWarning: String?
    @State private var saving = false
    @State private var operationPhase: ImportOperationPhase?
    private let initialImportDeckID: UUID?

    init(store: StudyStore, initialText: String = "", sourceName: String = "貼り付け", initialDeckID: UUID? = nil) {
        self.store = store
        #if DEBUG
        if let package = UITestFixtures.deckUpdatePreview() { _deckPackage = State(initialValue: package) }
        #endif
        initialImportDeckID = initialDeckID
        _text = State(initialValue: initialText)
        _source = State(initialValue: sourceName)
        _deckID = State(initialValue: initialDeckID ?? store.decks.first?.id ?? UUID())
    }

    var body: some View {
        NavigationStack {
            Group {
                if let deckPackage {
                    DeckPackagePreviewView(store: store, package: deckPackage, anki: ankiPackage,
                        initialDeckID: initialImportDeckID, chooseFile: { filePicker = true },
                        continueImport: resetInput, busyChanged: { childWorking = $0 })
                        .id(packageIdentity)
                } else if let imagePackage {
                    ImageZIPImportView(store: store, package: imagePackage, deckID: deckID,
                        chooseFile: { filePicker = true }, continueImport: resetInput,
                        busyChanged: { childWorking = $0 })
                        .id(packageIdentity)
                } else if let result {
                    ImportCompletionView(store: store, result: result, warning: reloadWarning,
                                         resultIdentifier: "importResult", closeIdentifier: "closeImport", retryImport: { self.result = nil }, continueImport: resetInput, close: { dismiss() })
                } else {
                    Form {
                    Section {
                        ImportFileSelectionButton { filePicker = true }
                        #if targetEnvironment(macCatalyst)
                        Text("FinderからCSV / TSV / TXTをこの画面へドロップできます。保存前にプレビューと確定が必要です。")
                            .font(.footnote).foregroundStyle(.secondary)
                        #endif
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
                        Button("プレビューを作成", action: preview).buttonStyle(SecondaryActionStyle()).accessibilityIdentifier("previewImport")
                            .disabled(text.isEmpty)
                    } header: { Text("入力") } footer: { Text("通常の文章から問いや解答を自動生成しません。プレビューで編集できます。") }
                    Section("登録先") {
                        DeckSelectionField("デッキ", decks: store.decks, selection: $deckID)
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
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if result == nil && deckPackage == nil && imagePackage == nil && !rows.isEmpty {
                    VStack(spacing: 0) {
                        Text("選択 \(rows.filter(\.included).count)件 / 全\(rows.count)行")
                            .font(.subheadline).foregroundStyle(.secondary)
                        ImportConfirmationButton(identifier: "confirmImport", disabled: saving || readingFile ||
                            !rows.contains(where: { $0.included && !incomplete($0) })) {
                            focused = false; confirming = true
                        }
                    }
                    .background(.regularMaterial)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: text) { _, _ in refreshColumnCount() }
            .onChange(of: format) { _, _ in refreshColumnCount() }
            .disabled(saving || readingFile || childWorking)
            .interactiveDismissDisabled(saving || readingFile || childWorking)
            .navigationBarBackButtonHidden(saving || readingFile || childWorking)
            .navigationTitle("インポート")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { if result == nil { Button("閉じる") { dismiss() }.disabled(saving || readingFile || childWorking).accessibilityIdentifier("closeImport") } }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完了") { focused = false } }
            }
            .fileImporter(isPresented: $filePicker, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText, .zip, .studyDeck, .ankiPackage, .data]) { result in
                do { readFile(try result.get()) }
                catch { if (error as NSError).code != NSUserCancelledError { failure = error.localizedDescription } }
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget) { providers in
                guard providers.count == 1 else { failure = "ファイルは1件ずつ選択してください。"; return false }
                LocalFileInput.load(providers[0], extensions: ["csv", "tsv", "txt", "zip", "studydeck", "apkg", "studybackup"], maximumBytes: 200_000_000) { result in
                    guard acceptingFiles, self.result == nil, !saving, !childWorking else { return }
                    switch result {
                    case let .success((url, data)): acceptFile(url, data: data)
                    case let .failure(error): failure = error.localizedDescription
                    }
                }
                return true
            }
            .onAppear {
                acceptingFiles = true
                #if DEBUG
                let args = ProcessInfo.processInfo.arguments
                if args.contains("-study-test-import-3000"), let index = args.firstIndex(of: "-study-test-store"),
                   args.count > index + 1, UUID(uuidString: args[index + 1]) != nil, text.isEmpty {
                    text = "Question,Answer\n" + (1...3000).map { "Q\($0),A\($0)" }.joined(separator: "\n")
                    format = "CSV"
                }
                #endif
            }
            .onDisappear { acceptingFiles = false; fileOperation?.cancel(); fileGeneration = UUID(); readingFile = false }
            .overlay {
                if let phase = operationPhase ?? (readingFile ? .reading : nil) {
                    ImportProcessingOverlay(phase: phase, cancel: readingFile ? {
                        fileOperation?.cancel(); fileGeneration = UUID(); readingFile = false
                    } : nil)
                }
            }
            .overlay { if dropTarget { RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 2).allowsHitTesting(false) } }
            .alert("入力中の内容をファイルで置き換えますか？", isPresented: $replaceInput) {
                Button("ファイルの内容に置き換える", role: .destructive) { applyPendingFile() }
                Button("キャンセル", role: .cancel) { pendingFile = nil }
            } message: { Text("現在の入力とプレビューを置き換えます。登録済みカードは変更しません。") }
            .confirmationDialog("\(rows.filter(\.included).count)件の取り込みを確定しますか？", isPresented: $confirming, titleVisibility: .visible) {
                Button("確定して保存") { commit() }.accessibilityIdentifier("commitImport")
            } message: { Text("重複は「\(action.title)」。\(resetHistory && action == .update ? "更新対象の復習予定を初期化します。" : "既存の学習履歴を保持します。")") }
            .alert("取り込めませんでした", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("閉じる", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }
    }
    private func acceptFile(_ url: URL, data: Data) {
        readFile(url, suppliedData: data)
    }
    private func stageFile(_ url: URL, contents: LocalFileInput.ImportContents) {
        pendingFile = (url, contents)
        if !text.isEmpty || !rows.isEmpty || imagePackage != nil || deckPackage != nil { replaceInput = true }
        else { applyPendingFile() }
    }
    private func readFile(_ url: URL, suppliedData: Data? = nil) {
        guard !saving, !childWorking else { return }
        fileOperation?.cancel()
        let generation = UUID(); fileGeneration = generation; readingFile = true
        fileOperation = Task {
            defer { if fileGeneration == generation { readingFile = false; fileOperation = nil } }
            do {
                let contents: LocalFileInput.ImportContents
                if let suppliedData {
                    let task = Task.detached(priority: .utility) {
                        try LocalFileInput.decodeImport(suppliedData, extension: url.pathExtension)
                    }
                    contents = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                } else { contents = try await LocalFileInput.readImport(url) }
                guard !Task.isCancelled, acceptingFiles, fileGeneration == generation, result == nil, !saving else { return }
                readingFile = false
                stageFile(url, contents: contents)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, acceptingFiles, fileGeneration == generation else { return }
                readingFile = false; failure = error.localizedDescription
            }
        }
    }
    private func applyPendingFile() {
        guard let file = pendingFile else { return }
        resetInput()
        source = file.url.pathExtension.lowercased()
        packageIdentity = UUID()
        switch file.contents {
        case .text(let value):
            text = value
            format = source == "csv" ? "CSV" : source == "tsv" ? "TSV" : "Q/A"
            refreshColumnCount()
        case .images(let package): imagePackage = package
        case .deck(let package): deckPackage = package
        case .anki(let package): deckPackage = package.deck; ankiPackage = package
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
        // The covered, disabled preview must not refetch/decode the library for
        // each visible row on every progress-phase render. Commit rechecks duplicates.
        guard !saving else { return false }
        return (try? store.repository.duplicate(of: NoteInput(deckID: deckID, kind: kind, question: row.question, answer: row.answer))) != nil
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
    private func resetInput() {
        result = nil; reloadWarning = nil; rows = []; text = ""; previewPage = 0
        source = "貼り付け"; pendingFile = nil; failure = nil
        deckPackage = nil; ankiPackage = nil; imagePackage = nil; childWorking = false
    }
    private func commit() {
        guard !saving, result == nil else { return }
        saving = true
        operationPhase = .preparing
        reloadWarning = nil
        let rows = rows, deckID = deckID, kind = kind, tagText = tagText, action = action, resetHistory = resetHistory, source = source
        Task {
            defer { saving = false; operationPhase = nil }
            do {
                await ImportOperationPhase.allowDisplay()
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try PreparedTextImport.make(rows, deckID: deckID, kind: kind,
                                                tagNames: tagText.components(separatedBy: ","))
                }.value
                operationPhase = .restorePoint
                await ImportOperationPhase.allowDisplay()
                try await store.createRestorePoint("テキスト・CSVの取り込み")
                operationPhase = .saving
                await ImportOperationPhase.allowDisplay()
                let saved = try await store.repository.importPreparedRowsInBackground(prepared, action: action,
                                                                resetHistory: resetHistory, source: source, now: store.clock())
                operationPhase = .refreshing
                await ImportOperationPhase.allowDisplay()
                do { try store.reload() }
                catch { reloadWarning = "保存は完了しましたが、表示を更新できません。再取り込みせず、閉じてアプリを開き直してください。\n" + error.localizedDescription }
                result = saved
                if saved.outcome == .complete { store.haptics.play(.importCompleted, mode: store.settings.hapticsMode) }
            } catch { failure = "保存されていません。入力を確認して再試行してください。\n" + error.localizedDescription }
        }
    }
}


struct ImageZIPImportView: View {
    @Bindable var store: StudyStore
    @State var package: ImageImportPackage
    @State var deckID: UUID
    @Environment(\.dismiss) private var dismiss
    var chooseFile: (() -> Void)? = nil
    var continueImport: (() -> Void)? = nil
    var busyChanged: (Bool) -> Void = { _ in }
    @State private var page = 0
    @State private var imageDisplayNamespace = UUID()
    @State private var duplicates = Set<UUID>()
    @State private var action = DuplicateAction.skip
    @State private var confirming = false
    @State private var failure: String?
    @State private var result: ImportResult?
    @State private var reloadWarning: String?
    @State private var saving = false
    @State private var operationPhase: ImportOperationPhase?
    var body: some View {
        Group {
            Group {
                if let result {
                    ImportCompletionView(store: store, result: result, warning: reloadWarning,
                                         resultIdentifier: "imageImportResult", closeIdentifier: "closeImageImport", retryImport: { self.result = nil }, continueImport: { if let continueImport { continueImport() } else { dismiss() } }, close: { dismiss() })
                } else {
                    Form {
                    if let chooseFile { Section { ImportFileSelectionButton(action: chooseFile) } }
                    Section("画像ZIP") {
                        Text("\(package.rows.count)行 / 重複 \(duplicates.count)行 / エラー \(package.rows.filter { $0.error != nil }.count)行。確定するまで保存されません。")
                        Text("問題が空欄の行には「画像を見て答えてください」を補います。プレビューで変更できます。")
                        DeckSelectionField("デッキ指定がない行の登録先", decks: store.decks, selection: $deckID)
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
                                if let data = package.images[package.rows[index].imagePath] {
                                    AsyncStudyImageView(data: data, namespace: imageDisplayNamespace, identity: package.rows[index].imagePath, maximumHeight: 140)
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
            }
            .safeAreaInset(edge: .bottom) {
                if result == nil {
                    ImportConfirmationButton(identifier: "confirmImageImport", disabled: saving ||
                        !package.rows.contains { $0.included && $0.error == nil }) { confirming = true }
                }
            }
            .onAppear { refreshDuplicates() }
            .onChange(of: saving) { _, value in busyChanged(value) }
            .onChange(of: deckID) { refreshDuplicates() }
            .onChange(of: package.rows.map { $0.question + "\u{1f}" + $0.answer }) { refreshDuplicates() }
            .disabled(saving)
            .interactiveDismissDisabled(saving)
            .overlay { if let operationPhase { ImportProcessingOverlay(phase: operationPhase) } }
            .navigationTitle("インポート")

            .confirmationDialog("選択した行を保存しますか？", isPresented: $confirming, titleVisibility: .visible) {
                Button("確定して保存", action: commit)
            }
            .alert("取り込めませんでした", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("閉じる", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }
    }
    private func commit() {
        guard !saving, result == nil else { return }
        saving = true
        operationPhase = .restorePoint
        reloadWarning = nil
        let package = package, deckID = deckID, action = action
        Task {
            defer { saving = false; operationPhase = nil }
            do {
                await ImportOperationPhase.allowDisplay()
                try await store.createRestorePoint("画像ZIPの取り込み")
                operationPhase = .saving
                await ImportOperationPhase.allowDisplay()
                let saved = try store.repository.importImagePackage(package, deckID: deckID, action: action, now: store.clock())
                operationPhase = .refreshing
                await ImportOperationPhase.allowDisplay()
                do { try store.reload() }
                catch { reloadWarning = "保存は完了しましたが、表示を更新できません。再取り込みせず、閉じてアプリを開き直してください。\n" + error.localizedDescription }
                result = saved
                if saved.outcome == .complete { store.haptics.play(.importCompleted, mode: store.settings.hapticsMode) }
            } catch { failure = "保存されていません。入力を確認して再試行してください。\n" + error.localizedDescription }
        }
    }
    private func refreshDuplicates() {
        duplicates = (try? store.repository.imageImportDuplicates(package, deckID: deckID)) ?? []
    }

}

/// A committed receipt shared by text, file, OCR and image ZIP imports.
struct ImportCompletionView: View {
    @Bindable var store: StudyStore
    let result: ImportResult
    let warning: String?
    let resultIdentifier: String
    let closeIdentifier: String
    let retryImport: () -> Void
    let continueImport: () -> Void
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    private var complete: Bool { result.outcome == .complete }
    private var title: String {
        switch result.outcome {
        case .complete: return "取り込みが完了しました"
        case .partial: return "一部の行を取り込みました"
        case .empty: return "追加・更新はありません"
        }
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ImportCompletionHeader(title: title, complete: complete)
                VStack(spacing: 12) {
                    if complete { Text(result.createdCards > 0 ? "カードを正常に追加しました" : "既存のノートを更新しました") }
                    Text(result.summary).accessibilityIdentifier(resultIdentifier)
                    if !result.destinations.isEmpty {
                        Text(result.destinations.count == 1 ? "保存先：" + result.destinations[0].name : "保存先：複数のデッキ")
                        if result.destinations.count > 1 {
                            ForEach(result.destinations) { Text($0.name).font(.footnote) }
                        }
                    }
                    if result.outcome == .empty {
                        Text("重複スキップ・選択解除・エラーの件数を確認してください。入力を変更して再試行できます。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("ノートは問題と解答のまとまり、カードは出題単位です。選択解除は除外行として表示します。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .opacity(complete && !reduceMotion && !appeared ? 0 : 1)
                .animation(.easeIn(duration: 0.3).delay(0.3), value: appeared)
                if let warning { Text(warning).foregroundStyle(.orange).accessibilityIdentifier("importCommittedWarning") }
                if !result.errors.isEmpty {
                    DisclosureGroup("エラー詳細（\(result.errors.count)行）") {
                        ForEach(Array(result.errors.enumerated()), id: \.offset) { _, error in
                            Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .multilineTextAlignment(.center).padding(24).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomActionArea {
                if !result.affectedCardIDs.isEmpty {
                    NavigationLink {
                        ImportedCardsView(store: store, cardIDs: result.affectedCardIDs)
                    } label: { Text("取り込んだカードを見る").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryActionStyle()).accessibilityIdentifier("viewImportedCards")
                }
                if result.outcome == .empty {
                    Button("入力を修正して再試行", action: retryImport).buttonStyle(PrimaryActionStyle())
                        .accessibilityIdentifier("retryEmptyImport")
                }
                HStack {
                    Button("続けて取り込む", action: continueImport).buttonStyle(SecondaryActionStyle())
                        .accessibilityIdentifier("continueImport")
                    Button("閉じる", action: close).buttonStyle(SecondaryActionStyle()).accessibilityIdentifier(closeIdentifier)
                }
            }
        }
        .onAppear {
            guard !appeared else { return }
            appeared = true
            UIAccessibility.post(notification: .announcement, argument: title + "。" + result.summary)
        }
    }
}

private struct ImportedCardsView: View {
    @Bindable var store: StudyStore
    let cardIDs: Set<UUID>
    var body: some View {
        List {
            Section {
                Text("今回追加・更新したカードだけを表示します（\(cardIDs.count)枚）。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(cardIDs.sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                ImportedCardRow(store: store, cardID: id)
            }
        }.navigationTitle("取り込んだカード")
    }
}

private struct ImportedCardRow: View {
    @Bindable var store: StudyStore
    let cardID: UUID
    @State private var item: NoteItem?
    @State private var failure: String?
    var body: some View {
        Group {
            if let item {
                NavigationLink { NoteDetailView(store: store, cardID: cardID) } label: {
                    VStack(alignment: .leading) {
                        Text(item.content.question).lineLimit(3)
                        Text(item.deckName).font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("importedCard-\(cardID.uuidString)")
            } else if let failure {
                Text(failure).foregroundStyle(.secondary)
                Button("再読み込み") { load() }
            } else { ProgressView("カードを読み込み中") }
        }.task { load() }
    }
    private func load() {
        do {
            item = try store.repository.noteItems(cardID: cardID).first
            failure = item == nil ? "このカードは削除されたため表示できません。" : nil
        } catch { failure = "カードを表示できません。" + error.localizedDescription }
    }
}

/// Shared receipt header for text/image and deck-file operations.
struct ImportCompletionHeader: View {
    let title: String
    let complete: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: complete ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 76)).foregroundStyle(complete ? .green : .orange)
                .scaleEffect(complete && !reduceMotion && !appeared ? 0.85 : 1)
                .opacity(complete && !reduceMotion && !appeared ? 0 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: appeared)
                .accessibilityHidden(true)
            Text(title).font(.title2.bold()).accessibilityIdentifier("importCompletionTitle")
        }
        .onAppear { appeared = true }
    }
}

/// Presentation phases describe actual operations; no estimated percentage is shown.
enum ImportOperationPhase: Equatable {
    case reading, validating, preparing, restorePoint, saving, refreshing, exporting

    var title: String {
        switch self {
        case .reading, .validating: return "内容を確認中"
        case .exporting: return "書き出し準備中"
        default: return "取り込み中"
        }
    }
    var message: String {
        switch self {
        case .reading: return "ファイルを読み込んでいます…"
        case .validating: return "内容を確認しています…"
        case .preparing: return "取り込みの準備をしています…"
        case .restorePoint: return "復元ポイントを作成しています…"
        case .saving: return "カード・デッキを保存しています…"
        case .refreshing: return "表示を更新しています…"
        case .exporting: return "共有ファイルを準備しています…"
        }
    }
    var canCancel: Bool { self == .reading || self == .validating || self == .exporting }

    // Give SwiftUI a render opportunity before entering synchronous repository work.
    // This does not move SwiftData objects across actors or change transaction boundaries.
    static func allowDisplay() async {
        try? await Task.sleep(for: .milliseconds(30))
    }
}

struct ImportProcessingOverlay: View {
    let phase: ImportOperationPhase
    var cancel: (() -> Void)? = nil
    var body: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text(phase.title).font(.headline)
                Text(phase.message).font(.subheadline)
                if phase.canCancel, let cancel {
                    Button("処理を取り消す", action: cancel)
                        .accessibilityIdentifier("cancelImportOperation")
                } else {
                    Text("完了までお待ちください").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center).padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(24)
            .accessibilityIdentifier("importProcessingOverlay")
        }
        .onAppear { announce() }
        .onChange(of: phase) { _, _ in announce() }
    }
    private func announce() {
        UIAccessibility.post(notification: .announcement, argument: phase.title + "。" + phase.message)
    }
}


struct ImportFileSelectionButton: View {
    let action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: action) {
                Label("ファイルを選択", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryActionStyle())
            .accessibilityIdentifier("selectImportFile")
            Text("CSV / TSV / TXT / 画像ZIP / .studydeck / .apkg")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct ImportConfirmationButton: View {
    let identifier: String
    let disabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("取り込みを確定").font(.headline).frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryActionStyle())
        .accessibilityIdentifier(identifier).disabled(disabled)
        .padding(.horizontal).padding(.vertical, 10).background(.regularMaterial)
    }
}
