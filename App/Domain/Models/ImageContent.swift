import Foundation

struct MaskRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1.000001 && y + height <= 1.000001
    }
    func replacingPercentage(_ text: String, at keyPath: WritableKeyPath<MaskRect, Double>) -> MaskRect? {
        let lower: Double = (keyPath == \.width || keyPath == \.height) ? 1 : 0
        guard let value = NumericSettingsInput.percentage(text, lower: lower, upper: 100) else { return nil }
        var candidate = self
        candidate[keyPath: keyPath] = value
        guard candidate.isValid, candidate.width >= 0.01, candidate.height >= 0.01,
              candidate.x + candidate.width <= 1 + 1e-12,
              candidate.y + candidate.height <= 1 + 1e-12 else { return nil }
        return candidate
    }
    func clamped() -> MaskRect {
        let x = min(0.99, max(0, self.x)), y = min(0.99, max(0, self.y))
        return MaskRect(x: x, y: y, width: min(1 - x, max(0.01, width)), height: min(1 - y, max(0.01, height)))
    }
    func frame(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
    }
}

struct ImageMask: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var rect: MaskRect
    var answer: String = ""
}

struct StoredImage: Sendable {
    let id: UUID
    let relativePath: String
    let mediaType: String
    let width: Int
    let height: Int
    let sha256: String
}

enum MediaError: LocalizedError {
    case invalidImage, invalidPath, tooLarge, saveFailed, noCamera, cameraDenied
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "画像を読み込めません。"
        case .invalidPath: return "画像ファイルのパスが不正です。"
        case .tooLarge: return "画像が大きすぎます（1枚20MB・4000万画素まで）。元の画質を保つため自動縮小はしません。画像を縮小してから再選択してください。"
        case .saveFailed: return "画像を保存できませんでした。端末の空き容量と保存先を確認して、再度お試しください。"
        case .noCamera: return "この環境ではカメラを利用できません。写真ライブラリから選択してください。"
        case .cameraDenied: return "カメラへのアクセスを許可してください。設定アプリから変更できます。"
        }
    }
}
