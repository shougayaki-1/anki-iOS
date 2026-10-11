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
        } else if kind == .cloze {
            let id = String(variant.dropFirst("cloze:".count))
            let parts = try clozes(content.question)
            guard parts.contains(where: { $0.id == id }) else { throw CardGenerationError.invalidCloze }
            let rendered = NSMutableString(string: content.question)
            for part in parts.reversed() {
                rendered.replaceCharacters(in: part.range, with: part.id == id ? "[\(part.hint ?? "…")]" : part.answer)
            }
            displayed.question = rendered as String
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
