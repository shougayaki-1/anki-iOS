import SwiftUI

struct NotePreviewView: View {
    let input: NoteInput
    let image: UIImage?
    @Environment(\.dismiss) private var dismiss
    @State private var selected = ""
    @State private var revealed = false
    @State private var ordering: OrderingDraft? = nil
    @State private var previewCardID = UUID()

    private var content: TextContent {
        TextContent(question: input.question, answer: input.answer, explanation: input.explanation, hint: input.hint,
                    reverseEnabled: input.reverseEnabled, imageID: input.imageID,
                    masks: input.masks, hideAllMasks: input.hideAllMasks, questionLayout: input.questionLayout, answerLayout: input.answerLayout)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let variants = try? CardGeneration.variants(kind: input.kind, content: content), !variants.isEmpty {
                        Text("このノートから\(variants.count)枚の学習カードを作成").accessibilityIdentifier("previewCardCount")
                        Picker("生成カード", selection: $selected) {
                            ForEach(variants, id: \.self) { Text("カード\((variants.firstIndex(of: $0) ?? 0) + 1)").tag($0) }
                        }
                        if let shown = try? CardGeneration.displayed(kind: input.kind, content: content, variant: selected) {
                            StudyTextView(text: shown.question, layout: shown.questionLayout, font: .title2, fontSize: 24).accessibilityIdentifier("previewQuestion")
                            if let image {
                                StudyImageView(image: image, masks: input.kind == .imageOcclusion ? input.masks : [],
                                               targetID: UUID(uuidString: String(selected.dropFirst("image:".count))),
                                               hideAll: input.hideAllMasks, revealed: revealed)
                            }
                            if !revealed {
                                StudyHintView(hint: shown.hint).id(selected)
                            }
                            if input.responseMode == .ordering && !revealed {
                                if let draft = ordering, let problem = try? OrderingAnswer(kind: input.kind, answer: shown.answer) {
                                    OrderingAnswerView(problem: problem, draft: draft) { action in
                                        do {
                                            var updated = draft; try updated.apply(action, problem: problem)
                                            ordering = updated
                                            if updated.result == .correct { revealed = true }
                                        } catch { }
                                    }
                                } else if let reason = OrderingAnswer.reason(kind: input.kind, answer: shown.answer) {
                                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            if revealed {
                                if input.responseMode == .ordering, ordering?.result == .correct { Label("正解", systemImage: "checkmark.circle") }
                                StudyTextView(text: shown.answer, layout: shown.answerLayout).accessibilityIdentifier("previewAnswer")
                                if !shown.explanation.isEmpty { Text(shown.explanation).foregroundStyle(.secondary) }
                            }
                            Button(revealed ? "問題に戻る" : "答えを表示") {
                                revealed.toggle()
                                if !revealed { resetOrdering() }
                            }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("previewReveal")
                                .tint(Color("PrimaryAction")).foregroundStyle(Color.white)
                        }
                        Text("プレビューでは学習履歴を変更しません。").font(.footnote).foregroundStyle(.secondary)
                            .onAppear { selected = variants.first ?? "" }
                    } else {
                        Text("入力内容を確認してください。穴埋め構文や画像・マスクが揃うと出題を確認できます。")
                    }
                }.padding()
            }
            .onChange(of: selected) { _, _ in revealed = false; resetOrdering() }
            .navigationTitle("出題プレビュー")
            .toolbar { Button("閉じる") { dismiss() }.accessibilityIdentifier("closePreview") }
        }
    }
    private func resetOrdering() {
        guard input.responseMode == .ordering,
              let shown = try? CardGeneration.displayed(kind: input.kind, content: content, variant: selected),
              let problem = try? OrderingAnswer(kind: input.kind, answer: shown.answer) else { ordering = nil; return }
        ordering = OrderingDraft(cardID: previewCardID, problem: problem)
    }
}

// Expansion is presentation-only: it never changes the answer draft or scheduler.
struct StudyHintView: View {
    let hint: String?
    @State private var expanded = false

    var body: some View {
        if let hint, !hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button { expanded.toggle() } label: {
                    Label(expanded ? "ヒントを隠す" : "ヒントを見る", systemImage: "lightbulb")
                        .font(.subheadline).frame(minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(expanded ? "ヒントを隠す" : "ヒントを見る")
                .accessibilityValue(expanded ? "展開中" : "折り畳み中")
                .accessibilityIdentifier("toggleHint")
                if expanded {
                    Text(hint).font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("studyHint")
                }
            }
            .onAppear { expanded = false }
            .onDisappear { expanded = false }
        }
    }
}
