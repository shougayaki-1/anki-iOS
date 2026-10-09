import Foundation
import UIKit
import ImageIO
import CryptoKit

struct MediaStore {
    var root: URL = URL.applicationSupportDirectory.appendingPathComponent("Study/Media")

    func url(for relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.contains("\\"),
              !relativePath.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { throw MediaError.invalidPath }
        let file = root.appendingPathComponent(relativePath)
        guard file.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
            throw MediaError.invalidPath
        }
        return file
    }

    static func normalizedImage(_ data: Data) throws -> UIImage {
        guard data.count <= 20_000_000 else { throw MediaError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw MediaError.invalidImage }
        guard width <= 40_000_000 / height else { throw MediaError.tooLarge }
        guard let image = UIImage(data: data) else { throw MediaError.invalidImage }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
    }

    func store(_ data: Data, crop: MaskRect? = nil) throws -> StoredImage {
        var image = try Self.normalizedImage(data)
        if let crop {
            guard crop.isValid, let original = image.cgImage,
                  let cropped = original.cropping(to: crop.frame(in: image.size).integral) else { throw MediaError.invalidImage }
            image = UIImage(cgImage: cropped)
        }
        guard let encoded = image.jpegData(compressionQuality: 0.9) else { throw MediaError.invalidImage }
        let id = UUID(), path = "images/\(UUID().uuidString).jpg"
        let file = try url(for: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: file, options: .atomic)
        return StoredImage(id: id, relativePath: path, width: Int(image.size.width), height: Int(image.size.height),
                           sha256: SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined())
    }
    func remove(_ path: String) throws {
        let file = try url(for: path)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
