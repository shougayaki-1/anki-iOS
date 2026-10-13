import XCTest
@testable import AnkiIOS

final class ImportParserTests: XCTestCase {
    func testUnifiedImportRoutesTextDeckAndImageZIPWithoutFallback() throws {
        for ext in ["csv", "tsv", "txt"] {
            guard case .text(let value) = try LocalFileInput.decodeImport(Data("\u{feff}Q: 問題\nA: 解答".utf8), extension: ext) else {
                return XCTFail("Expected text for \(ext)")
            }
            XCTAssertEqual(value, "Q: 問題\nA: 解答")
        }
        let id = UUID()
        let package = DeckPackage(rootID: id, decks: [SharedDeck(id: id, name: "Test", parentID: nil)], notes: [], media: [])
        let deck = try DeckExchange.encode(package, bytes: [:])
        for ext in ["studydeck", "zip", "STUDYDECK"] {
            guard case .deck(let value) = try LocalFileInput.decodeImport(deck, extension: ext) else { return XCTFail("Expected deck") }
            XCTAssertEqual(value.package, package)
        }
        let images = try StoredZIP.write(["cards.csv": Data("question,answer,image\nQ,A,images/missing.png".utf8)])
        guard case .images(let value) = try LocalFileInput.decodeImport(images, extension: "zip") else { return XCTFail("Expected images") }
        XCTAssertEqual(value.rows.count, 1)
        XCTAssertNotNil(value.rows[0].error) // Missing media remains an explicit row error.
        XCTAssertThrowsError(try LocalFileInput.decodeImport(images, extension: "studydeck"))
        XCTAssertThrowsError(try LocalFileInput.decodeImport(deck, extension: "apkg"))
        XCTAssertThrowsError(try LocalFileInput.decodeImport(deck, extension: "csv"))
        var mixed = try StoredZIP.read(deck); mixed["cards.csv"] = Data("answer,image".utf8)
        XCTAssertThrowsError(try LocalFileInput.decodeImport(StoredZIP.write(mixed), extension: "zip"))
        mixed = try StoredZIP.read(deck); mixed["deck.json"] = Data("broken".utf8)
        XCTAssertThrowsError(try LocalFileInput.decodeImport(StoredZIP.write(mixed), extension: "zip"))
        XCTAssertThrowsError(try LocalFileInput.decodeImport(Data("not a ZIP".utf8), extension: "zip"))
    }

