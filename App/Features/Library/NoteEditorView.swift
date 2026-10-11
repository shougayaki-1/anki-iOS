import SwiftUI
import UniformTypeIdentifiers

struct NoteEditorView: View {
    @Bindable var store: StudyStore
    let item: NoteItem?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @FocusedValue(\.numericSettingEditing) private var numericSettingEditing
    @State private var kanbunBase = ""
    @State private var kanbunOkuri = ""
    @State private var kanbunMark = "レ"
    @State private var kanbunLeft = ""
    @State private var rubySide = false
    @State private var rubyBase = ""
    @State private var rubyReading = ""
    @State private var input: NoteInput
    @State private var tagText: String
    @State private var historyChoice = false
    @State private var failure: String?
    @State private var pendingUpdateID: UUID?
    @State private var duplicateID: UUID?
    @State private var duplicateChoice = false
    @State private var crop = false
    @State private var committed = false
    @State private var ocrWorking = false
    @State private var pendingReset = false
    @State private var preview = false
    @State private var saveFailure = false
    @State private var saveNext = false
    @State private var audioSelecting = false
    @State private var audioSide = SpeechSide.question
    @State private var audioWorking = false
    @State private var audioImport: Task<Void, Never>?
    @StateObject private var audioPreview = StudySpeechPlayer()

