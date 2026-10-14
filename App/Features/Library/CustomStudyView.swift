import SwiftUI

struct CustomStudyView: View {
    @Bindable var store: StudyStore
    private enum Field { case limit, name }
    @FocusState private var focusedField: Field?
    @State private var condition = CustomStudyCondition()
    @State private var preview = CustomStudyPreview()
    @State private var presets: [CustomStudyPreset] = []
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var failure: String?
    @State private var showingPractice = false
    @State private var hasPractice = false
    @State private var deleteTarget: CustomStudyPreset?

    var body: some View {
        Form {
            if hasPractice {
                Section("中断したカスタム練習") {
                    Button("練習を再開") { showingPractice = true }.accessibilityIdentifier("resumeCustomPractice")
                    Button("練習を終了", role: .destructive) {
                        run { try store.repository.finishCustomPractice(); reload() }
                    }
                }
            }
            Section("学習条件") {
                Picker("デッキ（子孫を含む）", selection: $condition.scope.deckID) {
                    Text("すべて").tag(nil as UUID?)
                    ForEach(store.decks) { Text($0.name).tag(Optional($0.id)) }
                }
                ForEach(store.tags) { tag in
                    Toggle(tag.name, isOn: Binding(get: { condition.scope.tagIDs.contains(tag.id) }, set: { selected in
                        condition.scope.tagIDs.removeAll { $0 == tag.id }
                        if selected { condition.scope.tagIDs.append(tag.id) }
                    }))
                }
                Text("選択したタグをすべて持つカードを対象にします。")
                    .font(.footnote).foregroundStyle(.secondary)
                Picker("出題条件", selection: $condition.criterion) {
                    ForEach(CustomStudyCriterion.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("上限", selection: $condition.limit) {
                    ForEach([10, 30, 50, 0], id: \.self) { Text($0 == 0 ? "すべて" : "\($0)枚").tag($0) }
                    if ![10, 30, 50, 0].contains(condition.limit) { Text("\(condition.limit)枚").tag(condition.limit) }
                }
                LabeledContent("任意数（0〜500）") {
                    TextField("上限", value: $condition.limit, format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .frame(width: 80).focused($focusedField, equals: .limit)
                }
                Text("0はすべてのカードを対象にします。")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("正式な復習として保存", isOn: $condition.official)
                Text(condition.official ? "期限到来カードのみ。FSRS・学習履歴を保存し、通常の復習画面でUndoできます。期限前カードの正式評価は非対応です。" : "練習のみ。FSRS・復習予定・学習履歴・今日の正式学習枚数と日次上限は変更しません。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("対象プレビュー") {
                Text("\(preview.cardIDs.count)枚・\(condition.criterion.title)・\(condition.official ? "正式復習" : "練習")")
                Text("停止・一時非表示と兄弟カード抑制を適用。1枚につき1回答。実行中の対象は固定し、削除・停止されたカードはスキップします。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let message = preview.message { Text(message).foregroundStyle(.secondary) }
                Button("対象を再構築") { rebuild() }
                Button("カスタム学習を開始") { start() }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(preview.cardIDs.isEmpty || hasPractice || store.review != nil).accessibilityIdentifier("startCustomStudy")
                if store.review != nil { Text("ホームから既存の学習を再開・終了してから開始してください。") }
            }
            Section("条件を保存") {
                TextField("プリセット名", text: $name).focused($focusedField, equals: .name).accessibilityIdentifier("customStudyName")
                Button(editingID == nil ? "条件を保存" : "条件を更新") {
                    run {
                        let preset = CustomStudyPreset(id: editingID ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), condition: condition)
                        try store.repository.saveCustomPreset(preset)
                        editingID = preset.id; reload()
                    }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("saveCustomStudy")
                if editingID != nil { Button("別の条件を新規作成") { editingID = nil; name = "" } }
            }
            Section("保存した条件") {
                ForEach(presets) { preset in
                    Button {
                        editingID = preset.id; name = preset.name; condition = preset.condition; rebuild()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(preset.name)
                            Text(preset.condition.criterion.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }.swipeActions { Button("削除", role: .destructive) { deleteTarget = preset } }
                }
            }
            if let failure { Section { Text(failure).foregroundStyle(.red) } }
        }
        .navigationTitle("カスタム学習")
        .scrollDismissesKeyboard(.interactively)
        .onSubmit { focusedField = nil }
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完了") { focusedField = nil } } }
        .onAppear { reload(); rebuild() }
        .onChange(of: condition) { _, _ in rebuild() }
        .confirmationDialog("保存した条件を削除しますか？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("削除", role: .destructive) {
                if let target = deleteTarget { run { try store.repository.deleteCustomPreset(target.id); reload() } }
                deleteTarget = nil
            }
        }
        .sheet(isPresented: $showingPractice, onDismiss: { reload(); rebuild() }) {
            CustomPracticeView(store: store)
        }
    }
    private func run(_ work: () throws -> Void) {
        do { try work(); failure = nil } catch { failure = error.localizedDescription }
    }
    private func reload() {
        run {
            let options = try store.repository.options()
            presets = options.customStudyPresets ?? []; hasPractice = options.customPractice != nil
        }
    }
    private func rebuild() {
        preview = CustomStudyPreview()
        run { preview = try store.repository.customStudyPreview(condition, now: store.clock()) }
    }
    private func start() {
        if condition.official {
            if store.perform(metadata: false, changed: false, {
                try store.repository.start(mode: .review, scope: condition.scope, customStudy: condition, customCardIDs: preview.cardIDs, now: store.clock())
            }) { store.showingReview = true }
            else { failure = store.failure }
        } else {
            run {
                try store.repository.startCustomPractice(condition, ids: preview.cardIDs, now: store.clock())
                hasPractice = true; showingPractice = true
            }
        }
    }
}

private struct CustomPracticeView: View {
    @Bindable var store: StudyStore
    @Environment(\.dismiss) private var dismiss
    @State private var progress: CustomPracticeProgress?
    @State private var card: NoteItem?
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("練習のみ・正式な学習履歴と復習予定は変更しません")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let progress {
                        Text(progress.condition.criterion.title)
                        Text("進行: \(progress.index) / \(progress.cardIDs.count)枚（スキップを含む）")
                        if let card {
                            Text(card.content.question).font(.title2)
                            if let id = card.sourceContent.imageID, let url = try? store.repository.assetURL(id: id) {
                                AsyncStudyImageView(file: url, namespace: store.mediaDisplayNamespace, revision: store.dataRevision, identity: id.uuidString,
                                    masks: card.kind == .imageOcclusion ? card.sourceContent.masks ?? [] : [],
                                    targetID: UUID(uuidString: String(card.variantKey.dropFirst("image:".count))),
                                    hideAll: card.sourceContent.hideAllMasks ?? true, revealed: progress.revealed)
                            }
                            if !progress.revealed { StudyHintView(hint: card.content.hint).id(card.cardID) }
                            if progress.revealed {
                                Text(card.content.answer)
                                if !card.content.explanation.isEmpty { Text(card.content.explanation).foregroundStyle(.secondary) }
                                Button("次のカード") { update(revealOnly: false) }.buttonStyle(PrimaryActionStyle()).accessibilityIdentifier("nextCustomPractice")
                            } else {
                                Button("答えを表示") { update(revealOnly: true) }.buttonStyle(PrimaryActionStyle()).accessibilityIdentifier("revealCustomPractice")
                            }
                        } else if failure == nil {
                            Text("カスタム練習が完了しました").font(.title2)
                            Button("練習を終了") {
                                do { try store.repository.finishCustomPractice(); dismiss() }
                                catch { failure = error.localizedDescription }
                            }.buttonStyle(PrimaryActionStyle()).accessibilityIdentifier("finishCustomPractice")
                        }
                    }
                    if let failure { Text(failure).foregroundStyle(.red); Button("再試行") { reload() } }
                }.padding()
            }
            .navigationTitle("カスタム練習")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("中断") { dismiss() } } }
            .onAppear { reload() }
            .onChange(of: store.dataRevision) { _, _ in reload() }
        }
    }
    private func reload() {
        do {
            card = try store.repository.customPracticeCard(now: store.clock())
            progress = try store.repository.options().customPractice; failure = nil
        } catch { card = nil; failure = error.localizedDescription }
    }
    private func update(revealOnly: Bool) {
        do { try store.repository.advanceCustomPractice(revealOnly: revealOnly, now: store.clock()); reload() }
        catch { failure = error.localizedDescription }
    }
}
