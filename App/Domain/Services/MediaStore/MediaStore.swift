import Foundation
import UIKit
import ImageIO
import CryptoKit

// Kept independent of SwiftData and UI so ZIP import (#22) can reuse this policy.
enum ImageEncodingPolicy {
    static let maximumBytes = 20_000_000
    static let maximumPixels = 40_000_000
    static let jpegQuality: CGFloat = 0.92

    struct Result {
        let data: Data
        let mediaType: String
        let width: Int
        let height: Int
        var fileExtension: String { mediaType == "image/png" ? "png" : "jpg" }
    }

    static func prepare(_ data: Data, crop: MaskRect? = nil) throws -> Result {
        guard data.count <= maximumBytes else { throw MediaError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw MediaError.invalidImage }
        guard width <= maximumPixels / height else { throw MediaError.tooLarge }
        // Inspect the whole image, not merely its header; truncated files cannot be stored.
        guard let decoded = CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) else { throw MediaError.invalidImage }

        let sourceType = CGImageSourceGetType(source) as String?
        let png = sourceType == "public.png"
        let jpeg = sourceType == "public.jpeg"
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        if let crop, !crop.isValid { throw MediaError.invalidImage }

        // Original, complete PNG/JPEG bytes are preferable to an invisible lossy conversion.
        // Leave their metadata/EXIF untouched; existing masks use relative display coordinates.
        if crop == nil && orientation == 1 && (png || jpeg) {
            return Result(data: data, mediaType: png ? "image/png" : "image/jpeg",
                          width: width, height: height)
        }

        let alpha: Bool
        switch decoded.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: alpha = true
        default: alpha = false
        }
        let usePNG = png || alpha
        guard let original = UIImage(data: data) else { throw MediaError.invalidImage }
        // UIGraphicsImageRenderer draws UIImage with its EXIF orientation applied.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !usePNG
        // EXIF orientations 5...8 rotate pixel axes; avoid stretching rotated photographs.
        let rotated = (5...8).contains(orientation)
        let displaySize = CGSize(width: rotated ? height : width, height: rotated ? width : height)
        let upright = UIGraphicsImageRenderer(size: displaySize, format: format).image { _ in
            original.draw(in: CGRect(origin: .zero, size: displaySize))
        }
        var result = upright
        if let crop {
            guard let bitmap = upright.cgImage else { throw MediaError.invalidImage }
            let bounds = CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height)
            let rect = crop.frame(in: bounds.size).integral.intersection(bounds)
            guard rect.width > 0, rect.height > 0,
                  let cut = bitmap.cropping(to: rect) else { throw MediaError.invalidImage }
            result = UIImage(cgImage: cut)
        }
        guard let output = usePNG ? result.pngData() : result.jpegData(compressionQuality: jpegQuality) else {
            throw MediaError.invalidImage
        }
        // Never silently lower resolution or JPEG quality to satisfy the cap.
        guard output.count <= maximumBytes else { throw MediaError.tooLarge }
        return Result(data: output, mediaType: usePNG ? "image/png" : "image/jpeg",
                      width: result.cgImage?.width ?? Int(result.size.width),
                      height: result.cgImage?.height ?? Int(result.size.height))
    }
}

struct MediaStore {
    var root: URL = URL.applicationSupportDirectory.appendingPathComponent("Study/Media")

    func url(for relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.contains("\\"),
              !relativePath.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { throw MediaError.invalidPath }
        let resolvedRoot = root.resolvingSymlinksInPath()
        let file = resolvedRoot.appendingPathComponent(relativePath)
        guard file.isFileDescendant(of: resolvedRoot) else {
            throw MediaError.invalidPath
        }
        return file
    }

    static func normalizedImage(_ data: Data) throws -> UIImage {
        let prepared = try ImageEncodingPolicy.prepare(data)
        guard let image = UIImage(data: prepared.data) else { throw MediaError.invalidImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = prepared.mediaType != "image/png"
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    func store(_ data: Data, crop: MaskRect? = nil) throws -> StoredImage {
        let prepared = try ImageEncodingPolicy.prepare(data, crop: crop)
        let id = UUID()
        let path = "images/\(UUID().uuidString).\(prepared.fileExtension)"
        let file = try url(for: path)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try prepared.data.write(to: file, options: .atomic)
        } catch {
            // The SwiftData record is not inserted unless the complete atomic write succeeds.
            throw MediaError.saveFailed
        }
        return StoredImage(id: id, relativePath: path, mediaType: prepared.mediaType,
                           width: prepared.width, height: prepared.height,
                           sha256: SHA256.hash(data: prepared.data).map { String(format: "%02x", $0) }.joined())
    }

    func remove(_ path: String) throws {
        let file = try url(for: path)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
