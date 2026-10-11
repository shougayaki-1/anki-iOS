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

enum BackupExportResult {
    case saved, cancelled
    var message: String {
        self == .saved ? "バックアップを書き出しました。" : "書き出しを取り消しました。保存は完了していません。"
    }
    var icon: String { self == .saved ? "checkmark.circle.fill" : "arrow.uturn.backward" }
}

struct BackupView: View {
    @Bindable var store: StudyStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var document: BackupDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var working = false
    @State private var selected: ValidatedBackup?
    @State private var confirmation = false
    @State private var failure: String?
    @State private var exportResult: BackupExportResult?
    @State private var restored: BackupRestoreOutcome?
    private var busy: Bool { working || exporting || importing }

    var body: some View {
        NavigationStack {
            Group {
                if let restored { restoreCompletion(restored) }
                else { backupForm }
            }
            .navigationTitle("バックアップ")
            .toolbar { Button("閉じる") { dismiss() }.disabled(busy) }
            .interactiveDismissDisabled(working)
            .fileExporter(isPresented: $exporting, document: document, contentTypes: [.studyBackup],
                          defaultFilename: "Study-\(store.clock().formatted(.iso8601.year().month().day().dateSeparator(.dash)))") { outcome in
                document = nil
                switch outcome {
                case .success:
                    exportResult = .saved
                    store.haptics.play(.backupCompleted, mode: store.settings.hapticsMode)
                    UIAccessibility.post(notification: .announcement, argument: exportResult?.message)
                case .failure(let error):
                    if (error as NSError).code == NSUserCancelledError { exportResult = .cancelled }
                    else { failure = error.localizedDescription }
                }
            } onCancellation: {
                document = nil
                exportResult = .cancelled
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.studyBackup, .zip]) { outcome in
                do {
                    let url = try outcome.get()
                    working = true
                    Task {
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
    private var backupForm: some View {
        Form {
            Section {
                Button("完全バックアップを書き出す", action: export).disabled(busy).accessibilityIdentifier("exportBackup")
                Button("バックアップを選択") { document = nil; selected = nil; exportResult = nil; importing = true }
                    .disabled(busy).accessibilityIdentifier("importBackup")
                if working { ProgressView("データを処理しています") }
            } footer: { Text("デッキ、タグ、全カード・FSRS状態、回答履歴、画像・音声、設定、下書きを1つの.studybackupファイルに保存します。書き出し先は自分で選択してください。") }
            if let exportResult {
                Section {
                    Label(exportResult.message, systemImage: exportResult.icon)
                        .accessibilityIdentifier("backupResult")
                    if exportResult == .saved {
                        Text("保存先はファイル画面で選択した場所です。端末の故障・紛失に備え、端末外でも安全に保管してください。").font(.footnote)
                    }
                }

            }
            if let selected {
                Section {
                    LabeledContent("作成日時", value: selected.manifest.createdAt.formatted())
                    LabeledContent("アプリバージョン", value: selected.manifest.appVersion)
                    LabeledContent("デッキ", value: "\(selected.data.decks.count)")
                    LabeledContent("ノート", value: "\(selected.data.notes.count)")
                    LabeledContent("カード", value: "\(selected.data.cards.count)")
                    LabeledContent("回答履歴", value: "\(selected.data.logs.count)")
                    LabeledContent("メディア（画像・音声）", value: "\(selected.data.media.count)")
                    Button("このバックアップで置換して復元", role: .destructive) { confirmation = true }
                        .disabled(busy).accessibilityIdentifier("restoreBackup")
                } header: { Text("検証済みのバックアップ") } footer: { Text("現在のデータ全体を置き換えます。ZIP構造・サイズ・チェックサム・参照関係は検証済みです。必要なら先に現在のデータを書き出してください。") }
            }
        }
    }
    private func restoreCompletion(_ outcome: BackupRestoreOutcome) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 68)).foregroundStyle(.green).accessibilityHidden(true)
                Text("復元が完了しました").font(.title2.bold()).accessibilityIdentifier("backupResult")
                if let summary = outcome.summary {
                    Text(summary.description).multilineTextAlignment(.center).accessibilityIdentifier("restoredBackupCounts")
                }
                Text("カード・学習履歴・設定を復元しました。ホームから学習を再開できます。")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let warning = outcome.warning { Text(warning).font(.footnote).accessibilityIdentifier("backupCommittedWarning") }
                Button("ホームへ戻る") { dismiss(); store.selectedTab = 0 }
                    .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("backupReturnHome")
                Button("ライブラリで確認") { dismiss(); store.selectedTab = 1 }
                    .accessibilityIdentifier("backupOpenLibrary")
            }.padding(32).frame(maxWidth: .infinity)
        }
        .transition(.opacity)
        .task {
            UIAccessibility.post(notification: .announcement, argument: "復元が完了しました。" + (outcome.summary?.description ?? ""))
        }
    }
    private func export() {
        guard !busy else { return }
        working = true
        selected = nil; document = nil; exportResult = nil
        Task {
            defer { working = false }
            do {
                let bytes = try await BackupService.export(repository: store.repository, now: store.clock(),
                                                           appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                document = BackupDocument(data: bytes); exporting = true
            } catch { failure = error.localizedDescription }
        }
    }
    private func restore() {
        guard !busy, restored == nil, let selected else { return }
        working = true
        Task {
            defer { working = false }
            await Task.yield()
            do {
                let outcome = try store.restoreBackup(selected)
                self.selected = nil; document = nil; exportResult = nil
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { restored = outcome }
                store.haptics.play(.backupCompleted, mode: store.settings.hapticsMode)
            } catch { failure = error.localizedDescription }
        }
    }
}
