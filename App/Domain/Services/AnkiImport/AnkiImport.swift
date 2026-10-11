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
        let files: [String: Data]
        do { files = try StoredZIP.read(bytes, allowDeflate: true) }
        catch BackupError.unsupportedArchive { throw AnkiImportError.unsupported("ZIP構成が未対応です。通常のstore/DEFLATE形式（暗号化・ZIP64・extra field・データディスクリプタなし）を選んでください。") }
        guard files["collection.anki21b"] == nil else { throw AnkiImportError.modern }
        if let meta = files["meta"] {
            guard meta == Data([8, 1]) || meta == Data([8, 2]) else { throw AnkiImportError.modern }
        }
        let name = files["collection.anki21"] == nil ? "collection.anki2" : "collection.anki21"
        guard let database = files[name], let mediaJSON = files["media"], mediaJSON.count <= 5_000_000,
              let map = try? JSONDecoder().decode([String: String].self, from: mediaJSON), map.count <= 9996 else { throw AnkiImportError.database }
        try BackupValidation.unique(map.values.map { $0.precomposedStringWithCanonicalMapping })
        let allowed: Set<String> = ["collection.anki2", "collection.anki21", "media", "meta"]
        guard files.keys.allSatisfy({ allowed.contains($0) || map[$0] != nil }),
              map.allSatisfy({ key, value in !key.isEmpty && key.allSatisfy(\.isNumber) && files[key] != nil && StoredZIP.validPath(value) && !value.contains("/") && value.count <= 1000 }) else { throw AnkiImportError.database }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AnkiRead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AnkiDatabase(bytes: database, url: directory.appendingPathComponent("collection.sqlite"))
        let collection = try db.rows("SELECT ver,models,decks FROM col", maximum: 1)
        guard collection.count == 1, collection[0][0] == "11" else { throw AnkiImportError.database }
        let models = try JSONDecoder().decode([String: AnkiModel].self, from: Data(collection[0][1].utf8))
        let sourceDecks = try JSONDecoder().decode([String: AnkiDeck].self, from: Data(collection[0][2].utf8))
        guard models.count <= 1000, sourceDecks.count <= 9999 else { throw BackupError.tooLarge }
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
        let mediaByName = Dictionary(uniqueKeysWithValues: map.map { ($0.value, files[$0.key]!) })
        let rootID = UUID()
        var decks = [SharedDeck(id: rootID, name: "Anki取込", parentID: nil)], deckPaths: [String: UUID] = ["": rootID]
        var notes: [SharedNote] = [], media: [SharedMedia] = [], mediaBytes: [UUID: Data] = [:], mediaIDs: [String: UUID] = [:], skipped: [AnkiSkippedNote] = []
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
            try Task.checkCancellation()
            do {
                guard let model = models[row[1]] else { throw AnkiImportError.unsupported("ノートモデルがありません") }
                let noteCards = byNote[row[0]] ?? []
                guard !noteCards.isEmpty, Set(noteCards.map(\.deckID)).count == 1,
                      Set(noteCards.map(\.ordinal)).count == noteCards.count else { throw AnkiImportError.unsupported("カードなし・複数デッキ・重複ordinalのノートは未対応") }
                let values = row[2].components(separatedBy: "\u{1f}")
                let fields = model.flds.sorted { $0.ord < $1.ord }, templates = model.tmpls.sorted { $0.ord < $1.ord }
                guard fields.count == 2, fields.map(\.ord) == [0, 1], values.count == 2,
                      fields.allSatisfy({ !$0.name.isEmpty && !$0.name.contains("{") && !$0.name.contains("}") }) else { throw AnkiImportError.unsupported("2フィールドの標準モデルのみ対応") }
                let first = "{{\(fields[0].name)}}", second = "{{\(fields[1].name)}}", cloze = "{{cloze:\(fields[0].name)}}"
                let normalized: (String) throws -> String = { try field($0).text.filter { !$0.isWhitespace } }
                let expected: [(String, String)]
                let kind: NoteKind, reverse: Bool
                if model.type == 0 {
                    guard templates.count == 1 || templates.count == 2 else { throw AnkiImportError.unsupported("標準の基本・逆方向テンプレートのみ対応") }
                    expected = templates.count == 1 ? [(first, "{{FrontSide}}" + second)] : [(first, "{{FrontSide}}" + second), (second, "{{FrontSide}}" + first)]
                    kind = .basic; reverse = noteCards.contains { $0.ordinal == 1 }
                    guard (!reverse || templates.count == 2), Set(noteCards.map(\.ordinal)) == Set(reverse ? [0, 1] : [0]) else { throw AnkiImportError.unsupported("基本カードのordinalが一致しません") }
                } else if model.type == 1 {
                    guard templates.count == 1 else { throw AnkiImportError.unsupported("標準の穴埋めテンプレートのみ対応") }
                    expected = [(cloze, cloze + second)]; kind = .cloze; reverse = false
                } else { throw AnkiImportError.unsupported("画像遮蔽などのカスタムモデルは未対応") }
                for (index, template) in templates.enumerated() {
                    guard template.ord == index, try normalized(template.qfmt) == expected[index].0.filter({ !$0.isWhitespace }),
                          try normalized(template.afmt) == expected[index].1.filter({ !$0.isWhitespace }) else { throw AnkiImportError.unsupported("任意HTML/JS・条件分岐・フィルタを含むテンプレートは未対応") }
                }
                let question = try field(values[0]), answer = try field(values[1])
                guard answer.image == nil, !(reverse && question.image != nil) else { throw AnkiImportError.unsupported("解答画像・画像付き逆方向は未対応") }
                var content = TextContent(question: question.text, answer: kind == .cloze ? "" : answer.text,
                    explanation: kind == .cloze ? answer.text : "", reverseEnabled: reverse)
                if let image = question.image { content.imageID = try attach(image, audio: false); if content.question.isEmpty { content.question = "画像の内容を答えてください" } }
                if let audio = question.audio { content.questionAudioID = try attach(audio, audio: true) }
                if let audio = answer.audio { content.answerAudioID = try attach(audio, audio: true) }
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
            } catch is CancellationError { throw CancellationError() }
            catch { skipped.append(AnkiSkippedNote(id: row[0], reason: error.localizedDescription)) }
        }
        let referenced = Set(notes.flatMap { [$0.content.imageID].compactMap { $0 } + $0.content.audioIDs })
        media = media.filter { referenced.contains($0.id) }; mediaBytes = mediaBytes.filter { referenced.contains($0.key) }
        let package = DeckPackage(rootID: rootID, decks: decks, notes: notes, media: media)
        let validated = try DeckExchange.validated(package: package, bytes: mediaBytes)
        return AnkiImportPreview(deck: validated, sourceNotes: rows.count, sourceCards: cards.count,
            scheduledCards: cards.filter(\.studied).count, reviewLogs: Int(logs.first?.first ?? "0") ?? 0, skipped: skipped)
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
        let allowed = Set(["br", "div", "p", "b", "i", "u", "strong", "em", "span", "font", "hr", "ul", "ol", "li", "a", "sup", "sub"])
        for match in matches.reversed() {
            let tag = (text as NSString).substring(with: match.range)
            let name = tag.dropFirst().drop(while: { $0 == "/" || $0.isWhitespace }).prefix(while: { $0.isLetter }).lowercased()
            guard allowed.contains(name) else { throw AnkiImportError.unsupported("未対応HTMLまたは画像タグ：\(name)") }
            let replacement = ["br", "div", "p", "li"].contains(name) ? "\n" : ""
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
