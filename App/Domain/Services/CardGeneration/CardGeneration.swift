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
            displayed.questionAudioID = content.answerAudioID; displayed.answerAudioID = content.questionAudioID
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
            let replaced = (rendered as String).replacingOccurrences(of: #"(\[[^\]]*\])(?:［＃[^］]*］)+"#, with: "$1", options: .regularExpression)
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
    var hasRuby: Bool { (source.contains("［＃") && warning == nil) || tokens.contains { if case .ruby = $0 { return true }; return false } }
    var plain: String {
        if source.contains("［＃"), warning == nil { return KanbunDocument.parse(source).plain }
        return tokens.map { switch $0 { case .text(let value): return value; case .ruby(let base, _): return base } }.joined() }
    var spoken: String {
        if source.contains("［＃"), warning == nil { return KanbunDocument.parse(source).spoken }
        return tokens.map { switch $0 { case .text(let value): return value; case .ruby(let base, let reading): return "\(base)（\(reading)）" } }.joined()
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
        if source.contains("［＃"), let warning = KanbunDocument.parse(source).warning {
            return Self(source: source, tokens: [.text(source)], warning: warning)
        }
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
        let rubyBody = tokens.map { token in
            switch token {
            case .text(let value): return text(value)
            case .ruby(let base, let reading): return "<ruby>\(text(base))<rt>\(Self.escape(reading))</rt></ruby>"
            }
        }.joined()
        let body = source.contains("［＃") && warning == nil ? KanbunDocument.parse(source).html() : rubyBody
        let size = min(72, max(14, fontSize.isFinite ? fontSize : 20))
        return """
        <!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'none'; connect-src 'none'">
        <style>:root{color-scheme:light dark}body{margin:12px;font: \(size)px -apple-system,serif;color:CanvasText;background:Canvas;line-height:2;white-space:pre-wrap;overflow-wrap:anywhere;\(layout == .vertical ? "writing-mode:vertical-rl;height:300px;" : "writing-mode:horizontal-tb;")}ruby{ruby-position:over}rt{font-size:0.5em}.tcy{text-combine-upright:all}.kg{display:inline-block;position:relative;writing-mode:vertical-rl;line-height:1;margin:0 .6em;vertical-align:top;break-inside:avoid}.kg-right,.kg-left{position:absolute;font-size:.45em;line-height:1;white-space:nowrap;writing-mode:vertical-rl}.kg-right{right:-1.1em}.kg-left{left:-1.1em}</style></head><body>\(body)</body></html>
        """
    }
}

