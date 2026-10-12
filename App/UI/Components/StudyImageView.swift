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

import WebKit

// Only the card body uses WebKit; controls and navigation remain native.
struct StudyTextView: View {
    let text: String
    var layout: TextLayout? = nil
    var font: Font = .body
    var fontSize: Double = 20
    var body: some View {
        let document = RubyDocument.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            if (layout ?? .horizontal) == .vertical || document.hasRuby {
                LocalStudyWebText(document: document, layout: layout ?? .horizontal, fontSize: fontSize)
                    .frame(height: 340)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(document.spoken)
                    .accessibilityHint((layout ?? .horizontal) == .vertical ? "縦書き。長い文章は横にスクロールできます" : "ルビ付き本文。長い文章はスクロールできます")
            } else { Text(text).font(font).textSelection(.enabled) }
            if let warning = document.warning { Text(warning).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

private struct LocalStudyWebText: UIViewRepresentable {
    let document: RubyDocument
    let layout: TextLayout
    let fontSize: Double
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false; view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let html = document.html(layout: layout, fontSize: fontSize)
        guard html != context.coordinator.html else { return }
        context.coordinator.html = html; context.coordinator.vertical = layout == .vertical
        view.loadHTMLString(html, baseURL: nil)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var html = ""
        var vertical = false
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if vertical {
                webView.scrollView.setContentOffset(CGPoint(x: max(0, webView.scrollView.contentSize.width - webView.bounds.width), y: 0), animated: false)
            }
        }
    }
}

import ImageIO
import CryptoKit

// ImageIO work is serialized away from the main actor; only immutable CGImages
// cross the boundary. Original media bytes and editor/OCR paths are untouched.
actor DisplayImageLoader {
    static let shared = DisplayImageLoader()
    private struct Key: Hashable {
        let source: String
        let pixels: Int
    }
    private struct Entry { let image: CGImage; let cost: Int }
    private var images: [Key: Entry] = [:]
    private var order: [Key] = []
    private(set) var cachedBytes = 0
    private let maximumBytes: Int
    #if DEBUG
    private(set) var decodeCount = 0
    #endif
    init(maximumBytes: Int = 24 * 1024 * 1024) { self.maximumBytes = maximumBytes }
    func clearCache() { images = [:]; order = []; cachedBytes = 0 }

    func load(file: URL, namespace: UUID, pixels: Int) throws -> CGImage {
        try Task.checkCancellation()
        var currentFile = file
        currentFile.removeAllCachedResourceValues()
        let values = try currentFile.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw MediaError.invalidImage }
        let sourceID = "\(namespace)|\(file.absoluteString)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)"
        let key = Key(source: sourceID, pixels: try pixelBucket(pixels))
        if let cached = cached(key) { return cached }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw MediaError.invalidImage }
        return try decode(source, key: key)
    }
    func load(data: Data, pixels: Int) throws -> CGImage {
        try Task.checkCancellation()
        let key = Key(source: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), pixels: try pixelBucket(pixels))
        if let cached = cached(key) { return cached }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw MediaError.invalidImage }
        return try decode(source, key: key)
    }
    private func pixelBucket(_ pixels: Int) throws -> Int {
        guard pixels > 0 else { throw MediaError.invalidImage }
        return min(3072, ((min(pixels, 3072) + 255) / 256) * 256)
    }
    private func cached(_ key: Key) -> CGImage? {
        guard let entry = images[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key)
        return entry.image
    }
    private func decode(_ source: CGImageSource, key: Key) throws -> CGImage {
        guard CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= ImageEncodingPolicy.maximumPixels / height else { throw MediaError.invalidImage }
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: key.pixels
        ] as CFDictionary) else { throw MediaError.invalidImage }
        try Task.checkCancellation()
        #if DEBUG
        decodeCount += 1
        #endif
        let cost = image.bytesPerRow * image.height
        if cost <= maximumBytes {
            while cachedBytes + cost > maximumBytes || order.count >= 64 {
                guard let oldest = order.first else { break }
                order.removeFirst()
                cachedBytes -= images.removeValue(forKey: oldest)?.cost ?? 0
            }
            images[key] = Entry(image: image, cost: cost); order.append(key); cachedBytes += cost
        }
        return image
    }
}

struct AsyncStudyImageView: View {
    var file: URL? = nil
    var data: Data? = nil
    var namespace: UUID
    var revision = 0
    var identity: String
    var maximumHeight: CGFloat = 560
    var masks: [ImageMask] = []
    var targetID: UUID?
    var hideAll = true
    var revealed = false
    @Environment(\.displayScale) private var displayScale
    @State private var width: CGFloat = 400
    @State private var image: UIImage?
    @State private var failure = false
    @State private var loadedKey: String?
    private var pixels: Int { Int(ceil(max(width, maximumHeight) * displayScale / 256)) * 256 }
    private var key: String { "\(namespace)|\(identity)|\(revision)|\(pixels)" }
    var body: some View {
        Group {
            if let image, loadedKey == key {
                StudyImageView(image: image, masks: masks, targetID: targetID, hideAll: hideAll, revealed: revealed)
                    .frame(maxHeight: maximumHeight)
            } else if failure {
                Label("画像を読み込めません。ライブラリで画像を確認してください。", systemImage: "exclamationmark.triangle")
            } else { ProgressView().frame(height: min(180, maximumHeight)) }
        }
        .frame(maxWidth: .infinity)
        .background { GeometryReader { geometry in
            Color.clear.onAppear { width = geometry.size.width }
                .onChange(of: geometry.size.width) { _, value in width = value }
        } }
        .task(id: key) {
            let request = key
            image = nil; failure = false; loadedKey = nil
            do {
                let result: CGImage
                if let file { result = try await DisplayImageLoader.shared.load(file: file, namespace: namespace, pixels: pixels) }
                else if let data { result = try await DisplayImageLoader.shared.load(data: data, pixels: pixels) }
                else { throw MediaError.invalidImage }
                guard !Task.isCancelled, request == key else { return }
                image = UIImage(cgImage: result); loadedKey = request
            } catch is CancellationError { } catch {
                guard !Task.isCancelled, request == key else { return }
                failure = true
            }
        }
        .onDisappear { image = nil; loadedKey = nil }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await DisplayImageLoader.shared.clearCache() }
        }
    }
}
