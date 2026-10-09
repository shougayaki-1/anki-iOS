import SwiftUI

struct CropView: View {
    let image: UIImage
    let apply: (MaskRect) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection = [ImageMask(rect: MaskRect(x: 0, y: 0, width: 1, height: 1))]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("画像上で切り抜く範囲をドラッグしてください。数値でも範囲を調整できます。")
                    MaskEditorView(image: image, masks: $selection)
                }.padding()
            }
            .navigationTitle("トリミング")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("適用") { if let rect = selection.last?.rect { apply(rect); dismiss() } }.disabled(selection.isEmpty)
                }
            }
            .onChange(of: selection) { _, masks in
                if masks.count > 1, let last = masks.last { selection = [last] }
            }
        }
    }
}
