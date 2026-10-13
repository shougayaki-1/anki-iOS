import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let studyDeck = UTType(exportedAs: "dev.shoug.studydeck", conformingTo: .zip)
    static let ankiPackage = UTType(importedAs: "dev.shoug.anki-package", conformingTo: .zip)
}
struct DeckFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.studyDeck] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw BackupError.invalidArchive }
        data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
// Export remains in deck management; every import entry opens ImportView.
struct DeckExchangeView: View {
    @Bindable var store: StudyStore
    var body: some View { DeckPackagePreviewView(store: store) }
}

struct DeckPackagePreviewView: View {
    @Bindable var store: StudyStore
    @State private var destinationMode = 0
    @State private var destinationID: UUID?
    @State private var rootID: UUID?
    @State private var selected: ValidatedDeckPackage?
    @State private var exportBytes: Data?
    @State private var preview: DeckImportPreview?
    @State private var skipDuplicates = true
    @State private var ankiPreview: AnkiImportPreview?
    @State private var skippedPage = 0
    @State private var warningPage = 0
    @State private var exporting = false
    @State private var confirmation = false
    @State private var working = false
    @State private var operationPhase: ImportOperationPhase?
    @State private var operation: Task<Void, Never>?
    @State private var failure: String?
    @State private var completion: DeckExchangeCompletion?
    @State private var showingCompletion = false
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var shareURL: URL?
    private let isImport: Bool
    let chooseFile: (() -> Void)?
    let continueImport: (() -> Void)?
    let busyChanged: (Bool) -> Void

    init(store: StudyStore, package: ValidatedDeckPackage? = nil, anki: AnkiImportPreview? = nil,
         initialDeckID: UUID? = nil, chooseFile: (() -> Void)? = nil,
         continueImport: (() -> Void)? = nil, busyChanged: @escaping (Bool) -> Void = { _ in }) {
        self.store = store
        isImport = package != nil
        _selected = State(initialValue: package)
        _ankiPreview = State(initialValue: anki)
        _destinationID = State(initialValue: initialDeckID ?? store.decks.first?.id)
        _destinationMode = State(initialValue: initialDeckID == nil ? 0 : 1)
        self.chooseFile = chooseFile; self.continueImport = continueImport; self.busyChanged = busyChanged
    }