    init(store: StudyStore, item: NoteItem?, initialDeckID: UUID? = nil) {
        self.store = store; self.item = item
        _tagText = State(initialValue: item?.tagNames.joined(separator: ", ") ?? "")
        _input = State(initialValue: NoteInput(deckID: item?.deckID ?? initialDeckID ?? store.decks.first?.id ?? UUID(),
                                               kind: item?.kind ?? .basic,
                                               question: item?.sourceContent.question ?? "",
                                               answer: item?.sourceContent.answer ?? "",
                                               explanation: item?.sourceContent.explanation ?? "",
                                               hint: item?.sourceContent.hint,
                                               responseMode: item?.responseMode ?? .mental, tagNames: item?.tagNames ?? [], reverseEnabled: item?.sourceContent.reverseEnabled ?? false,
                                               imageID: item?.sourceContent.imageID, masks: item?.sourceContent.masks ?? [],
                                               hideAllMasks: item?.sourceContent.hideAllMasks ?? true,
                                               speechOverrides: item?.sourceContent.speechOverrides ?? [:],
                                               speechQuestion: item?.sourceContent.speechQuestion,
                                               speechAnswer: item?.sourceContent.speechAnswer, questionAudioID: item?.sourceContent.questionAudioID,
                                               answerAudioID: item?.sourceContent.answerAudioID, questionLayout: item?.sourceContent.questionLayout, answerLayout: item?.sourceContent.answerLayout))
        do {
            if let saved = try store.repository.editorDraft(key: item.map { "edit:\($0.noteID.uuidString)" } ?? "new") {
                _input = State(initialValue: saved)
                _tagText = State(initialValue: saved.tagNames.joined(separator: ", "))
            }
        } catch { _failure = State(initialValue: "下書きを読み込めません: " + error.localizedDescription) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DeckSelectionField("デッキ", decks: store.decks, selection: $input.deckID).accessibilityIdentifier("noteDeckPicker")
                    Picker("形式", selection: $input.kind) {
                        ForEach(NoteKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("noteKindPicker")
                    Picker("標準の回答方法", selection: $input.responseMode) {
                        ForEach(ResponseMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                                .disabled(mode == .ordering && OrderingAnswer.reason(kind: input.kind, answer: input.answer) != nil)
                        }
                    }.accessibilityIdentifier("noteResponseMode")
                }
                if input.kind == .basic { Toggle("裏表反転カードも作る", isOn: $input.reverseEnabled) }
                if input.kind == .cloze {
                    Text("例：日本の首都は {{c1::東京}}。番号ごとにカードを作ります。既存の番号を維持すると学習履歴も維持できます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("本文の表示") {
                    Picker("問題面", selection: Binding(get: { input.questionLayout ?? .horizontal }, set: { input.questionLayout = $0 })) {
                        ForEach(TextLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("questionLayout")
                    Picker("解答面", selection: Binding(get: { input.answerLayout ?? .horizontal }, set: { input.answerLayout = $0 })) {
                        ForEach(TextLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("answerLayout")
                    Text("ルビ：｜漢字《かんじ》。明示した語に付けます。縦書きは右から左に列が進み、2桁数字は縦中横にします。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let warning = RubyDocument.parse(input.question).warning ?? RubyDocument.parse(input.answer).warning {
                        Text(warning).font(.footnote).foregroundStyle(.orange)
                    }
                    DisclosureGroup("ルビを末尾に追加") {
                        Toggle("解答面に追加", isOn: $rubySide)
                        TextField("親文字", text: $rubyBase)
                        TextField("読み", text: $rubyReading)
                        Button("ルビを追加") {
                            let value = "｜\(rubyBase)《\(rubyReading)》"
                            if rubySide { input.answer += value } else { input.question += value }
                            rubyBase = ""; rubyReading = ""
                        }.disabled(rubyBase.isEmpty || rubyReading.isEmpty || (rubyBase + rubyReading).contains(where: { "｜|《》\n".contains($0) }))
                    }
                }
                Section("漢文の訓点") {
                    Text("例：不［＃（ズ）］［＃レ］知［＃（ラ）］。返り点は左下、送り仮名は右下へ配置します。訓点付き本文は縦書きを推奨します。")
                        .font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup("訓点付きの字を末尾に追加") {
                        Toggle("解答面に追加", isOn: $rubySide)
                        TextField("漢字1字", text: $kanbunBase)
                        TextField("送り仮名（任意）", text: $kanbunOkuri)
                        Picker("返り点", selection: $kanbunMark) {
                            Text("なし").tag("")
                            ForEach(KanbunDocument.returnMarks, id: \.self) { Text($0).tag($0) }
                        }
                        TextField("再読の左ルビ（任意）", text: $kanbunLeft)
                        Button("訓点付きの字を追加") {
                            var value = kanbunBase
                            if !kanbunOkuri.isEmpty { value += "［＃（\(kanbunOkuri)）］" }
                            if !kanbunMark.isEmpty { value += "［＃\(kanbunMark)］" }
                            if !kanbunLeft.isEmpty { value += "［＃「\(kanbunBase)」の左に「\(kanbunLeft)」のルビ］" }
                            if rubySide { input.answer += value } else { input.question += value }
                            kanbunBase = ""; kanbunOkuri = ""; kanbunLeft = ""
                        }.disabled(kanbunBase.count != 1 || kanbunOkuri.count > 32 || kanbunLeft.count > 32 || (kanbunBase + kanbunOkuri + kanbunLeft).contains(where: { "［］「」\n".contains($0) }))
                    }
                }
                Section("問題") {
                    TextField("問題文", text: $input.question, axis: .vertical).lineLimit(3...10)
                        .accessibilityIdentifier("questionInput")
                }
                Section("解答") {
                    TextField("解答・模範解答", text: $input.answer, axis: .vertical).lineLimit(3...10)
                        .accessibilityIdentifier("answerInput")
                }
                Section {
                    TextField("ヒント", text: Binding(get: { input.hint ?? "" }, set: { input.hint = $0 }), axis: .vertical)
                        .lineLimit(2...8).accessibilityIdentifier("hintInput")
                } header: { Text("ヒント（任意）") } footer: {
                    Text("解答前に手動で開く手がかりです。同じノートのカードで共通ですが、裏表反転の逆向きカードには表示しません。")
                }
                Section {
                    Text("読み上げ設定を変更しても復習予定や回答履歴は変わりません。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let variants = speechVariants, !variants.isEmpty {
                        ForEach(variants, id: \.self) { variant in
                            Picker(variants.count == 1 ? "自動読み上げ" : "自動読み上げ（\(variant)）", selection: Binding(
                                get: { input.speechOverrides?[variant] },
                                set: { value in
                                    var overrides = input.speechOverrides ?? [:]
                                    overrides[variant] = value
                                    input.speechOverrides = overrides.isEmpty ? nil : overrides
                                }
                            )) {
                                Text("デッキに従う").tag(SpeechAutoplay?.none)
                                ForEach(SpeechAutoplay.allCases) { mode in
                                    Text(mode.title).tag(Optional(mode))
                                }
                            }
                            .accessibilityIdentifier("noteSpeech-\(variant)")
                        }
                    }
                    if input.kind != .cloze {
                        TextField("問題面の読み上げ用英文（任意）", text: Binding(
                            get: { input.speechQuestion ?? "" }, set: { input.speechQuestion = $0 }
                        ), axis: .vertical).lineLimit(1...5).accessibilityIdentifier("speechQuestionInput")
                        TextField("解答面の読み上げ用英文（任意）", text: Binding(
                            get: { input.speechAnswer ?? "" }, set: { input.speechAnswer = $0 }
                        ), axis: .vertical).lineLimit(1...5).accessibilityIdentifier("speechAnswerInput")
                    }
                    Text("日本語混在は自動検出では読みません。英文のみを指定すると日本語の問題でも読み上げできます。穴埋めの伏せ字は読み上げません。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("音声読み上げ") }
                Section("添付音声（任意）") {
                    audioRow(.question)
                    audioRow(.answer)
                    if audioWorking { ProgressView("音声を確認しています…") }
                    if let notice = audioPreview.notice { Text(notice).font(.footnote).foregroundStyle(.red) }
                    Text("WAV・M4A・MP3・AAC・CAF、20MB・10分以内。添付音声を優先し、TTSは学習中に手動で選べます。自動再生は上の設定を使用します。穴埋め・画像マスクの問題音声には答えを含めないでください。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if !input.answer.isEmpty, let reason = OrderingAnswer.reason(kind: input.kind, answer: input.answer) {
                        Text(reason).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let variants = speechVariants {
                        Text("このノートから\(variants.count)枚の学習カードを作成")
                            .accessibilityIdentifier("generatedCardCount")
                    }
                    Button("出題プレビュー") { preview = true }.accessibilityIdentifier("previewNote")
                    if item == nil { Button("保存して次へ") { requestSave(next: true) }.disabled(!canSave) }
                }
                Section("タグ") { TextField("タグ（カンマ区切り）", text: $tagText) }
                Section("画像（任意）") {
                    PhotoInputControls { data in
                        do {
                            input.imageID = try store.repository.addImage(data, now: store.clock())
                            if input.question.isEmpty && input.kind == .imageOcclusion { input.question = "画像の隠した部分を答えてください" }
                        } catch { failure = error.localizedDescription }
                    }
                    if let image = image {
                        if input.kind == .imageOcclusion {
                            Toggle("全マスクを隠す", isOn: $input.hideAllMasks)
                            MaskEditorView(image: image, masks: $input.masks)
                        } else { StudyImageView(image: image) }
                        Button("トリミング") { crop = true }
                        Button("文字を認識して問題文に追加") { recognize() }.disabled(ocrWorking)
                        if ocrWorking { ProgressView("文字を認識中") }
                        Button("画像を外す", role: .destructive) { input.imageID = nil; input.masks = [] }
                    } else if input.imageID != nil { Text("画像を読み込めません。写真を再選択してください。").foregroundStyle(.red) }
                }
                Section {
                    Button("下書きを破棄して閉じる", role: .destructive) {
                        do { try store.repository.discardEditorDraft(key: draftKey); committed = true; dismiss() }
                        catch { failure = error.localizedDescription }
                    }
                }
                Section("解説（任意）") {
                    TextField("解説", text: $input.explanation, axis: .vertical).lineLimit(2...8)
                }
            }
.frame(maxWidth: UIDevice.current.userInterfaceIdiom != .phone ? 820 : .infinity)
            .frame(maxWidth: .infinity)
            .scrollDismissesKeyboard(.interactively)
            .onDisappear { audioPreview.stop(); audioImport?.cancel() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { audioPreview.stop() } }
            .fileImporter(isPresented: $audioSelecting, allowedContentTypes: [.audio]) { result in
                switch result {
                case .failure(let error): failure = error.localizedDescription
                case .success(let url):
                    let side = audioSide
                    audioWorking = true
                    audioImport = Task {
                        defer { audioWorking = false }
                        do {
                            let prepared = try await AudioEncodingPolicy.read(url)
                            try Task.checkCancellation()
                            let id = try store.repository.addAudio(prepared, now: store.clock())
                            if side == .question { input.questionAudioID = id } else { input.answerAudioID = id }
                        } catch is CancellationError {} catch { failure = error.localizedDescription }
                    }
                }
            }
            .onChange(of: tagText) { _, value in input.tagNames = value.components(separatedBy: ",") }
            .onChange(of: input) { _, _ in if !committed { persistDraft() } }
            .sheet(isPresented: $preview) { NotePreviewView(input: input, image: image) }
            .sheet(isPresented: $crop) {
                if let image { CropView(image: image) { applyCrop($0) } }
            }
            .navigationTitle(item == nil ? "カード追加" : "カード編集")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if numericSettingEditing != true {
                        Spacer()
                        Button("完了") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { persistDraft(); if failure == nil { dismiss() } }.keyboardShortcut(.escape, modifiers: []).accessibilityIdentifier("closeEditor").accessibilityHint("入力中の下書きを保持します") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { requestSave(next: false) }.keyboardShortcut("s", modifiers: .command).accessibilityIdentifier("saveNote")
                        .disabled(!canSave)
                }
            }
            .confirmationDialog("同じデッキに重複候補があります", isPresented: $duplicateChoice, titleVisibility: .visible) {
                Button("スキップして閉じる") {
                    do { try store.repository.discardEditorDraft(key: draftKey); committed = true; dismiss() }
                    catch { failure = error.localizedDescription }
                }
                Button("別ノートとして追加") { save(reset: false) }
                Button("既存ノートを更新（履歴維持）") { save(reset: false, updateID: duplicateID) }
            }
            .confirmationDialog("学習済みの内容を変更します", isPresented: $historyChoice, titleVisibility: .visible) {
                Button("復習予定を維持して保存") { save(reset: false) }
                Button("未学習に戻して保存", role: .destructive) { save(reset: true) }
            } message: { Text("学習の意味が変わる場合は未学習に戻せます。過去の履歴は残ります。") }
            .alert("操作を完了できませんでした", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil; saveFailure = false } })) {
                if saveFailure { Button("再試行") { save(reset: pendingReset, updateID: pendingUpdateID) } }
                Button("閉じる", role: .cancel) { failure = nil; saveFailure = false }
            } message: { Text(failure ?? "") }
        }
    }

    @ViewBuilder private func audioRow(_ side: SpeechSide) -> some View {
        let question = side == .question
        let id = question ? input.questionAudioID : input.answerAudioID
        VStack(alignment: .leading) {
            Button(question ? "問題音声を選択" : "解答音声を選択") {
                audioPreview.stop(); audioSide = side; audioSelecting = true
            }.disabled(audioWorking).accessibilityIdentifier(question ? "selectQuestionAudio" : "selectAnswerAudio")
            if let id {
                Text(question ? "問題音声を添付済み" : "解答音声を添付済み")
                HStack {
                    Button("試聴") {
                        if let url = try? store.repository.assetURL(id: id) { audioPreview.playAttached(url: url) }
                        else { audioPreview.missingAttachment() }
                    }.accessibilityIdentifier(question ? "previewQuestionAudio" : "previewAnswerAudio")
                    Button("停止") { audioPreview.stop() }
                    Button("外す", role: .destructive) {
                        audioPreview.stop()
                        if question { input.questionAudioID = nil } else { input.answerAudioID = nil }
                    }.accessibilityIdentifier(question ? "removeQuestionAudio" : "removeAnswerAudio")
                }.buttonStyle(.borderless)
            }
        }
    }

    private var speechVariants: [String]? {
        let content = TextContent(question: input.question, answer: input.answer,
                                  explanation: input.explanation, reverseEnabled: input.reverseEnabled,
                                  imageID: input.imageID, masks: input.masks, hideAllMasks: input.hideAllMasks)
        return try? CardGeneration.variants(kind: input.kind, content: content)
    }
    private var canSave: Bool {
        !audioWorking && !input.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        ([.cloze, .imageOcclusion].contains(input.kind) || !input.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private func requestSave(next: Bool) {
        saveNext = next
        if let item, (item.sourceContent.question != input.question || item.sourceContent.answer != input.answer || item.kind != input.kind || item.sourceContent.imageID != input.imageID || (item.sourceContent.masks ?? []) != input.masks || (item.sourceContent.reverseEnabled ?? false) != input.reverseEnabled),
           store.notes.contains(where: { $0.noteID == item.noteID && $0.summary.repetitions > 0 }) { historyChoice = true }
        else if item == nil {
            do {
                if let existing = try store.repository.duplicate(of: input) { duplicateID = existing.id; duplicateChoice = true }
                else { save(reset: false) }
            } catch { failure = error.localizedDescription }
        } else { save(reset: false) }
    }
    private var draftKey: String { item.map { "edit:\($0.noteID.uuidString)" } ?? "new" }
    private var image: UIImage? {
        guard let id = input.imageID, let url = try? store.repository.assetURL(id: id) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    private func persistDraft() {
        do { try store.repository.saveEditorDraft(key: draftKey, input: input, now: store.clock()) }
        catch { failure = error.localizedDescription }
    }
    private func recognize() {
        guard let id = input.imageID else { return }
        Task {
            ocrWorking = true
            defer { ocrWorking = false }
            do {
                let data = try Data(contentsOf: store.repository.assetURL(id: id))
                let result = try await OCRService.recognize(data)
                input.question += (input.question.isEmpty ? "" : "\n") + result.text
            } catch { failure = error.localizedDescription }
        }
    }
    private func applyCrop(_ rect: MaskRect) {
        guard let id = input.imageID else { return }
        do {
            let data = try Data(contentsOf: store.repository.assetURL(id: id))
            input.imageID = try store.repository.addImage(data, crop: rect, now: store.clock())
            input.masks = input.masks.compactMap { mask in
                let intersect = CGRect(x: mask.rect.x, y: mask.rect.y, width: mask.rect.width, height: mask.rect.height)
                    .intersection(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
                guard !intersect.isNull, intersect.width > 0, intersect.height > 0 else { return nil }
                var updated = mask
                updated.rect = MaskRect(x: (intersect.minX - rect.x) / rect.width, y: (intersect.minY - rect.y) / rect.height,
                                        width: intersect.width / rect.width, height: intersect.height / rect.height).clamped()
                return updated
            }
        } catch { failure = error.localizedDescription }
    }

    private func save(reset: Bool, updateID: UUID? = nil) {
        saveFailure = false
        pendingReset = reset
        pendingUpdateID = updateID
        input.tagNames = tagText.components(separatedBy: ",")
        do {
            if let id = updateID ?? item?.noteID { try store.repository.updateNote(id: id, input: input, resetHistory: reset, clearingDraft: draftKey, now: store.clock()) }
            else { try store.repository.createNote(input, clearingDraft: draftKey, now: store.clock()) }
            committed = true
            try store.reload()
            if saveNext {
                input = NoteInput(deckID: input.deckID, kind: input.kind, question: "", answer: "", responseMode: input.responseMode)
                tagText = ""; committed = false; saveNext = false
            } else { dismiss() }
            do { try store.repository.cleanupUnusedMedia() }
            catch { store.failure = "カードは保存済みですが、不要な画像の清掃に失敗しました: " + error.localizedDescription }
        } catch { saveFailure = !committed; failure = error.localizedDescription }
    }
}
