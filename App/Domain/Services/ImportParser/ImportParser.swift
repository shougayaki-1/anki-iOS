import Foundation

struct DelimitedTable {
    let rows: [[String]]
    let lines: [Int]
}

struct ImportParser {
    // RFC 4180 style quoting, including multiline fields and escaped double quotes.
    static func table(_ text: String, delimiter: Character) throws -> DelimitedTable {
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var rows: [[String]] = [], lines: [Int] = [], row: [String] = [], field = ""
        var quoted = false, closed = false, line = 1, rowLine = 1, index = 0
        while index < chars.count {
            let char = chars[index]
            if quoted {
                if char == "\"" {
                    if index + 1 < chars.count && chars[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(char); if char == "\n" { line += 1 } }
            } else if char == delimiter {
                row.append(field); field = ""; closed = false
            } else if char == "\n" {
                row.append(field)
                if row.contains(where: { !$0.isEmpty }) { rows.append(row); lines.append(rowLine) }
                row = []; field = ""; closed = false; line += 1; rowLine = line
            } else if char == "\"" {
                guard field.isEmpty && !closed else { throw LibraryError.malformedCSV(line) }
                quoted = true
            } else {
                guard !closed else { throw LibraryError.malformedCSV(line) }
                field.append(char)
            }
            index += 1
        }
        guard !quoted else { throw LibraryError.malformedCSV(rowLine) }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row); lines.append(rowLine) }
        return DelimitedTable(rows: rows, lines: lines)
    }

    static func map(_ table: DelimitedTable, header: Bool, questionColumn: Int, answerColumn: Int, hintColumn: Int? = nil, modeColumn: Int? = nil) -> [ImportRow] {
        table.rows.enumerated().compactMap { index, row in
            if header && index == 0 { return nil }
            let question = row.indices.contains(questionColumn) ? row[questionColumn] : ""
            let answer = row.indices.contains(answerColumn) ? row[answerColumn] : ""
            var mapped = ImportRow(line: table.lines[index], question: question, answer: answer,
                             error: question.isEmpty || answer.isEmpty ? "問題または解答が未入力です。" : nil)
            if let hintColumn { mapped.hint = row.indices.contains(hintColumn) ? row[hintColumn] : "" }
            if let modeColumn {
                let value = row.indices.contains(modeColumn) ? row[modeColumn].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
                let aliases: [String: ResponseMode] = ["mental": .mental, "頭の中": .mental, "頭の中で回答": .mental,
                                                     "typing": .typing, "文字入力": .typing,
                                                     "ordering": .ordering, "並び替え": .ordering]
                mapped.responseMode = aliases[value] ?? .mental
                if !value.isEmpty && aliases[value] == nil { mapped.modeWarning = "回答方式が不明なため、頭の中で回答に切り替えます。" }
            }
            return mapped
        }
    }

    static func hintColumn(in table: DelimitedTable) -> Int? {
        table.rows.first?.firstIndex {
            ["hint", "ヒント"].contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    static func responseModeColumn(in table: DelimitedTable) -> Int? {
        table.rows.first?.firstIndex {
            ["responsemode", "response_mode", "回答方式", "回答方法"].contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    static func pasted(_ text: String) throws -> [ImportRow] {
        if text.contains("\t") { return map(try table(text, delimiter: "\t"), header: false, questionColumn: 0, answerColumn: 1) }
        var rows: [ImportRow] = [], question: String?, answer = "", readingAnswer = false, start = 1
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            if line.hasPrefix("Q:") || line.hasPrefix("Q：") {
                if let question { rows.append(ImportRow(line: start, question: question, answer: answer)) }
                question = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                answer = ""; readingAnswer = false; start = index + 1
            } else if line.hasPrefix("A:") || line.hasPrefix("A：") {
                answer = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces); readingAnswer = true
            } else if question != nil {
                if readingAnswer { answer += "\n" + line } else { question! += "\n" + line }
            }
        }
        if let question { rows.append(ImportRow(line: start, question: question, answer: answer)) }
        if rows.isEmpty {
            // Plain prose is editable input, not automatically invented questions.
            return [ImportRow(line: 1, question: text, answer: "", error: "解答を入力してカードにしてください。")]
        }
        return rows.map { row in
            var row = row
            if row.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || row.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                row.error = "問題または解答が未入力です。"
            }
            return row
        }
    }

    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct ImageImportRow: Identifiable {
    var id = UUID()
    var line: Int
    var question: String
    var answer: String
    var explanation: String
    var imagePath: String
    var deckPath: String
    var tags: [String]
    var error: String?
    var included = true
}
struct ImageImportPackage: Identifiable {
    let id = UUID()
    var rows: [ImageImportRow]
    let images: [String: Data]
    static func read(_ data: Data) throws -> Self {
        let files: [String: Data]
        do { files = try ImageImportZIP.read(data) }
        catch BackupError.tooLarge { throw ImageImportError.tooLarge }
        catch BackupError.unsupportedArchive { throw ImageImportError.unsupportedArchive }
        catch { throw ImageImportError.invalidArchive }
        let tables = ["cards.csv", "cards.tsv"].filter { files[$0] != nil }
        guard tables.count == 1, let path = tables.first, let bytes = files[path], bytes.count <= 10_000_000,
              let text = String(data: bytes, encoding: .utf8) else { throw ImageImportError.invalidTable }
        let table = try ImportParser.table(text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text, delimiter: path.hasSuffix("csv") ? "," : "\t")
        guard let header = table.rows.first else { throw ImageImportError.invalidTable }
        let keys = header.map { ImportParser.normalized($0).lowercased() }
        guard Set(keys).count == keys.count, keys.contains("answer"), keys.contains("image") else { throw ImageImportError.invalidTable }
        var images: [String: Data] = [:], errors: [String: String] = [:]
        for (name, bytes) in files where name.hasPrefix("images/") {
            guard ["png", "jpg", "jpeg"].contains((name as NSString).pathExtension.lowercased()) else { errors[name] = "PNG / JPEG の画像を指定してください。"; continue }
            guard bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) || bytes.starts(with: [255, 216]) else {
                errors[name] = "画像の実データがPNG / JPEGではありません。"; continue
            }
            do { images[name] = try ImageEncodingPolicy.prepare(bytes).data }
            catch { errors[name] = "画像が壊れているか、画像の容量・サイズ上限を超えています。" }
        }
        let rows = table.rows.dropFirst().enumerated().map { index, values in
            func value(_ key: String) -> String {
                guard let column = keys.firstIndex(of: key), values.indices.contains(column) else { return "" }
                return ImportParser.normalized(values[column])
            }
            let image = value("image"), question = value("question"), answer = value("answer")
            var error: String?
            if answer.isEmpty { error = "解答が空です。" }
            else if image.isEmpty { error = "画像パスが空です。" }
            else if !image.hasPrefix("images/") || !StoredZIP.validPath(image) { error = "images/ 内の相対パスを指定してください。" }
            else if images[image] == nil { error = errors[image] ?? "参照先の画像が見つかりません。" }
            let deck = value("deck")
            if !deck.isEmpty && deck.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.count > 100 }) { error = "デッキの階層パスが不正です。" }
            return ImageImportRow(line: table.lines[index + 1], question: question.isEmpty ? "画像を見て答えてください" : question,
                                  answer: answer, explanation: value("explanation"), imagePath: image, deckPath: deck,
                                  tags: value("tags").split(whereSeparator: { $0 == "," || $0 == ";" }).map { ImportParser.normalized(String($0)) }, error: error)
        }
        guard !rows.isEmpty, rows.count <= 10_000 else { throw BackupError.tooLarge }
        return Self(rows: rows, images: images)
    }
}

enum ImageImportError: LocalizedError {
    case invalidArchive, unsupportedArchive, tooLarge, invalidTable
    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "画像ZIPの構造・パス・チェックサムが不正です。データは保存されていません。"
        case .unsupportedArchive: return "無圧縮またはDeflateのZIPを選択してください。暗号化・ZIP64・シンボリックリンクは未対応です。"
        case .tooLarge: return "画像ZIPは合計200MB、1000ファイル、1ファイル20MB、圧縮比100倍までです。"
        case .invalidTable: return "ZIP直下にUTF-8のcards.csvまたはcards.tsvを1つ入れ、重複しないanswer・imageヘッダーを指定してください。表は10MBまでです。"
        }
    }
}