    var body: some View {
        Form {
            if !isImport {
            Section("デッキを渡す") {
                DeckSelectionField("選択デッキ", decks: store.decks, selection: $rootID, includesDescendants: true).disabled(working).accessibilityIdentifier("exchangeDeckPicker")
                Button("共有内容を確認", action: prepareExport).disabled(rootID == nil || working)
                    .accessibilityIdentifier("previewDeckExport")
                Text("選択デッキと子孫のノート・タグ・画像・音声を含みます。回答履歴、FSRS状態、個人設定、下書き、他のデッキは含みません。学習履歴の移行には完全バックアップを使用してください。")
                    .font(.footnote)
            }
            Section("ファイルを取り込む") {
                NavigationLink("インポート") { ImportView(store: store, initialDeckID: rootID) }
                    .accessibilityIdentifier("openUnifiedImport")
                Text("CSV / TSV / TXT / 画像ZIP / .studydeck / .apkgを同じ画面から選べます。")
                    .font(.footnote)
            }
            } else if let chooseFile {
                Section { ImportFileSelectionButton(action: chooseFile) }
            }
            if let ankiPreview {
                Section("Ankiの移行結果") {
                    DisclosureGroup("対応形式と変更点") {
                        Text("最新.apkg（anki21b・schema 18）と旧形式（anki2/anki21・schema 11）に対応します。")
                        Text("基本・逆方向・穴埋め、安全なフィールド参照の多フィールドテンプレートに対応。画像は問題面にJPEG/PNG1枚、音声は各面1本です。")
                        Text("任意HTML/JS・画像遮蔽・動画・LaTeX・複数メディア等は未対応です。AnkiのFSRS・復習予定・回答履歴は引き継ぎません。")
                    }.font(.footnote)
                    LabeledContent("元ノート", value: "\(ankiPreview.sourceNotes)")
                    LabeledContent("元カード", value: "\(ankiPreview.sourceCards)")
                    LabeledContent("未対応ノート", value: "\(ankiPreview.skipped.count)").accessibilityIdentifier("ankiSkippedCount")
                    Text("学習済みカード\(ankiPreview.scheduledCards)件・回答履歴\(ankiPreview.reviewLogs)件は取り込みません。すべて新規学習として開始します。文字装飾やテンプレートの配置も移行しません。")
                        .font(.footnote).accessibilityIdentifier("ankiHistoryPolicy")
                    if !ankiPreview.warnings.isEmpty {
                        LabeledContent("本文のみ移行・フィールド省略の警告", value: "\(ankiPreview.warnings.count)")
                        Text("欠落音声は追加しません。以下の変更を確認してから取り込んでください。").font(.footnote)
                        ForEach(Array(ankiPreview.warnings.dropFirst(warningPage * 100).prefix(100))) { item in
                            Text("ノート\(item.id)：\(item.reason)").font(.footnote)
                        }
                        if ankiPreview.warnings.count > 100 {
                            HStack {
                                Button("警告の前へ") { warningPage -= 1 }.disabled(warningPage == 0)
                                Button("警告の次へ") { warningPage += 1 }.disabled((warningPage + 1) * 100 >= ankiPreview.warnings.count)
                            }
                        }
                    }
                    ForEach(Array(ankiPreview.skipped.dropFirst(skippedPage * 100).prefix(100))) { item in
                        Text("ノート\(item.id)：\(item.reason)").font(.footnote)
                    }
                    if ankiPreview.skipped.count > 100 {
                        HStack {
                            Button("未対応の前へ") { skippedPage -= 1 }.disabled(skippedPage == 0)
                            Button("未対応の次へ") { skippedPage += 1 }.disabled((skippedPage + 1) * 100 >= ankiPreview.skipped.count)
                        }
                    }
                }
            }
            if let selected {
                Section(exportBytes == nil ? "取込プレビュー" : "共有プレビュー") {
                    LabeledContent("デッキ", value: "\(selected.package.decks.count)")
                    LabeledContent("ノート", value: "\(selected.package.notes.count)")
                    LabeledContent("生成カード", value: "\(selected.cardCount)")
                    LabeledContent("画像・音声", value: "\(selected.package.media.count)")
                    ForEach(selected.package.decks, id: \.id) { deck in
                        Text(deckPath(deck.id, in: selected.package)).font(.footnote)
                    }
                    if let preview, exportBytes == nil {
                        if isImport {
                            Picker("取込方法", selection: $destinationMode) {
                                Text("新規デッキとして追加").tag(0)
                                Text("既存デッキの下へ追加").tag(1)
                                Text("選択した既存デッキに統合").tag(2)
                            }.disabled(working).accessibilityIdentifier("deckImportMode")
                            if destinationMode != 0 {
                                DeckSelectionField("取込先", decks: store.decks, selection: $destinationID)
                                    .disabled(working).accessibilityIdentifier("deckImportDestination")
                            }
                        }
                        LabeledContent("取込先", value: preview.destinationName)
                        LabeledContent("追加デッキ", value: "\(preview.mappings.filter { !$0.reused }.count)")
                        LabeledContent("再利用デッキ", value: "\(preview.mappings.filter(\.reused).count)")
                        DisclosureGroup("階層の変更を確認") {
                            ForEach(preview.mappings) { mapping in
                                Text("\(mapping.sourcePath) → \(mapping.destinationPath)（\(mapping.reused ? "再利用" : "追加")）")
                                    .font(.footnote)
                            }
                        }
                        LabeledContent("追加ノート", value: "\(selected.package.notes.filter { !skipDuplicates || !preview.duplicates.contains($0.id) }.count)")
                        LabeledContent("追加カード", value: "\(selected.package.notes.filter { !skipDuplicates || !preview.duplicates.contains($0.id) }.reduce(0) { $0 + ((try? CardGeneration.variants(kind: $1.kind, content: $1.content).count) ?? 0) })")
                        LabeledContent("重複ノート", value: "\(preview.duplicates.count)")
                        Toggle("重複をスキップ", isOn: $skipDuplicates).accessibilityIdentifier("skipDeckDuplicates")
                        Text("本文・形式・画像/音声の内容が同じノートを重複として扱います。タグや回答方法の違いは重複判定に含みません。既存ノートの上書きは行いません。")
                            .font(.footnote)

                    } else if exportBytes != nil {
                        Button("Filesに書き出す") { exporting = true }.accessibilityIdentifier("exportDeckFile")
                        if let shareURL { ShareLink(item: shareURL) { Label("共有", systemImage: "square.and.arrow.up") }.accessibilityIdentifier("shareDeckFile") }
                    }
                    Button("プレビューを閉じる") { if isImport { continueImport?() } else { clearPreview() } }.disabled(working).accessibilityIdentifier("cancelDeckPreview")
                }
                Section("内容（\(page + 1)ページ）") {
                    ForEach(Array(selected.package.notes.dropFirst(page * 100).prefix(100)), id: \.id) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.content.question).lineLimit(3)
                            Text(note.content.answer).lineLimit(3).foregroundStyle(.secondary)
                            Text("\(note.kind.rawValue)・\(note.tags.joined(separator: ", "))").font(.caption)
                            if preview?.duplicates.contains(note.id) == true { Text("重複").font(.caption) }
                        }
                    }
                    HStack {
                        Button("前へ") { page -= 1 }.disabled(page == 0)
                        Button("次へ") { page += 1 }.disabled((page + 1) * 100 >= selected.package.notes.count)
                    }
                }
            }
        }
        .disabled(working)
        .navigationBarBackButtonHidden(working)
        .interactiveDismissDisabled(working)
        .overlay {
            if let operationPhase {
                ImportProcessingOverlay(phase: operationPhase, cancel: operationPhase.canCancel ? { operation?.cancel() } : nil)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isImport, let selected, let preview, !showingCompletion {
                ImportConfirmationButton(identifier: "confirmDeckImport", disabled: working ||
                    !selected.package.notes.contains { !skipDuplicates || !preview.duplicates.contains($0.id) }) {
                    confirmation = true
                }
            }
        }
        .navigationTitle(isImport ? "インポート" : "デッキファイル")
        .onChange(of: working) { _, value in busyChanged(value) }
        .onAppear { if !isImport && rootID == nil { rootID = store.decks.first?.id }; if destinationID == nil { destinationID = store.decks.first?.id }; if isImport { refreshImportPreview() } }
        .onChange(of: destinationMode) { _, _ in refreshImportPreview() }
        .onChange(of: destinationID) { _, _ in refreshImportPreview() }
        .onChange(of: rootID) { _, _ in if !isImport { clearPreview() } }
        .onDisappear { operation?.cancel(); if !showingCompletion { removeShareFile() } }
        .sheet(isPresented: $showingCompletion, onDismiss: { completion = nil }) {
            if let completion {
                NavigationStack {
                    DeckExchangeCompletionView(store: store, completion: completion,
                        retry: { showingCompletion = false; self.completion = nil },
                        continueImport: { showingCompletion = false; if isImport { continueImport?() } else { clearPreview() } },
                        close: { showingCompletion = false; clearPreview(); dismiss() })
                }
            }
        }
        .fileExporter(isPresented: $exporting, document: exportBytes.map(DeckFileDocument.init), contentType: .studyDeck, defaultFilename: "StudyDeck-\(selected?.package.rootID.uuidString.prefix(8) ?? "Export")") { outcome in
            switch outcome {
            case .success(let url):
                let name = selected?.package.decks.first(where: { $0.id == selected?.package.rootID })?.name ?? "デッキ"
                completion = .exported(name: name, url: shareURL ?? url); showingCompletion = true
                store.haptics.play(.importCompleted, mode: store.settings.hapticsMode)
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { failure = error.localizedDescription }
            }
        }
        .confirmationDialog("新規カードとして取り込みますか？", isPresented: $confirmation, titleVisibility: .visible) {
            Button("取り込む") {
                guard !working, completion == nil, let selected else { return }
                run(phase: .preparing) {
                    try Task.checkCancellation()
                    try await store.createRestorePoint("デッキ・APKGの取り込み")
                    try Task.checkCancellation()
                    operationPhase = .saving
                    await ImportOperationPhase.allowDisplay()
                    var receipt = try store.repository.importDeckPackageReceipt(selected, skipDuplicates: skipDuplicates, now: store.clock(), destination: importDestination, expectedPreview: preview)
                    receipt.skipped = ankiPreview?.skipped ?? []
                    receipt.warnings = ankiPreview?.warnings ?? []
                    var warning: String?
                    if receipt.createdNotes > 0 {
                        operationPhase = .refreshing
                        await ImportOperationPhase.allowDisplay()
                        do { try store.reload() }
                        catch { warning = "保存は完了しましたが、表示を更新できません。再取り込みせず、アプリを開き直してください。\n" + error.localizedDescription }
                        clearPreview()
                    }
                    completion = .imported(receipt, reloadWarning: warning); showingCompletion = true
                    if receipt.outcome == .complete { store.haptics.play(.importCompleted, mode: store.settings.hapticsMode) }
                }
            }.accessibilityIdentifier("commitDeckImport")
        } message: { Text("\(preview?.destinationName ?? "")へ追加します。既存のカード・回答履歴は保持されます。重複判定は確定時に再確認します。\(ankiPreview == nil ? "" : " Ankiの履歴は移行せず、未対応ノートを除外し、装飾はプレーンテキストになります。")") }
        .alert("デッキファイルを処理できません", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("閉じる", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }
    private var importDestination: DeckImportDestination {
        guard let destinationID else { return .newRoot }
        switch destinationMode {
        case 1: return .childOf(destinationID)
        case 2: return .mergeInto(destinationID)
        default: return .newRoot
        }
    }
    private func refreshImportPreview() {
        guard let selected, exportBytes == nil else { return }
        do { preview = try store.repository.previewDeckImport(selected, destination: importDestination) }
        catch { preview = nil; failure = error.localizedDescription }
    }
    private func run(phase: ImportOperationPhase, _ action: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true; operationPhase = phase; completion = nil
        operation = Task { @MainActor in
            defer { working = false; operationPhase = nil }
            do { await ImportOperationPhase.allowDisplay(); try await action() } catch is CancellationError {} catch { refreshImportPreview(); failure = error.localizedDescription }
        }
    }
    private func prepareExport() {
        guard let rootID else { return }
        clearPreview()
        run(phase: .exporting) {
            let bytes = try await DeckExchange.export(repository: store.repository, rootID: rootID)
            try Task.checkCancellation()
            let value = try await Task.detached(priority: .utility) { try DeckExchange.decode(bytes) }.value
            try Task.checkCancellation()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeckShare-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("StudyDeck.studydeck")
            do { try bytes.write(to: url, options: .atomic) } catch { try? FileManager.default.removeItem(at: directory); throw error }
            shareURL = url; selected = value; exportBytes = bytes; page = 0
        }
    }
    private func removeShareFile() {
        if let shareURL { try? FileManager.default.removeItem(at: shareURL.deletingLastPathComponent()) }
        shareURL = nil
    }
    private func clearPreview() { ankiPreview = nil; skippedPage = 0; warningPage = 0; selected = nil; exportBytes = nil; preview = nil; completion = nil; page = 0; removeShareFile() }
    private func deckPath(_ id: UUID, in package: DeckPackage) -> String {
        var cursor: UUID? = id, names: [String] = []
        let byID = Dictionary(uniqueKeysWithValues: package.decks.map { ($0.id, $0) })
        while let id = cursor, let deck = byID[id] { names.append(deck.name); cursor = deck.parentID }
        return names.reversed().joined(separator: " / ")
    }
}

enum DeckExchangeCompletion {
    case imported(DeckImportReceipt, reloadWarning: String?)
    case exported(name: String, url: URL)

    var title: String {
        switch self {
        case .imported(let receipt, _): return receipt.title
        case .exported: return "デッキファイルを書き出しました"
        }
    }
    var isSuccess: Bool {
        switch self {
        case .imported(let receipt, _): return receipt.outcome == .complete
        case .exported: return true
        }
    }
    var canRetry: Bool {
        if case .imported(let receipt, _) = self { return receipt.outcome == .empty }
        return false
    }
}

private struct DeckExchangeCompletionView: View {
    @Bindable var store: StudyStore
    let completion: DeckExchangeCompletion
    let retry: () -> Void
    let continueImport: () -> Void
    let close: () -> Void
    @State private var announced = false
    @State private var skippedPage = 0
    @State private var warningPage = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ImportCompletionHeader(title: completion.title, complete: completion.isSuccess)
                switch completion {
                case .imported(let receipt, let warning):
                    Text(receipt.summary).accessibilityIdentifier("deckExchangeResult")
                    if let name = receipt.destinationName { Text("保存先：" + name) }
                    if receipt.outcome == .empty {
                        Text("保存したノートはありません。重複・未対応の理由を確認してください。プレビューを保持しているので再試行できます。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("すべて新規学習として追加しました。既存カードの学習履歴・復習状態は保持されています。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let warning { Text(warning).foregroundStyle(.orange).accessibilityIdentifier("deckImportCommittedWarning") }
                    if !receipt.skipped.isEmpty {
                        reasons("未対応ノートの理由", items: receipt.skipped, page: $skippedPage)
                    }
                    if !receipt.warnings.isEmpty {
                        reasons("本文・メディア変更の理由", items: receipt.warnings, page: $warningPage)
                    }
                    if let deckID = receipt.rootDeckID, warning == nil {
                        NavigationLink {
                            ShortcutDeckContentsView(store: store, deckID: deckID)
                        } label: { Text("取り込んだデッキを見る").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .accessibilityIdentifier("viewImportedDeck")
                    }
                    if completion.canRetry {
                        Button("プレビューに戻って再試行", action: retry).buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("retryDeckImport")
                    }
                    Button("続けて取り込む", action: continueImport).buttonStyle(.bordered)
                        .accessibilityIdentifier("continueDeckImport")
                case .exported(let name, let url):
                    Text(name).accessibilityIdentifier("deckExchangeResult")
                    Text("Filesへの保存が完了しました。相手への共有はまだ行っていません。")
                        .font(.footnote).foregroundStyle(.secondary)
                    ShareLink(item: url) { Label("共有する", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("shareExportedDeck")
                    Button("デッキファイルに戻る", action: continueImport).buttonStyle(.bordered)
                }
                Button("閉じる", action: close).accessibilityIdentifier("closeDeckCompletion")
            }
            .multilineTextAlignment(.center).padding(24).frame(maxWidth: .infinity)
        }
        .onAppear {
            guard !announced else { return }
            announced = true
            let summary: String
            switch completion {
            case .imported(let receipt, _): summary = receipt.summary
            case .exported(let name, _): summary = name + "。共有はまだ行っていません。"
            }
            UIAccessibility.post(notification: .announcement, argument: completion.title + "。" + summary)
        }
    }
    private func reasons(_ title: String, items: [AnkiSkippedNote], page: Binding<Int>) -> some View {
        DisclosureGroup("\(title)（\(items.count)件）") {
            ForEach(Array(items.dropFirst(page.wrappedValue * 100).prefix(100))) { item in
                Text("ノート\(item.id)：\(item.reason)").font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if items.count > 100 {
                HStack {
                    Button("前へ") { page.wrappedValue -= 1 }.disabled(page.wrappedValue == 0)
                    Button("次へ") { page.wrappedValue += 1 }.disabled((page.wrappedValue + 1) * 100 >= items.count)
                }
            }
        }
    }
}
