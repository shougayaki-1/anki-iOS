import Foundation

struct ClozePart {
    let id: String
    let answer: String
    let hint: String?
    let range: NSRange
}

enum CardGenerationError: LocalizedError {
    case invalidCloze
    var errorDescription: String? { "穴埋めは {{c1::語句}} の形式で入力してください。番号は編集後も維持してください。" }
}

struct CardGeneration {
    static func clozes(_ text: String) throws -> [ClozePart] {
        let regex = try NSRegularExpression(pattern: "\\{\\{c([1-9][0-9]*)::([^{}]+?)\\}\\}")
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var parts: [ClozePart] = []
        let stripped = NSMutableString(string: text)
        for match in matches.reversed() { stripped.replaceCharacters(in: match.range, with: "") }
        guard !matches.isEmpty, !stripped.contains("{{c") else { throw CardGenerationError.invalidCloze }
        for match in matches {
            let id = (text as NSString).substring(with: match.range(at: 1))
            let body = (text as NSString).substring(with: match.range(at: 2)).components(separatedBy: "::")
            guard !body[0].isEmpty else { throw CardGenerationError.invalidCloze }
            parts.append(ClozePart(id: id, answer: body[0], hint: body.count > 1 ? body.dropFirst().joined(separator: "::") : nil, range: match.range))
        }
        return parts
    }

    static func variants(kind: NoteKind, content: TextContent) throws -> [String] {
        switch kind {
        case .basic: return content.reverseEnabled == true ? ["basic:front", "basic:reverse"] : ["basic:front"]
        case .written: return ["basic:front"]
        case .cloze:
            let ids = Set(try clozes(content.question).map(\.id))
            return ids.sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }.map { "cloze:\($0)" }
        case .imageOcclusion:
            guard content.imageID != nil, let masks = content.masks, !masks.isEmpty,
                  masks.allSatisfy({ $0.rect.isValid }), Set(masks.map(\.id)).count == masks.count else { throw MediaError.invalidImage }
            return masks.map { "image:\($0.id.uuidString)" }
        }
    }

    static func displayed(kind: NoteKind, content: TextContent, variant: String) throws -> TextContent {
        var displayed = content
        if variant == "basic:reverse" {
            displayed.question = content.answer; displayed.answer = content.question
            displayed.speechQuestion = content.speechAnswer; displayed.speechAnswer = content.speechQuestion
            displayed.hint = nil
            displayed.questionLayout = content.answerLayout; displayed.answerLayout = content.questionLayout
        } else if kind == .cloze {
            let id = String(variant.dropFirst("cloze:".count))
            let parts = try clozes(content.question)
            guard parts.contains(where: { $0.id == id }) else { throw CardGenerationError.invalidCloze }
            let rendered = NSMutableString(string: content.question)
            for part in parts.reversed() {
                rendered.replaceCharacters(in: part.range, with: part.id == id ? "[\(part.hint ?? "…")]" : part.answer)
            }
            let replaced = rendered as String
            let hidden = parts.filter { $0.id == id }.map { "[\($0.hint ?? "…")]" }
            let ruby = RubyDocument.parse(replaced)
            displayed.question = ruby.warning == nil ? ruby.tokens.map { token in
                switch token {
                case .text(let value): return value
                case .ruby(let base, let reading):
                    return hidden.contains(where: { base.contains($0) }) ? base : "｜\(base)《\(reading)》"
                }
            }.joined() : replaced
            displayed.answer = parts.filter { $0.id == id }.map(\.answer).joined(separator: " / ")
        }
        if kind == .imageOcclusion {
            guard let id = UUID(uuidString: String(variant.dropFirst("image:".count))),
                  let mask = content.masks?.first(where: { $0.id == id }) else { throw MediaError.invalidImage }
            displayed.answer = mask.answer.isEmpty ? content.answer : mask.answer
        }
        return displayed
    }
}

enum TextLayout: String, Codable, CaseIterable {
    case horizontal, vertical
    var title: String { self == .vertical ? "縦書き" : "横書き" }
    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .horizontal
    }
}

struct RubyDocument {
    enum Token: Equatable { case text(String), ruby(String, String) }
    let source: String
    let tokens: [Token]
    let warning: String?
    var hasRuby: Bool { tokens.contains { if case .ruby = $0 { return true }; return false } }
    var plain: String { tokens.map { switch $0 { case .text(let value): return value; case .ruby(let base, _): return base } }.joined() }
    var spoken: String {
        tokens.map { switch $0 { case .text(let value): return value; case .ruby(let base, let reading): return "\(base)（\(reading)）" } }.joined()
    }
    static func parse(_ source: String) -> Self {
        func fallback() -> Self { Self(source: source, tokens: [.text(source)], warning: "ルビは ｜漢字《かんじ》 の形式で入力してください。原文を表示しています。") }
        guard source.utf8.count <= 200_000 else { return fallback() }
        var tokens: [Token] = [], text = "", index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "｜" || character == "|" {
                let baseStart = source.index(after: index)
                guard let open = source[baseStart...].firstIndex(of: "《"),
                      !source[baseStart..<open].contains(where: { "｜|》\n".contains($0) }),
                      let close = source[source.index(after: open)...].firstIndex(of: "》") else { return fallback() }
                let base = String(source[baseStart..<open]), reading = String(source[source.index(after: open)..<close])
                guard !base.isEmpty, !reading.isEmpty,
                      !reading.contains(where: { "《｜|\n".contains($0) }) else { return fallback() }
                if !text.isEmpty { tokens.append(.text(text)); text = "" }
                tokens.append(.ruby(base, reading)); index = source.index(after: close)
            } else {
                if character == "《" || character == "》" { return fallback() }
                text.append(character); index = source.index(after: index)
            }
        }
        if !text.isEmpty { tokens.append(.text(text)) }
        return Self(source: source, tokens: tokens, warning: nil)
    }
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
    func html(layout: TextLayout, fontSize: Double) -> String {
        func text(_ value: String) -> String {
            let escaped = Self.escape(value)
            guard layout == .vertical else { return escaped }
            return escaped.replacingOccurrences(of: "(?<![0-9])[0-9]{2}(?![0-9])", with: "<span class=\"tcy\">$0</span>", options: .regularExpression)
        }
        let body = tokens.map { token in
            switch token {
            case .text(let value): return text(value)
            case .ruby(let base, let reading): return "<ruby>\(text(base))<rt>\(Self.escape(reading))</rt></ruby>"
            }
        }.joined()
        let size = min(72, max(14, fontSize.isFinite ? fontSize : 20))
        return """
        <!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'none'; connect-src 'none'">
        <style>:root{color-scheme:light dark}body{margin:12px;font: \(size)px -apple-system,serif;color:CanvasText;background:Canvas;line-height:2;white-space:pre-wrap;overflow-wrap:anywhere;\(layout == .vertical ? "writing-mode:vertical-rl;height:300px;" : "writing-mode:horizontal-tb;")}ruby{ruby-position:over}rt{font-size:0.5em}.tcy{text-combine-upright:all}</style></head><body>\(body)</body></html>
        """
    }
}
