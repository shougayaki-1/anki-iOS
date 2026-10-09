import SwiftUI

struct OCRImportView: View {
    @Bindable var store: StudyStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var languages: [String] = []
    @State private var working = false
    @State private var failure: String?
    @State private var preview = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotoInputControls { data in
                        Task {
                            working = true
                            defer { working = false }
                            do {
                                let result = try await OCRService.recognize(data)
                                text = result.text; languages = result.languages
                            } catch { failure = error.localizedDescription }
                        }
                    }.disabled(working)
                    if working { ProgressView("文字を認識しています") }
                    if !languages.isEmpty { Text("認識言語: \(languages.joined(separator: ", "))").font(.caption).accessibilityIdentifier("ocrLanguages") }
                } footer: { Text("認識は端末内で行います。読み取り結果を確認・修正してから登録してください。空の結果では画像を変更して再試行できます。") }
                Section("認識結果（編集可能）") {
                    TextEditor(text: $text).frame(minHeight: 240).accessibilityIdentifier("ocrText").disabled(working)
                    Button("認識結果を消去") { text = "" }.disabled(text.isEmpty || working).accessibilityIdentifier("clearOCRText")
                }
                Button("カード候補をプレビュー") { preview = true }.disabled(text.isEmpty || working).accessibilityIdentifier("ocrPreview")
            }.scrollDismissesKeyboard(.interactively)
            .navigationTitle("写真から文字を取り込む")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() }.accessibilityIdentifier("closeOCR") }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完了") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } }
            }
            .sheet(isPresented: $preview) { ImportView(store: store, initialText: text, sourceName: "OCR") }
            .alert("文字を認識できませんでした", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("閉じる", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }
    }
}
