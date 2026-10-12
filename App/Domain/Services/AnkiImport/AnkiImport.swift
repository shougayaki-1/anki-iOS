import Foundation
import ImageIO

struct AnkiSkippedNote: Identifiable, Sendable {
    let id: String
    let reason: String
}
struct AnkiImportPreview: Sendable {
    let deck: ValidatedDeckPackage
    let sourceNotes: Int
    let sourceCards: Int
    let scheduledCards: Int
    let reviewLogs: Int
    let skipped: [AnkiSkippedNote]
    var warnings: [AnkiSkippedNote] = []
}
private struct AnkiModel: Decodable {
    let type: Int
    let flds: [Field]
    let tmpls: [Template]
    struct Field: Decodable { let name: String; let ord: Int }
    struct Template: Decodable { let qfmt: String; let afmt: String; let ord: Int }
}
private struct AnkiDeck: Decodable { let name: String }
private struct AnkiCard {
    let noteID: String
    let deckID: String
    let ordinal: Int
    let studied: Bool
}
private struct AnkiField {
    let text: String
    let image: String?
    let audio: String?
}

enum AnkiImport {
    static func read(_ url: URL) async throws -> AnkiImportPreview {
        let task = Task.detached(priority: .utility) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= StoredZIP.maximumBytes else { throw BackupError.tooLarge }
            return try decode(Data(contentsOf: url, options: .mappedIfSafe))
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    static func decode(_ bytes: Data) throws -> AnkiImportPreview {
        try Task.checkCancellation()
        let budget = AnkiReadBudget()
        let archive = try AnkiPackage.read(bytes, budget: budget)
        let database = archive.database, mediaByName = archive.media
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AnkiRead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AnkiDatabase(bytes: database, url: directory.appendingPathComponent("collection.sqlite"))
        let (models, sourceDecks) = try metadata(db, budget: budget)
        guard (archive.version == 3 && db.schemaVersion == 18) || (archive.version != 3 && db.schemaVersion == 11) else { throw AnkiImportError.database }
        let rows = try db.rows("SELECT id,mid,flds,tags FROM notes ORDER BY id", maximum: 100_000)
        let cardRows = try db.rows("SELECT nid,did,ord,reps FROM cards ORDER BY id", maximum: 300_000)
        let logs = try db.rows("SELECT count(id) FROM revlog", maximum: 1)
        let cards = try cardRows.map { row -> AnkiCard in
            guard let ordinal = Int(row[2]), ordinal >= 0, let reps = Int(row[3]), reps >= 0 else { throw AnkiImportError.database }
            return AnkiCard(noteID: row[0], deckID: row[1], ordinal: ordinal, studied: reps > 0)
        }
        try BackupValidation.unique(rows.map { $0[0] })
        let noteIDs = Set(rows.map { $0[0] })
        guard cards.allSatisfy({ noteIDs.contains($0.noteID) && sourceDecks[$0.deckID] != nil }) else { throw AnkiImportError.database }
        let byNote = Dictionary(grouping: cards, by: \.noteID)
        let rootID = UUID()
        var decks = [SharedDeck(id: rootID, name: "Anki取込", parentID: nil)], deckPaths: [String: UUID] = ["": rootID]
        var notes: [SharedNote] = [], media: [SharedMedia] = [], mediaBytes: [UUID: Data] = [:], mediaIDs: [String: UUID] = [:], skipped: [AnkiSkippedNote] = [], warnings: [AnkiSkippedNote] = []
        func attach(_ filename: String, audio: Bool) throws -> UUID {
            let cache = (audio ? "audio:" : "image:") + filename
            if let id = mediaIDs[cache] { return id }
            guard let data = mediaByName[filename] else { throw AnkiImportError.unsupported("参照メディアがありません：\(filename)") }
            let id = UUID(), value: Data, type: String, width: Int, height: Int
            if audio {
                let prepared = try AudioEncodingPolicy.prepare(data)
                value = prepared.data; type = prepared.mediaType; width = 0; height = 0
            } else {
                guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                      let imageType = CGImageSourceGetType(image) as String?, ["public.jpeg", "public.png"].contains(imageType) else { throw AnkiImportError.unsupported("画像はJPEG/PNGのみ対応") }
                let prepared = try ImageEncodingPolicy.prepare(data)
                value = prepared.data; type = prepared.mediaType; width = prepared.width; height = prepared.height
            }
            media.append(SharedMedia(id: id, mediaType: type, width: width, height: height, sha256: BackupArchive.hash(value)))
            mediaBytes[id] = value; mediaIDs[cache] = id; return id
        }
        func destination(_ name: String) throws -> UUID {
            let components = name.components(separatedBy: "::")
            guard components.count <= 100, components.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 1000 }) else { throw AnkiImportError.database }
            var path = "", parent = rootID
            for component in components {
                path += "::" + component
                if let id = deckPaths[path] { parent = id }
                else { let id = UUID(); decks.append(SharedDeck(id: id, name: component, parentID: parent)); deckPaths[path] = id; parent = id }
                guard decks.count <= 10_000 else { throw BackupError.tooLarge }
            }
            return parent
        }
        for row in rows {
            try budget.check()
            do {
                guard let model = models[row[1]] else { throw AnkiImportError.unsupported("ノートモデルがありません") }
                let noteCards = byNote[row[0]] ?? []
                guard !noteCards.isEmpty, Set(noteCards.map(\.deckID)).count == 1,
                      Set(noteCards.map(\.ordinal)).count == noteCards.count else { throw AnkiImportError.unsupported("カードなし・複数デッキ・重複ordinalのノートは未対応") }
                let values = row[2].components(separatedBy: "\u{1f}")
                let fields = model.flds.sorted { $0.ord < $1.ord }, templates = model.tmpls.sorted { $0.ord < $1.ord }
                guard !fields.isEmpty, fields.count <= 100, fields.map(\.ord) == Array(0..<fields.count), values.count == fields.count,
                      Set(fields.map(\.name)).count == fields.count,
                      fields.allSatisfy({ !$0.name.isEmpty && !$0.name.contains("{") && !$0.name.contains("}") && !$0.name.contains(":") }) else { throw AnkiImportError.unsupported("フィールド定義が不正です") }
                let valuesByName = Dictionary(uniqueKeysWithValues: zip(fields.map(\.name), values))
                let kind: NoteKind, reverse: Bool
                if model.type == 0 {
                    guard templates.count == 1 || templates.count == 2 else { throw AnkiImportError.unsupported("1枚の基本または2枚の逆方向テンプレートのみ対応") }
                    kind = .basic; reverse = noteCards.contains { $0.ordinal == 1 }
                    guard (!reverse || templates.count == 2), Set(noteCards.map(\.ordinal)) == Set(reverse ? [0, 1] : [0]) else { throw AnkiImportError.unsupported("基本カードのordinalが一致しません") }
                } else if model.type == 1 {
                    guard templates.count == 1 else { throw AnkiImportError.unsupported("穴埋めテンプレートが複数あります") }
                    kind = .cloze; reverse = false
                } else { throw AnkiImportError.unsupported("画像遮蔽などのモデルは未対応") }
                guard templates.map(\.ord) == Array(0..<templates.count) else { throw AnkiImportError.unsupported("テンプレートのordinalが不正です") }
                var used = Set<String>()
                let front = try render(templates[0].qfmt, values: valuesByName, answer: false, cloze: kind == .cloze, used: &used)
                let back = try render(templates[0].afmt, values: valuesByName, answer: true, cloze: kind == .cloze, used: &used)
                let question = try field(front), answer = try field(back)
                if templates.count == 2 {
                    let reverseFront = try field(render(templates[1].qfmt, values: valuesByName, answer: false, cloze: false, used: &used))
                    let reverseBack = try field(render(templates[1].afmt, values: valuesByName, answer: true, cloze: false, used: &used))
                    guard reverseFront.text == answer.text, reverseBack.text == question.text,
                          reverseFront.audio == answer.audio, reverseBack.audio == question.audio,
                          reverseFront.image == nil, reverseBack.image == nil else { throw AnkiImportError.unsupported("2枚目が問題と解答を交換する逆方向ではありません") }
                }
                let unused = fields.filter { !used.contains($0.name) && !(valuesByName[$0.name] ?? "").isEmpty }.map(\.name)
                var noteWarnings: [AnkiSkippedNote] = []
                if !unused.isEmpty { noteWarnings.append(AnkiSkippedNote(id: row[0] + "-fields", reason: "テンプレートで使用されないフィールドは移行しません：" + unused.joined(separator: "、"))) }
                guard answer.image == nil, !(reverse && question.image != nil) else { throw AnkiImportError.unsupported("解答画像・画像付き逆方向は未対応") }
                var content = TextContent(question: question.text, answer: kind == .cloze ? "" : answer.text,
                    explanation: kind == .cloze ? answer.text : "", reverseEnabled: reverse)
                if let image = question.image { content.imageID = try attach(image, audio: false); if content.question.isEmpty { content.question = "画像の内容を答えてください" } }
                if let audio = question.audio {
                    if mediaByName[audio] != nil { content.questionAudioID = try attach(audio, audio: true) }
                    else { noteWarnings.append(AnkiSkippedNote(id: row[0] + "-question-audio", reason: "問題音声がありません。本文のみ移行：\(audio)")) }
                }
                if let audio = answer.audio {
                    if mediaByName[audio] != nil { content.answerAudioID = try attach(audio, audio: true) }
                    else { noteWarnings.append(AnkiSkippedNote(id: row[0] + "-answer-audio", reason: "解答音声がありません。本文のみ移行：\(audio)")) }
                }
                guard !content.question.isEmpty, kind == .cloze || !content.answer.isEmpty else { throw AnkiImportError.unsupported("本文のない音声のみのノートは未対応") }
                let variants = try CardGeneration.variants(kind: kind, content: content)
                if kind == .cloze {
                    let ordinals = Set(variants.compactMap { Int($0.dropFirst(6)).map { $0 - 1 } })
                    guard ordinals == Set(noteCards.map(\.ordinal)) else { throw AnkiImportError.unsupported("穴埋めの番号と元カード数が一致しません") }
                }
                guard variants.count == noteCards.count else { throw AnkiImportError.unsupported("元カード数と生成数が一致しません") }
                let deckName = sourceDecks[noteCards[0].deckID]!.name
                notes.append(SharedNote(id: UUID(), deckID: try destination(deckName), kind: kind, content: content, responseMode: .mental,
                    tags: row[3].split(whereSeparator: \.isWhitespace).map(String.init)))
                warnings.append(contentsOf: noteWarnings)
            } catch is CancellationError { throw CancellationError() }
            catch AnkiImportError.budget { throw AnkiImportError.budget }
            catch BackupError.tooLarge { throw BackupError.tooLarge }
            catch { skipped.append(AnkiSkippedNote(id: row[0], reason: error.localizedDescription)) }
        }
        guard !notes.isEmpty else { throw AnkiImportError.unsupported("移行できるノートがありません。" + (skipped.first?.reason ?? "")) }
        try budget.check()
        let referenced = Set(notes.flatMap { [$0.content.imageID].compactMap { $0 } + $0.content.audioIDs })
        media = media.filter { referenced.contains($0.id) }; mediaBytes = mediaBytes.filter { referenced.contains($0.key) }
        let package = DeckPackage(rootID: rootID, decks: decks, notes: notes, media: media)
        let validated = try DeckExchange.validated(package: package, bytes: mediaBytes)
        return AnkiImportPreview(deck: validated, sourceNotes: rows.count, sourceCards: cards.count,
            scheduledCards: cards.filter(\.studied).count, reviewLogs: Int(logs.first?.first ?? "0") ?? 0, skipped: skipped, warnings: warnings)
    }
    private static func metadata(_ db: AnkiDatabase, budget: AnkiReadBudget) throws -> ([String: AnkiModel], [String: AnkiDeck]) {
        if db.schemaVersion == 11 {
            let rows = try db.rows("SELECT models,decks FROM col", maximum: 1)
            guard rows.count == 1 else { throw AnkiImportError.database }
            let models = try JSONDecoder().decode([String: AnkiModel].self, from: Data(rows[0][0].utf8))
            let decks = try JSONDecoder().decode([String: AnkiDeck].self, from: Data(rows[0][1].utf8))
            guard models.count <= 1000, decks.count <= 9999 else { throw BackupError.tooLarge }
            return (models, decks)
        }
        let fields = try db.rows("SELECT ntid,ord,name FROM fields ORDER BY ntid,ord", maximum: 100_000)
        let templates = try db.dataRows("SELECT ntid,ord,config FROM templates ORDER BY ntid,ord", maximum: 100_000, blobColumns: [2])
        var fieldsByModel: [String: [AnkiModel.Field]] = [:], templatesByModel: [String: [AnkiModel.Template]] = [:]
        for row in fields {
            guard let ordinal = Int(row[1]) else { throw AnkiImportError.database }
            fieldsByModel[row[0], default: []].append(.init(name: row[2], ord: ordinal))
        }
        for row in templates {
            guard let id = String(data: row[0], encoding: .utf8), let ordinalText = String(data: row[1], encoding: .utf8), let ordinal = Int(ordinalText) else { throw AnkiImportError.database }
            let config = try AnkiProto(row[2], budget: budget)
            templatesByModel[id, default: []].append(.init(qfmt: try config.string(1), afmt: try config.string(2), ord: ordinal))
        }
        var models: [String: AnkiModel] = [:]
        for row in try db.dataRows("SELECT id,config FROM notetypes ORDER BY id", maximum: 1000, blobColumns: [1]) {
            guard let id = String(data: row[0], encoding: .utf8), models[id] == nil else { throw AnkiImportError.database }
            let config = try AnkiProto(row[1], budget: budget), kind = try config.number(1)
            guard kind <= 1 else { throw AnkiImportError.database }
            models[id] = AnkiModel(type: Int(kind), flds: fieldsByModel[id] ?? [], tmpls: templatesByModel[id] ?? [])
        }
        var decks: [String: AnkiDeck] = [:]
        for row in try db.rows("SELECT id,name FROM decks ORDER BY id", maximum: 9999) {
            guard decks[row[0]] == nil else { throw AnkiImportError.database }
            decks[row[0]] = AnkiDeck(name: row[1].replacingOccurrences(of: "\u{1f}", with: "::"))
        }
        return (models, decks)
    }
    private static func render(_ template: String, values: [String: String], answer: Bool, cloze: Bool, used: inout Set<String>) throws -> String {
        let regex = try NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#)
        let remainder = regex.stringByReplacingMatches(in: template, range: NSRange(template.startIndex..., in: template), withTemplate: "")
        guard !remainder.contains("{{"), !remainder.contains("}}") else { throw AnkiImportError.unsupported("テンプレート構文が不正です") }
        var result = template
        var clozeCount = 0
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            let token = (template as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let value: String
            if token == "FrontSide" {
                guard answer else { throw AnkiImportError.unsupported("問題面のFrontSideは未対応") }; value = ""
            } else if token.hasPrefix("cloze:") {
                let name = String(token.dropFirst(6))
                guard cloze, let text = values[name] else { throw AnkiImportError.unsupported("穴埋めフィールドが不正です") }
                used.insert(name); clozeCount += 1; value = answer ? "" : text
            } else {
                guard let text = values[token] else { throw AnkiImportError.unsupported("条件分岐・フィルタ・未知のフィールドは未対応：\(token)") }
                used.insert(token); value = text
            }
            guard let range = Range(match.range, in: result) else { throw AnkiImportError.database }
            result.replaceSubrange(range, with: value)
        }
        guard !cloze || clozeCount == 1 else { throw AnkiImportError.unsupported("テンプレート構文が未対応です") }
        return result
    }
    // Decode a small, explicit HTML subset into plain text. No WebView or HTML attributed-string parser.
    private static func field(_ source: String) throws -> AnkiField {
        guard source.count <= 1_000_000, source.range(of: #"(?i)<\s*(script|style|iframe|object|embed|svg|video|audio|math)\b|javascript:|\[latex\]|\[\$"#, options: .regularExpression) == nil else { throw AnkiImportError.unsupported("スクリプト・動画・SVG・LaTeX等は未対応") }
        var text = source
        let sound = try NSRegularExpression(pattern: #"\[sound:([^\]]+)\]"#)
        let sounds = sound.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard sounds.count <= 1 else { throw AnkiImportError.unsupported("1面に複数の音声は未対応") }
        let audio = sounds.first.map { (text as NSString).substring(with: $0.range(at: 1)) }
        text = sound.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        let imagePattern = #"(?i)<img\s+src\s*=\s*[\"']([^\"']+)[\"']\s*/?>"#
        let imageRegex = try NSRegularExpression(pattern: imagePattern)
        let images = imageRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard images.count <= 1 else { throw AnkiImportError.unsupported("1面に複数の画像は未対応") }
        let image = images.first.map { (text as NSString).substring(with: $0.range(at: 1)) }
        text = imageRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        let tags = try NSRegularExpression(pattern: #"<[^>]*>"#)
        let matches = tags.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let allowed = Set(["br", "div", "p", "b", "i", "u", "strong", "em", "span", "font", "hr", "ul", "ol", "li", "a", "sup", "sub", "h1", "h2", "h3", "h4", "h5", "h6"])
        for match in matches.reversed() {
            let tag = (text as NSString).substring(with: match.range)
            let name = tag.dropFirst().drop(while: { $0 == "/" || $0.isWhitespace }).prefix(while: { $0.isLetter || $0.isNumber }).lowercased()
            guard allowed.contains(name) else { throw AnkiImportError.unsupported("未対応HTMLまたは画像タグ：\(name)") }
            let replacement = ["br", "div", "p", "li", "hr", "h1", "h2", "h3", "h4", "h5", "h6"].contains(name) ? "\n" : ""
            if let range = Range(match.range, in: text) { text.replaceSubrange(range, with: replacement) }
        }
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] { text = text.replacingOccurrences(of: entity, with: value) }
        let numbers = try NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#)
        for match in numbers.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let raw = (text as NSString).substring(with: match.range(at: 1))
            let value = raw.hasPrefix("x") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw)
            guard let value, let scalar = UnicodeScalar(value), value != 0, let range = Range(match.range, in: text) else { throw AnkiImportError.unsupported("不正な文字参照") }
            text.replaceSubrange(range, with: String(scalar))
        }
        return AnkiField(text: text.trimmingCharacters(in: .whitespacesAndNewlines), image: image, audio: audio)
    }
}
