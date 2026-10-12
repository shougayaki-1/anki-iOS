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
    private var busy: Bool { working || exporting || importing || store.snapshotWorking }

    var body: some View {
        NavigationStack {
            Group {
                if let restored { restoreCompletion(restored) }
                else { backupForm }
            }
            .navigationTitle("バックアップ")
            .onAppear { store.refreshSnapshots() }
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
                Toggle("自動バックアップ", isOn: Binding(get: { store.snapshotPolicy.enabled }, set: {
                    var value = store.snapshotPolicy; value.enabled = $0; store.setSnapshotPolicy(value)
                })).disabled(busy)
                Picker("作成間隔", selection: Binding(get: { store.snapshotPolicy.intervalHours }, set: {
                    var value = store.snapshotPolicy; value.intervalHours = $0; store.setSnapshotPolicy(value)
                })) {
                    ForEach([6, 12, 24, 48], id: \.self) { Text("\($0)時間").tag($0) }
                }.disabled(busy)
                if let last = store.snapshots.first(where: { $0.kind == .automatic }) {
                    LabeledContent("前回の自動バックアップ", value: last.createdAt.formatted())
                    LabeledContent("次の対象目安", value: last.createdAt.addingTimeInterval(store.snapshotPolicy.interval).formatted())
                } else { Text("自動バックアップはまだありません") }
                if let error = store.snapshotFailure, store.snapshotFailures != 1 {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
                Button("今の復元ポイントを作成") {
                    working = true
                    Task {
                        defer { working = false }
                        do { try await store.createSnapshot(kind: .manual, reason: "手動復元ポイント") }
                        catch { failure = error.localizedDescription }
                    }
                }.disabled(busy)
            } header: { Text("端末内の復元ポイント") } footer: {
                Text("起動・画面復帰時に間隔を確認します。バックグラウンド実行は保証されません。画像・音声を含む正常な最大7世代・アーカイブ合計512MBを保存し、新しい世代が正常に保存された後に古い世代を削除します。変更前のポイントも保持枠を共有します。破損ファイル・移行前救済コピーは保持枠外です。端末故障・紛失には外部への書き出しが必要です。")
            }
            Section {
                LabeledContent("使用容量", value: ByteCountFormatter.string(fromByteCount: store.localSnapshots.diskBytes, countStyle: .file))
                ForEach(store.snapshots) { entry in
                    Button {
                        selected = nil; working = true
                        let manager = store.localSnapshots
                        Task {
                            defer { working = false }
                            do { selected = try await Task.detached(priority: .utility) { try manager.read(entry) }.value }
                            catch { failure = "この世代を読み込めません。他の正常な世代または外部ファイルを選んでください。\n" + error.localizedDescription }
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(entry.createdAt.formatted()).foregroundStyle(.primary)
                            Text("\(entry.kind.title) · \(entry.reason)").font(.caption)
                            Text("\(entry.decks)デッキ・\(entry.cards)カード · \(ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(busy)
                }
                if store.localSnapshots.unreadableCount(entries: store.snapshots) > 0 {
                    Text("一覧情報を読み込めない世代があります。正常な世代は利用できます。破損ファイルは自動削除していません。").font(.footnote).foregroundStyle(.orange)
                }
            } header: { Text("保存済みの世代（選択して検証・確認）") }
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
                } header: { Text("検証済みのバックアップ") } footer: { Text("現在のデータ全体を置き換えます。ZIP構造・サイズ・チェックサム・参照関係は検証済みです。復元直前に現在の完全復元ポイントを作成します。作成に失敗した場合、復元は実行しません。") }
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
                try await store.createRestorePoint("完全復元")
                try Task.checkCancellation()
                let outcome = try store.restoreBackup(selected)
                self.selected = nil; document = nil; exportResult = nil
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { restored = outcome }
                store.haptics.play(.backupCompleted, mode: store.settings.hapticsMode)
            } catch { failure = error.localizedDescription }
        }
    }
}

