import SwiftUI

struct NotePreviewView: View {
    let input: NoteInput
    let image: UIImage?
    @Environment(\.dismiss) private var dismiss
    @State private var selected = ""
    @State private var revealed = false

    private var content: TextContent {
        TextContent(question: input.question, answer: input.answer, explanation: input.explanation,
                    reverseEnabled: input.reverseEnabled, imageID: input.imageID,
                    masks: input.masks, hideAllMasks: input.hideAllMasks)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let variants = try? CardGeneration.variants(kind: input.kind, content: content), !variants.isEmpty {
                        Picker("生成カード", selection: $selected) {
                            ForEach(variants, id: \.self) { Text("カード\((variants.firstIndex(of: $0) ?? 0) + 1)").tag($0) }
                        }
                        if let shown = try? CardGeneration.displayed(kind: input.kind, content: content, variant: selected) {
                            Text(shown.question).font(.title2).accessibilityIdentifier("previewQuestion")
                            if let image {
                                StudyImageView(image: image, masks: input.kind == .imageOcclusion ? input.masks : [],
                                               targetID: UUID(uuidString: String(selected.dropFirst("image:".count))),
                                               hideAll: input.hideAllMasks, revealed: revealed)
                            }
                            if revealed {
                                Text(shown.answer).accessibilityIdentifier("previewAnswer")
                                if !shown.explanation.isEmpty { Text(shown.explanation).foregroundStyle(.secondary) }
                            }
                            Button(revealed ? "問題に戻る" : "答えを表示") { revealed.toggle() }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("previewReveal")
                        }
                        Text("プレビューでは学習履歴を変更しません。").font(.footnote).foregroundStyle(.secondary)
                            .onAppear { selected = variants.first ?? "" }
                    } else {
                        Text("入力内容を確認してください。穴埋め構文や画像・マスクが揃うと出題を確認できます。")
                    }
                }.padding()
            }
            .onChange(of: selected) { _, _ in revealed = false }
            .navigationTitle("出題プレビュー")
            .toolbar { Button("閉じる") { dismiss() } }
        }
    }
}
