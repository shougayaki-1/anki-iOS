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
    let width: Int
    let height: Int
    let sha256: String
}

enum MediaError: LocalizedError {
    case invalidImage, invalidPath, tooLarge, noCamera, cameraDenied
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "画像を読み込めません。"
        case .invalidPath: return "画像ファイルのパスが不正です。"
        case .tooLarge: return "画像が大きすぎます（20MB・4000万画素まで）。"
        case .noCamera: return "この環境ではカメラを利用できません。写真ライブラリから選択してください。"
        case .cameraDenied: return "カメラへのアクセスを許可してください。設定アプリから変更できます。"
        }
    }
}
