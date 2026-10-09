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

    static func map(_ table: DelimitedTable, header: Bool, questionColumn: Int, answerColumn: Int) -> [ImportRow] {
        table.rows.enumerated().compactMap { index, row in
            if header && index == 0 { return nil }
            let question = row.indices.contains(questionColumn) ? row[questionColumn] : ""
            let answer = row.indices.contains(answerColumn) ? row[answerColumn] : ""
            return ImportRow(line: table.lines[index], question: question, answer: answer,
                             error: question.isEmpty || answer.isEmpty ? "問題または解答が未入力です。" : nil)
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
