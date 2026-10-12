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
struct DeckExchangeView: View {
    @Bindable var store: StudyStore
    @State private var rootID: UUID?
    @State private var selected: ValidatedDeckPackage?
    @State private var exportBytes: Data?
    @State private var preview: DeckImportPreview?
    @State private var skipDuplicates = true
    @State private var importing = false
    @State private var importingAnki = false
    @State private var ankiPreview: AnkiImportPreview?
    @State private var skippedPage = 0
    @State private var warningPage = 0
    @State private var exporting = false
    @State private var confirmation = false
    @State private var working = false
    @State private var operation: Task<Void, Never>?
    @State private var failure: String?
    @State private var result: String?
    @State private var page = 0
    @State private var shareURL: URL?

    var body: some View {
        Form {
            Section("デッキを渡す") {
                DeckSelectionField("選択デッキ", decks: store.decks, selection: $rootID, includesDescendants: true).disabled(working).accessibilityIdentifier("exchangeDeckPicker")
                Button("共有内容を確認", action: prepareExport).disabled(rootID == nil || working)
                    .accessibilityIdentifier("previewDeckExport")
                Text("選択デッキと子孫のノート・タグ・画像・音声を含みます。回答履歴、FSRS状態、個人設定、下書き、他のデッキは含みません。学習履歴の移行には完全バックアップを使用してください。")
                    .font(.footnote)
            }
            Section("デッキを受け取る") {
                Button(".studydeckファイルを選択") { clearPreview(); importingAnki = false; importing = true }
                    .disabled(working).accessibilityIdentifier("selectDeckFile")
                Text("既存データに追加します。全カードが未学習で開始し、同名デッキは別名で新しく作成します。")
                    .font(.footnote)
            }
            Section("Ankiから移行する") {
                Button("Anki .apkgを選択") { clearPreview(); importingAnki = true; importing = true }
                    .disabled(working).accessibilityIdentifier("selectAnkiPackage")
                DisclosureGroup("対応形式と変更点") {
                    Text("Ankiの最新.apkg（anki21b・schema 18）と旧形式（anki2/anki21・schema 11）に対応します。")
                    Text("基本・逆方向・穴埋めと、安全なフィールド参照のみの多フィールドテンプレートに対応。画像は問題面にJPEG/PNG1枚、音声は各面1本。文字装飾はプレーンテキストへ変わり、任意HTML/JS・画像遮蔽・動画・LaTeX・複数メディア等は未対応です。")
                    Text("AnkiのFSRS・予定・回答履歴は引き継げません。新規学習として開始します。未対応ノートと理由を表示し、対応するノートだけを確認してから追加します。")
                }.font(.footnote)
            }
            if working {
                Section {
                    ProgressView("ファイルを検証しています…")
                    Button("処理を取り消す") { operation?.cancel() }.accessibilityIdentifier("cancelDeckOperation")
                }
            }
            if let result { Text(result).accessibilityIdentifier("deckExchangeResult") }
            if let ankiPreview {
                Section("Ankiの移行結果") {
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
                        LabeledContent("取込先", value: preview.destinationName)
                        LabeledContent("重複ノート", value: "\(preview.duplicates.count)")
                        Toggle("重複をスキップ", isOn: $skipDuplicates).accessibilityIdentifier("skipDeckDuplicates")
                        Text("本文・形式・画像/音声の内容が同じノートを重複として扱います。タグや回答方法の違いは重複判定に含みません。既存ノートの上書きは行いません。")
                            .font(.footnote)
                        Button("確認して取り込む") { confirmation = true }.disabled(working || selected.package.notes.isEmpty)
                            .accessibilityIdentifier("confirmDeckImport")
                    } else if exportBytes != nil {
                        Button("Filesに書き出す") { exporting = true }.accessibilityIdentifier("exportDeckFile")
                        if let shareURL { ShareLink(item: shareURL) { Label("共有", systemImage: "square.and.arrow.up") }.accessibilityIdentifier("shareDeckFile") }
                    }
                    Button("プレビューを閉じる", action: clearPreview).disabled(working).accessibilityIdentifier("cancelDeckPreview")
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
        .navigationTitle("デッキファイル")
        .onAppear { if rootID == nil { rootID = store.decks.first?.id } }
        .onChange(of: rootID) { _, _ in clearPreview() }
        .onDisappear { operation?.cancel(); removeShareFile() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.studyDeck, .ankiPackage, .zip]) { outcome in
            switch outcome {
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { failure = error.localizedDescription }
            case .success(let url): run {
                let value: ValidatedDeckPackage
                if importingAnki {
                    let imported = try await AnkiImport.read(url)
                    try Task.checkCancellation()
                    value = imported.deck; ankiPreview = imported
                } else { value = try await DeckExchange.read(url) }
                try Task.checkCancellation()
                let summary = try store.repository.previewDeckImport(value)
                selected = value; preview = summary; page = 0
            }
            }
        }
        .fileExporter(isPresented: $exporting, document: exportBytes.map(DeckFileDocument.init), contentType: .studyDeck, defaultFilename: "StudyDeck-\(selected?.package.rootID.uuidString.prefix(8) ?? "Export")") { outcome in
            switch outcome {
            case .success: result = "デッキファイルを書き出しました。"
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { failure = error.localizedDescription }
            }
        }
        .confirmationDialog("新規カードとして取り込みますか？", isPresented: $confirmation, titleVisibility: .visible) {
            Button("取り込む") {
                guard let selected else { return }
                run {
                    try Task.checkCancellation()
                    let count = try store.repository.importDeckPackage(selected, skipDuplicates: skipDuplicates, now: store.clock())
                    try store.reload(); clearPreview(); result = "\(count)ノートを取り込みました。"
                }
            }.accessibilityIdentifier("commitDeckImport")
        } message: { Text("\(preview?.destinationName ?? "")へ追加します。既存のカード・回答履歴は保持されます。重複判定は確定時に再確認します。\(ankiPreview == nil ? "" : " Ankiの履歴は移行せず、未対応ノートを除外し、装飾はプレーンテキストになります。")") }
        .alert("デッキファイルを処理できません", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("閉じる", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        operation?.cancel(); working = true; result = nil
        operation = Task { @MainActor in
            defer { working = false }
            do { try await action() } catch is CancellationError {} catch { failure = error.localizedDescription }
        }
    }
    private func prepareExport() {
        guard let rootID else { return }
        clearPreview()
        run {
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
    private func clearPreview() { ankiPreview = nil; skippedPage = 0; warningPage = 0; selected = nil; exportBytes = nil; preview = nil; result = nil; page = 0; removeShareFile() }
    private func deckPath(_ id: UUID, in package: DeckPackage) -> String {
        var cursor: UUID? = id, names: [String] = []
        let byID = Dictionary(uniqueKeysWithValues: package.decks.map { ($0.id, $0) })
        while let id = cursor, let deck = byID[id] { names.append(deck.name); cursor = deck.parentID }
        return names.reversed().joined(separator: " / ")
    }
}
