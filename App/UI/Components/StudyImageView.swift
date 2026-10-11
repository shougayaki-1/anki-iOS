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
