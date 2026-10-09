import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let studyBackup = UTType(exportedAs: "dev.shoug.studybackup", conformingTo: .zip) }

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.studyBackup, .zip] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw BackupError.invalidArchive }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct BackupView: View {
    @Bindable var store: StudyStore
    @Environment(\.dismiss) private var dismiss
    @State private var document: BackupDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var working = false
    @State private var selected: ValidatedBackup?
    @State private var confirmation = false
    @State private var failure: String?
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("完全バックアップを書き出す", action: export).disabled(working).accessibilityIdentifier("exportBackup")
                    Button("バックアップを選択") { document = nil; selected = nil; result = nil; importing = true }
                        .disabled(working).accessibilityIdentifier("importBackup")
                    if working { ProgressView("データを処理しています") }
                    if let result { Text(result).accessibilityIdentifier("backupResult") }
                } footer: { Text("デッキ、タグ、全カード・FSRS状態、回答履歴、画像、設定、下書きを1つの.studybackupファイルに保存します。書き出し先は自分で選択してください。") }
                if let selected {
                    Section {
                        LabeledContent("作成日時", value: selected.manifest.createdAt.formatted())
                        LabeledContent("アプリバージョン", value: selected.manifest.appVersion)
                        LabeledContent("デッキ", value: "\(selected.data.decks.count)")
                        LabeledContent("ノート", value: "\(selected.data.notes.count)")
                        LabeledContent("カード", value: "\(selected.data.cards.count)")
                        LabeledContent("回答履歴", value: "\(selected.data.logs.count)")
                        LabeledContent("画像", value: "\(selected.data.media.count)")
                        Button("このバックアップで置換して復元", role: .destructive) { confirmation = true }
                            .disabled(working).accessibilityIdentifier("restoreBackup")
                    } header: { Text("検証済みのバックアップ") } footer: { Text("現在のデータ全体を置き換えます。ZIP構造・サイズ・チェックサム・参照関係は検証済みです。必要なら先に現在のデータを書き出してください。") }
                }
            }
            .navigationTitle("バックアップ")
            .toolbar { Button("閉じる") { dismiss() }.disabled(working) }
            .interactiveDismissDisabled(working)
            .fileExporter(isPresented: $exporting, document: document, contentType: .studyBackup,
                          defaultFilename: "Study-\(store.clock().formatted(.iso8601.year().month().day().dateSeparator(.dash)))") { outcome in
                document = nil
                switch outcome {
                case .success: result = "バックアップを書き出しました。"
                case .failure(let error): if (error as NSError).code != NSUserCancelledError { failure = error.localizedDescription }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.studyBackup, .zip]) { outcome in
                do {
                    let url = try outcome.get()
                    Task {
                        working = true
                        defer { working = false }
                        do { selected = try await BackupService.read(url) }
                        catch { failure = error.localizedDescription }
                    }
                } catch { if (error as NSError).code != NSUserCancelledError { failure = error.localizedDescription } }
            }
            .confirmationDialog("既存データをすべて置換しますか？", isPresented: $confirmation, titleVisibility: .visible) {
                Button("置換して復元", role: .destructive) { restore() }.accessibilityIdentifier("confirmRestoreBackup")
            } message: { Text("検証済みデータを新しい保存領域に書き込み、成功した場合だけ切り替えます。処理に失敗した場合は元のデータを保持します。") }
            .alert("バックアップ処理に失敗しました", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("閉じる", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }
    }
    private func export() {
        selected = nil; document = nil; result = nil
        Task {
            working = true
            defer { working = false }
            do {
                let bytes = try await BackupService.export(repository: store.repository, now: store.clock(),
                                                           appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                document = BackupDocument(data: bytes); exporting = true
            } catch { failure = error.localizedDescription }
        }
    }
    private func restore() {
        guard let selected else { return }
        Task {
            working = true
            defer { working = false }
            await Task.yield()
            do {
                try store.restoreBackup(selected)
                self.selected = nil; result = "復元しました。ホームから学習を再開できます。"
            } catch { failure = error.localizedDescription }
        }
    }
}