struct KanbunDocument {
    struct Glyph: Equatable {
        var base: String
        var rightRuby: String? = nil
        var leftRuby: String? = nil
        var okuri: String? = nil
        var returnMark: String? = nil
    }
    enum Unit: Equatable { case text(String), ruby(String, String), glyph(Glyph) }
    static let returnMarks = ["レ", "一", "二", "三", "四", "上", "中", "下", "甲", "乙", "丙", "丁", "天", "地", "人", "一レ", "二レ", "上レ", "下レ", "甲レ", "乙レ", "天レ", "地レ", "人レ"]
    let source: String
    let units: [Unit]
    let warning: String?
    static func parse(_ source: String) -> Self {
        func fallback(_ reason: String) -> Self {
            Self(source: source, units: [.text(source)], warning: reason + " 原文を表示しています。")
        }
        guard source.utf8.count <= 200_000 else { return fallback("訓点本文は200KB以内にしてください。") }
        var units: [Unit] = [], index = source.startIndex, textBuffer = ""
        func flushText() {
            if !textBuffer.isEmpty { units.append(.text(textBuffer)); textBuffer = "" }
        }
        while index < source.endIndex {
            if source[index...].hasPrefix("［＃") {
                flushText()
                guard let close = source[index...].firstIndex(of: "］"), case .glyph(var glyph)? = units.last else {
                    return fallback("訓点は漢字の直後に ［＃レ］／［＃（ズ）］ の形式で入力してください。")
                }
                let start = source.index(index, offsetBy: 2)
                let annotation = String(source[start..<close])
                if returnMarks.contains(annotation) {
                    guard glyph.returnMark == nil else { return fallback("同じ字の返り点を重複指定できません。") }
                    glyph.returnMark = annotation
                } else if annotation.hasPrefix("（"), annotation.hasSuffix("）") {
                    let value = String(annotation.dropFirst().dropLast())
                    guard !value.isEmpty, value.count <= 32, glyph.okuri == nil,
                          !value.contains(where: { "［］＃《》\n".contains($0) }) else { return fallback("送り仮名は空欄・重複を避け、32文字以内にしてください。") }
                    glyph.okuri = value
                } else {
                    let prefix = "「\(glyph.base)」の左に「"
                    guard annotation.hasPrefix(prefix), annotation.hasSuffix("」のルビ"), glyph.leftRuby == nil else {
                        return fallback("未知の訓点です。返り点・送り仮名・字に対応する左ルビを確認してください。")
                    }
                    let value = String(annotation.dropFirst(prefix.count).dropLast("」のルビ".count))
                    guard !value.isEmpty, value.count <= 32, !value.contains(where: { "［］「」\n".contains($0) }) else { return fallback("左ルビは32文字以内で入力してください。") }
                    glyph.leftRuby = value
                }
                units[units.count - 1] = .glyph(glyph); index = source.index(after: close)
            } else if source[index] == "｜" || source[index] == "|" {
                flushText()
                let start = source.index(after: index)
                guard let open = source[start...].firstIndex(of: "《"), let close = source[source.index(after: open)...].firstIndex(of: "》") else {
                    return fallback("ルビは ｜漢字《かんじ》 と入力してください。")
                }
                let base = String(source[start..<open]), reading = String(source[source.index(after: open)..<close])
                guard !base.isEmpty, !reading.isEmpty, !base.contains(where: { "｜|［\n".contains($0) }), !reading.contains(where: { "《［\n".contains($0) }) else { return fallback("ルビの親文字と読みを確認してください。") }
                if base.count == 1 { units.append(.glyph(Glyph(base: base, rightRuby: reading))) }
                else { units.append(.ruby(base, reading)) }
                index = source.index(after: close)
            } else {
                let value = String(source[index])
                let cjk = value.unicodeScalars.first.map { (0x3400...0x9fff).contains($0.value) || (0x20000...0x3134f).contains($0.value) } ?? false
                if cjk { flushText(); units.append(.glyph(Glyph(base: value))) }
                else { textBuffer.append(contentsOf: value) }
                index = source.index(after: index)
            }
        }
        flushText()
        return Self(source: source, units: units, warning: nil)
    }
    var plain: String {
        units.map { switch $0 { case .text(let value): return value; case .ruby(let base, _): return base; case .glyph(let glyph): return glyph.base } }.joined()
    }
    var spoken: String {
        units.map { unit in
            switch unit {
            case .text(let value): return value
            case .ruby(let base, let reading): return "\(base)（\(reading)）"
            case .glyph(let glyph):
                var value = glyph.base
                if let reading = glyph.rightRuby { value += "、右の読み \(reading)" }
                if let reading = glyph.leftRuby { value += "、再読の左の読み \(reading)" }
                if let okuri = glyph.okuri { value += "、送り仮名 \(okuri)" }
                if let mark = glyph.returnMark { value += "、返り点 \(mark)" }
                return value + " "
            }
        }.joined()
    }
    func html() -> String {
        let escape = RubyDocument.escape
        return units.map { unit in
            switch unit {
            case .text(let value): return escape(value).replacingOccurrences(of: "(?<![0-9])[0-9]{2}(?![0-9])", with: "<span class=\"tcy\">$0</span>", options: .regularExpression)
            case .ruby(let base, let reading): return "<ruby>\(escape(base))<rt>\(escape(reading))</rt></ruby>"
            case .glyph(let glyph):
                guard glyph.okuri != nil || glyph.returnMark != nil || glyph.leftRuby != nil else {
                    if let reading = glyph.rightRuby { return "<ruby>\(escape(glyph.base))<rt>\(escape(reading))</rt></ruby>" }
                    return escape(glyph.base)
                }
                let rightStart = max(0.7, Double(glyph.rightRuby?.count ?? 0) * 0.45 + 0.15)
                let leftStart = max(0.7, Double(glyph.leftRuby?.count ?? 0) * 0.45 + 0.15)
                let height = max(1.25, rightStart + Double(glyph.okuri?.count ?? 0) * 0.45,
                                 leftStart + Double(glyph.returnMark?.count ?? 0) * 0.45)
                var html = "<span class=\"kg\" style=\"height:\(height)em\"><span>\(escape(glyph.base))</span>"
                if let reading = glyph.rightRuby { html += "<span class=\"kg-right\" style=\"top:0\">\(escape(reading))</span>" }
                if let reading = glyph.leftRuby { html += "<span class=\"kg-left\" style=\"top:0\">\(escape(reading))</span>" }
                if let okuri = glyph.okuri { html += "<span class=\"kg-right\" style=\"top:\(rightStart / 0.45)em\">\(escape(okuri))</span>" }
                if let mark = glyph.returnMark { html += "<span class=\"kg-left\" style=\"top:\(leftStart / 0.45)em\">\(escape(mark))</span>" }
                return html + "</span>"
            }
        }.joined()
    }
}