/// Available without a StudyStore: a migration/open error must not hide backups.
struct BackupRecoveryView: View {
    let location: StudyStorageLocation
    let recover: (ValidatedBackup) throws -> BackupRestoreOutcome
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [LocalSnapshot] = []
    @State private var selected: ValidatedBackup?
    @State private var working = false
    @State private var importing = false
    @State private var confirming = false
    @State private var failure: String?
    @State private var recoveryOutcome: BackupRestoreOutcome?
    @State private var rescueDocument: BackupDocument?
    @State private var exporting = false
    private var manager: LocalSnapshots { LocalSnapshots(location: location) }
    var body: some View {
        NavigationStack {
            Form {
                if let recoveryOutcome {
                    Section {
                        Label("復元が完了しました", systemImage: "checkmark.circle.fill")
                        if let summary = recoveryOutcome.summary { Text(summary.description) }
                        if let warning = recoveryOutcome.warning { Text(warning).foregroundStyle(.orange) }
                        Button("ホームへ戻る") { dismiss() }
                    }
                } else {
                Section {
                    Text("元の保存領域を開けないため、現在の完全復元ポイントは作成できません。正常なバックアップを検証して新しい保存領域へ復元し、成功した場合だけ切り替えます。元の保存領域は削除しません。")
                    Button("外部の.studybackupを選択") { selected = nil; importing = true }.disabled(working)
                    ForEach(entries) { entry in
                        Button("\(entry.createdAt.formatted()) · \(entry.kind.title) · \(entry.cards)カード") {
                            selected = nil; working = true
                            let manager = manager
                            Task {
                                defer { working = false }
                                do { selected = try await Task.detached(priority: .utility) { try manager.read(entry) }.value }
                                catch { failure = "この世代を読み込めません。他の世代を選んでください。\n" + error.localizedDescription }
                            }
                        }.disabled(working)
                    }
                }
                if let selected {
                    Section("検証済みの復元プレビュー") {
                        LabeledContent("作成日時", value: selected.manifest.createdAt.formatted())
                        Text("\(selected.data.decks.count)デッキ・\(selected.data.cards.count)カード・回答履歴\(selected.data.logs.count)件・メディア\(selected.data.media.count)件")
                        Text("全カード・FSRS状態・履歴・設定をこのバックアップの状態へ置換します。現在の開けないストアの変更は取り込まれません。")
                        Button("このバックアップから復元", role: .destructive) { confirming = true }.disabled(working)
                        Button("選択を取り消す", role: .cancel) { self.selected = nil }.disabled(working)
                    }
                }
                let rescues = MigrationRescue(location: location).archives
                if !rescues.isEmpty {
                    Section("移行前の救済ファイル") {
                        Text("SQLiteのWALを含めた整合コピーとメディアを保存しています。これは.studybackupではなく、旧アプリでの救済・調査用です。この画面からの完全復元は保証できません。")
                        ForEach(rescues, id: \.self) { url in
                            Button("\(url.lastPathComponent)を書き出す") {
                                working = true
                                Task {
                                    defer { working = false }
                                    do {
                                        let data = try await Task.detached(priority: .utility) { try Data(contentsOf: url, options: .mappedIfSafe) }.value
                                        rescueDocument = BackupDocument(data: data); exporting = true
                                    } catch { failure = error.localizedDescription }
                                }
                            }.disabled(working)
                        }
                    }
                }
                if working { ProgressView("検証・復元中") }
                }
            }
            .navigationTitle("バックアップから救済")
            .toolbar { Button("閉じる") { dismiss() }.disabled(working) }
            .interactiveDismissDisabled(working)
            .task {
                do { entries = try manager.list() }
                catch { failure = error.localizedDescription }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.studyBackup, .zip]) { result in
                do {
                    let url = try result.get(); working = true
                    Task {
                        defer { working = false }
                        do { selected = try await BackupService.read(url) }
                        catch { failure = error.localizedDescription }
                    }
                } catch { if (error as NSError).code != NSUserCancelledError { failure = error.localizedDescription } }
            }
            .fileExporter(isPresented: $exporting, document: rescueDocument, contentType: .zip, defaultFilename: "Study-Migration-Rescue") { result in
                if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError { failure = error.localizedDescription }
                rescueDocument = nil
            }
            .confirmationDialog("検証済みバックアップへ置換しますか？", isPresented: $confirming, titleVisibility: .visible) {
                Button("置換して復元", role: .destructive) {
                    guard let selected else { return }
                    working = true
                    Task { @MainActor in
                        defer { working = false }
                        await Task.yield()
                        do { recoveryOutcome = try recover(selected); self.selected = nil }
                        catch { failure = error.localizedDescription }
                    }
                }
            } message: { Text("元のストアを削除せず、検証済みの新しい保存領域へ切り替えます。") }
            .alert("救済処理に失敗しました", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("閉じる", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }
    }
}
