import SwiftUI

struct MaskEditorView: View {
    let image: UIImage
    @Binding var masks: [ImageMask]
    @State private var selectedID: UUID?
    @State private var drawing: MaskRect?
    @State private var moving = false
    @State private var original: MaskRect?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("選択マスクを移動", isOn: $moving)
            Text(moving ? "マスクを選択し、画像上でドラッグすると移動できます。位置・大きさは下の数値でも編集できます。" : "画像上をドラッグして隠す範囲を追加してください。")
                .font(.footnote).foregroundStyle(.secondary)
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                .overlay {
                    GeometryReader { geometry in
                        ForEach(masks) { mask in
                            let rect = mask.rect.frame(in: geometry.size)
                            Rectangle().fill(Color.black.opacity(0.6))
                                .overlay { Rectangle().stroke(mask.id == selectedID ? Color.blue : Color.white, lineWidth: 3) }
                                .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                        }
                        if let drawing {
                            let rect = drawing.frame(in: geometry.size)
                            Rectangle().stroke(Color.blue, lineWidth: 2)
                                .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                        }
                        Color.clear.contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                                if moving, let index = masks.firstIndex(where: { $0.id == selectedID }) {
                                    if original == nil { original = masks[index].rect }
                                    if let original {
                                        var rect = original
                                        rect.x = min(1 - rect.width, max(0, original.x + value.translation.width / geometry.size.width))
                                        rect.y = min(1 - rect.height, max(0, original.y + value.translation.height / geometry.size.height))
                                        masks[index].rect = rect
                                    }
                                } else {
                                    let x = min(value.startLocation.x, value.location.x) / geometry.size.width
                                    let y = min(value.startLocation.y, value.location.y) / geometry.size.height
                                    drawing = MaskRect(x: x, y: y, width: abs(value.translation.width) / geometry.size.width,
                                                       height: abs(value.translation.height) / geometry.size.height).clamped()
                                }
                            }.onEnded { _ in
                                if !moving, let rect = drawing {
                                    let mask = ImageMask(rect: rect); masks.append(mask); selectedID = mask.id
                                }
                                drawing = nil; original = nil
                            })
                    }
                }.accessibilityElement(children: .ignore).accessibilityLabel("画像マスクの編集領域")
                .accessibilityHint("中央への追加と下の位置・大きさの操作でも編集できます").accessibilityIdentifier("maskCanvas")
            Button("中央にマスクを追加") {
                let mask = ImageMask(rect: MaskRect(x: 0.25, y: 0.25, width: 0.5, height: 0.25))
                masks.append(mask); selectedID = mask.id
            }.accessibilityIdentifier("addCenterMask")
            ForEach($masks) { $mask in
                DisclosureGroup {
                    TextField("このマスクの解答（任意）", text: $mask.answer)
                    coordinate("左位置", value: $mask.rect.x, upper: 1 - mask.rect.width)
                    coordinate("上位置", value: $mask.rect.y, upper: 1 - mask.rect.height)
                    coordinate("幅", value: $mask.rect.width, upper: 1 - mask.rect.x, lower: 0.01)
                    coordinate("高さ", value: $mask.rect.height, upper: 1 - mask.rect.y, lower: 0.01)
                    Button("このマスクを削除", role: .destructive) { masks.removeAll { $0.id == mask.id } }
                } label: {
                    Button("マスク\((masks.firstIndex(where: { $0.id == mask.id }) ?? 0) + 1)を選択") { selectedID = mask.id }
                }
            }
        }
        .buttonStyle(.borderless)
    }
    private func coordinate(_ title: String, value: Binding<Double>, upper: Double, lower: Double = 0) -> some View {
        HStack {
            Text(title)
            if upper - lower > 0.000001 {
                Slider(value: value, in: lower...upper, step: min(0.01, upper - lower))
                    .accessibilityLabel(title)
                    .accessibilityValue("\(Int((value.wrappedValue * 100).rounded()))パーセント")
            } else { Text("固定").foregroundStyle(.secondary) }
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
        }
    }
}
