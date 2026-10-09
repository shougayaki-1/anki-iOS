import SwiftUI

struct StudyImageView: View {
    let image: UIImage
    var masks: [ImageMask] = []
    var targetID: UUID?
    var hideAll = true
    var revealed = false

    var body: some View {
        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    ForEach(masks) { mask in
                        let target = mask.id == targetID
                        let hidden = (hideAll || target) && !(target && revealed)
                        let rect = mask.rect.frame(in: geometry.size)
                        Rectangle().fill(hidden ? Color.black : Color.clear)
                            .overlay { Rectangle().stroke(target ? Color.blue : Color.gray, lineWidth: target ? 3 : 1) }
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
            .accessibilityLabel(targetID == nil ? "問題の画像" : revealed ? "対象のマスクを開いた画像" : "対象のマスクを隠した画像")
    }
}