    func testUnifiedImportRejectsBackupEvenWhenRenamedAndUnknownVersion() throws {
        let backup = try StoredZIP.write(["data.json": Data("{}".utf8), "manifest.json": Data("{}".utf8)])
        for ext in ["studybackup", "zip", "studydeck", "apkg"] {
            XCTAssertThrowsError(try LocalFileInput.decodeImport(backup, extension: ext)) { error in
                guard case ImportRoutingError.backup = error else { return XCTFail("Expected restore guidance: \(error)") }
            }
        }
        let id = UUID()
        let package = DeckPackage(rootID: id, decks: [SharedDeck(id: id, name: "Test", parentID: nil)], notes: [], media: [])
        var files = try StoredZIP.read(DeckExchange.encode(package, bytes: [:]))
        var manifest = try JSONSerialization.jsonObject(with: XCTUnwrap(files["manifest.json"])) as! [String: Any]
        manifest["schemaVersion"] = 999
        files["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest)
        XCTAssertThrowsError(try LocalFileInput.decodeImport(StoredZIP.write(files), extension: "zip"))
    }

    func testAsyncImportFileReaderPreservesBOMAndCancellation() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("csv")
        try Data("\u{feff}question,answer\r\n日本語,解答".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        guard case let .text(text) = try await LocalFileInput.readImport(file) else { return XCTFail("Expected text") }
        XCTAssertEqual(text, "question,answer\r\n日本語,解答")
        let task = Task { try await LocalFileInput.readImport(file) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled read accepted") } catch is CancellationError { }
    }
    func testIteratorCSVNormalizesBareCRAndPreservesGraphemes() throws {
        let table = try ImportParser.table("question,answer\r\"e\u{301}👨‍👩‍👧‍👦\r\n次の行\",\"\"\"引用\"\"\"\rQ,A", delimiter: ",")
        XCTAssertEqual(table.lines, [1, 2, 4])
        XCTAssertEqual(table.rows[1], ["e\u{301}👨‍👩‍👧‍👦\n次の行", "\"引用\""])
    }
    func testImportReceiptDistinguishesCompletePartialAndZero() {
        XCTAssertEqual(ImportResult(imported: 0, skipped: 0, errors: []).outcome, .empty)
        XCTAssertEqual(ImportResult(imported: 0, skipped: 1, errors: ["invalid"]).outcome, .empty)
        XCTAssertEqual(ImportResult(imported: 1, skipped: 0, errors: []).outcome, .complete)
        XCTAssertEqual(ImportResult(imported: 1, skipped: 1, errors: []).outcome, .partial)
        XCTAssertEqual(ImportResult(imported: 1, skipped: 0, errors: ["invalid"]).outcome, .partial)
        let updated = ImportResult(imported: 1, skipped: 0, errors: [], updatedNotes: 1, maintainedCards: 2)
        XCTAssertEqual(updated.createdCards, 0)
        XCTAssertEqual(updated.outcome, .complete)
    }

    func testNativeFileReaderRejectsUnsupportedOversizedDirectoryAndSymbolicLink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sample.csv"), bytes = Data("Q,A\n".utf8)
        try bytes.write(to: file)
        XCTAssertEqual(try LocalFileInput.read(file, extensions: ["csv"], maximumBytes: bytes.count), bytes)
        XCTAssertThrowsError(try LocalFileInput.read(file, extensions: ["csv"], maximumBytes: bytes.count - 1))
        XCTAssertThrowsError(try LocalFileInput.read(file, extensions: ["txt"], maximumBytes: 100))
        XCTAssertThrowsError(try LocalFileInput.read(URL(string: "https://example.com/data.csv")!, extensions: ["csv"], maximumBytes: 100))
        let link = directory.appendingPathComponent("link.csv")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try LocalFileInput.read(link, extensions: ["csv"], maximumBytes: 100))
        let folder = directory.appendingPathComponent("folder.csv")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try LocalFileInput.read(folder, extensions: ["csv"], maximumBytes: 100))
    }

    @MainActor func testFinderURLProviderUsesTheSameBoundedReader() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("csv")
        let bytes = Data("question,answer\nQ,A\n".utf8)
        try bytes.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let provider = NSItemProvider(item: file as NSURL, typeIdentifier: "public.file-url")
        let result: Result<(URL, Data), Error> = await withCheckedContinuation { continuation in
            LocalFileInput.load(provider, extensions: ["csv"], maximumBytes: 100) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(try result.get().1, bytes)
    }

    func testOptionalTextLayoutsAndInvalidDirection() throws {
        let table = try ImportParser.table("question,answer,question_layout,answer_layout\nQ,A,vertical,horizontal\nX,Y,bad,\nOld,A,,", delimiter: ",")
        let rows = ImportParser.map(table, header: true, questionColumn: 0, answerColumn: 1)
        XCTAssertEqual(rows[0].questionLayout, .vertical); XCTAssertEqual(rows[0].answerLayout, .horizontal)
        XCTAssertNotNil(rows[1].error); XCTAssertFalse(rows[1].included)
        XCTAssertNil(rows[2].questionLayout)
    }
    func testHintHeaderMappingExplicitBlankAndAbsentColumn() throws {
        for (delimiter, header) in [(Character(","), " HINT "), (Character("\t"), "ヒント")] {
            let text = ["question", "answer", header].joined(separator: String(delimiter)) + "\n" +
                ["Q", "A", "手がかり"].joined(separator: String(delimiter)) + "\n" +
                ["Q2", "A2", ""].joined(separator: String(delimiter))
            let table = try ImportParser.table(text, delimiter: delimiter)
            XCTAssertEqual(ImportParser.hintColumn(in: table), 2)
            let rows = ImportParser.map(table, header: true, questionColumn: 0, answerColumn: 1,
                                        hintColumn: ImportParser.hintColumn(in: table))
            XCTAssertEqual(rows.map(\.hint), ["手がかり", ""])
            XCTAssertTrue(ImportParser.map(table, header: true, questionColumn: 0, answerColumn: 1).allSatisfy { $0.hint == nil })
        }
        let old = try ImportParser.table("question,answer\nQ,A", delimiter: ",")
        XCTAssertNil(ImportParser.hintColumn(in: old))
        XCTAssertNil(try ImportParser.pasted("Q: Q\nA: A")[0].hint)
        let multiline = try ImportParser.table("Q,A,\"line one\nline two\"", delimiter: ",")
        XCTAssertEqual(ImportParser.map(multiline, header: false, questionColumn: 0, answerColumn: 1, hintColumn: 2)[0].hint, "line one\nline two")
    }
    func testCSVQuotedCommasNewlinesQuotesAndHeaderMapping() throws {
        let text = "id,answer,question\r\n1,\"A, with \"\"quotes\"\"\",\"Q\nsecond line\"\r\n2,A2,Q2\r\n"
        let table = try ImportParser.table(text, delimiter: ",")
        XCTAssertEqual(table.rows.count, 3)
        let rows = ImportParser.map(table, header: true, questionColumn: 2, answerColumn: 1)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].question, "Q\nsecond line")
        XCTAssertEqual(rows[0].answer, "A, with \"quotes\"")
        XCTAssertEqual(rows.map(\.line), [2, 4])
    }
    func testTSVBlankFieldsAndInvalidCSV() throws {
        let rows = ImportParser.map(try ImportParser.table("Q\tA\nmissing\t\n\n", delimiter: "\t"), header: false, questionColumn: 0, answerColumn: 1)
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotNil(rows[1].error)
        XCTAssertThrowsError(try ImportParser.table("\"unterminated", delimiter: ","))
        XCTAssertThrowsError(try ImportParser.table("unquoted\"quote,A", delimiter: ","))
        XCTAssertThrowsError(try ImportParser.table("\"Q\"extra,A", delimiter: ","))
    }
    func testPasteQAAndPlainTextRemainEditable() throws {
        let rows = try ImportParser.pasted("Q: Question\ncontinued\nA: Answer\nmore\nQ: Q2\nA: A2")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].question, "Question\ncontinued")
        XCTAssertEqual(rows[0].answer, "Answer\nmore")
        let prose = try ImportParser.pasted("A plain paragraph without questions")
        XCTAssertEqual(prose.count, 1)
        XCTAssertEqual(prose[0].answer, "")
        XCTAssertNotNil(prose[0].error)
        XCTAssertEqual(try ImportParser.pasted("Q1\tA1\nQ2\tA2").count, 2)
    }
}
