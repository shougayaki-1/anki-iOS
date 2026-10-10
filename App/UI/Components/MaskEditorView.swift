import SwiftUI

struct MaskEditorView: View {
    let image: UIImage
    @Binding var masks: [ImageMask]
    @State private var selectedID: UUID?
    @State private var drawing: MaskRect?
    @State private var moving = false
    @State private var original: MaskRect?

    var body: some View {
        Group {
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
            }
            ForEach($masks) { $mask in
                DisclosureGroup {
                    TextField("このマスクの解答（任意）", text: $mask.answer)
                    coordinate("左位置", rect: $mask.rect, keyPath: \.x, identifier: "maskX-" + mask.id.uuidString)
                    coordinate("上位置", rect: $mask.rect, keyPath: \.y, identifier: "maskY-" + mask.id.uuidString)
                    coordinate("幅", rect: $mask.rect, keyPath: \.width, identifier: "maskWidth-" + mask.id.uuidString)
                    coordinate("高さ", rect: $mask.rect, keyPath: \.height, identifier: "maskHeight-" + mask.id.uuidString)
                    Button("このマスクを削除", role: .destructive) { masks.removeAll { $0.id == mask.id } }
                } label: {
                    Button("マスク\((masks.firstIndex(where: { $0.id == mask.id }) ?? 0) + 1)を選択") { selectedID = mask.id }
                }
            }
        }
        .buttonStyle(.borderless)
    }
    private func coordinate(_ title: String, rect: Binding<MaskRect>, keyPath: WritableKeyPath<MaskRect, Double>, identifier: String) -> some View {
        let current = rect.wrappedValue
        let lower = (keyPath == \.width || keyPath == \.height) ? 0.01 : 0
        let upper: Double = keyPath == \.x ? 1 - current.width : keyPath == \.y ? 1 - current.height : keyPath == \.width ? 1 - current.x : 1 - current.y
        let value = Binding<Double>(get: { rect.wrappedValue[keyPath: keyPath] }, set: { rect.wrappedValue[keyPath: keyPath] = $0 })
        return VStack(alignment: .leading, spacing: 6) {
            NumericSettingRow(title: title, value: NumericSettingsInput.percentageText(current[keyPath: keyPath]), unit: "%", identifier: identifier, allowsDecimal: true) { text in
                guard NumericSettingsInput.percentage(text, lower: lower * 100, upper: 100) != nil else {
                    return .invalid("\(lower == 0 ? "0" : "1")〜100%の数値を入力してください。")
                }
                guard let candidate = rect.wrappedValue.replacingPercentage(text, at: keyPath) else {
                    return .invalid("位置＋大きさは100%以内、幅・高さは1%以上にしてください。")
                }
                rect.wrappedValue = candidate
                return nil
            }
            if upper - lower > 0.000001 {
                Slider(value: value, in: lower...upper, step: min(0.01, upper - lower))
                    .accessibilityLabel(title)
                    .accessibilityIdentifier(identifier + "Slider")
                    .accessibilityValue("\(current[keyPath: keyPath] * 100)パーセント")
            } else { Text("固定").foregroundStyle(.secondary) }
        }
    }
}
