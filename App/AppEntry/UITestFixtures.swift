#if DEBUG
import Foundation
import UIKit
import SwiftData
import SQLite3

// Only explicit UI-test launch arguments create fixtures, in the app's sandbox.
enum UITestFixtures {
    @MainActor static func configureAccessibilityScene() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            scene.traitOverrides.userInterfaceStyle = .dark
        }
    }
    @MainActor static func populateNewReviewDue(_ store: StudyStore) throws {
        let repo = store.repository, now = store.clock()
        guard try repo.notes().isEmpty else { return }
        try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "Long-term review", answer: "Answer"), now: now)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(revealed: true, now: now)
        try repo.grade(.easy, now: now)
        guard let due = try repo.cards().first?.dueDate else { throw StudyError.missingRecord }
        store.clock = { due }
        try store.reload()
        store.showingReview = true
    }
    @MainActor static func populateScale(_ repository: StudyRepository, now: Date) throws {
        guard try repository.notes().isEmpty else { return }
        let base = now.addingTimeInterval(-300 * 86400), scheduler = try ReviewScheduler()
        let fresh = try JSONEncoder().encode(scheduler.newCard(now: base)), deck = try repository.decks()[0].id
        try repository.transaction {
            var cards: [StudyCard] = []
            for index in 0..<1000 {
                let input = NoteInput(deckID: deck, kind: .cloze, question: "Scale \(index) {{c1::one}} {{c2::two}} {{c3::three}}")
                let note = Note(input: input, content: try JSONEncoder().encode(TextContent(question: input.question, answer: "", explanation: "")), now: base)
                repository.context.insert(note)
                for variant in 1...3 {
                    let card = StudyCard(noteID: note.id, variantKey: "cloze:\(variant)", payload: fresh, now: base)
                    repository.context.insert(card); cards.append(card)
                }
            }
            for index in 0..<10000 {
                let card = cards[index % cards.count], date = base.addingTimeInterval(Double(index) * 60)
                let before = try repository.snapshot(card), wasNew = try scheduler.summary(before).state == "new"
                let transition = try scheduler.review(before, grade: .easy, now: date)
                let after = try JSONEncoder().encode(transition.after)
                repository.context.insert(StudyReviewLog(card: card, transition: transition, before: card.fsrsPayload, after: after,
                                                         mode: .mental, durationMs: 1000, wasNew: wasNew, sequence: index + 1))
                card.fsrsPayload = after; card.dueDate = try scheduler.summary(transition.after).dueDate; card.updatedAt = date
            }
        }
    }
    @MainActor static func populateDueNotification(_ repository: StudyRepository, now: Date) throws {
        guard try repository.notes().isEmpty else { return }
        let base = now.addingTimeInterval(-7200)
        try repository.createNote(NoteInput(deckID: repository.decks()[0].id, question: "通知の実機確認", answer: "通知からホームへ戻る"), now: base)
        try repository.start(mode: .new, now: base)
        try repository.updateDraft(revealed: true, now: base)
        try repository.grade(.again, now: base)
        try repository.setSessionActive(false, now: base)
        try repository.completeSession(now: base)
        var settings = try repository.settings()
        let parts = Calendar.current.dateComponents([.hour, .minute], from: now.addingTimeInterval(180))
        settings.notification.hour = parts.hour ?? 20
        settings.notification.minute = parts.minute ?? 0
        settings.notification.enabled = false
        try repository.updateSettings(settings)
    }
    @MainActor static func populateOrdering(_ repository: StudyRepository, now: Date) throws {
        guard try repository.notes().isEmpty else { return }
        try repository.createNote(NoteInput(deckID: repository.decks()[0].id, question: "私は毎日学校へ歩きます。",
                                            answer: "I walk to school every day.", explanation: "現在の習慣を表す英文です。",
                                            hint: "主語は I、動詞は walk", responseMode: .ordering), now: now)
    }
    @MainActor static func populateHints(_ repository: StudyRepository, now: Date) throws {
        guard try repository.notes().isEmpty else { return }
        let deck = try repository.decks()[0].id
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }.pngData()!
        let image = try repository.addImage(bytes, now: now)
        for kind in NoteKind.allCases {
            var input = NoteInput(deckID: deck, kind: kind,
                                  question: kind == .cloze ? "{{c1::Tokyo::city}} and {{c2::Japan}}" : "Hint \(kind.rawValue)",
                                  answer: "Reverse question", hint: "Shared \(kind.rawValue) hint", reverseEnabled: kind == .basic)
            if kind == .imageOcclusion {
                input.imageID = image
                input.masks = [ImageMask(rect: MaskRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), answer: "one"),
                               ImageMask(rect: MaskRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), answer: "two")]
            }
            try repository.createNote(input, now: now)
        }
        var settings = try repository.settings(); settings.siblingBuryEnabled = false
        try repository.updateSettings(settings)
    }
    @MainActor static func populateHomeFilters(_ repository: StudyRepository, now: Date) throws {
        guard try repository.notes().isEmpty else { return }
        let root = try repository.decks()[0].id
        let child = try repository.createDeck(name: "Child", parentID: root, now: now)
        let other = try repository.createDeck(name: "Other", now: now)
        try repository.createNote(NoteInput(deckID: child, question: "Both tags", answer: "A", tagNames: ["A", "B"]), now: now)
        try repository.createNote(NoteInput(deckID: child, question: "Only A", answer: "A", tagNames: ["A"]), now: now)
        try repository.createNote(NoteInput(deckID: other, question: "Other card", answer: "A", tagNames: ["A", "B"]), now: now)
    }
    @MainActor static func populateMask(_ repository: StudyRepository, now: Date) throws {
        guard try repository.notes().isEmpty else { return }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        let imageID = try repository.addImage(image.pngData()!, now: now)
        let deckID = try repository.decks()[0].id
        let input = NoteInput(deckID: deckID, kind: .imageOcclusion,
                              question: "Numeric mask fixture", imageID: imageID,
                              masks: [ImageMask(rect: MaskRect(x: 0.25, y: 0.25, width: 0.5, height: 0.25))])
        try repository.createNote(input, now: now)
    }
    static func silentAudio() -> Data {
        var bytes = Data()
        func text(_ s: String) { bytes.append(contentsOf: s.utf8) }
        func number<T: FixedWidthInteger>(_ n: T) { var little = n.littleEndian; withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) } }
        text("RIFF"); number(UInt32(160036)); text("WAVEfmt "); number(UInt32(16))
        number(UInt16(1)); number(UInt16(1)); number(UInt32(8000)); number(UInt32(16000))
        number(UInt16(2)); number(UInt16(16)); text("data"); number(UInt32(160000))
        bytes.append(Data(count: 160000)); return bytes
    }
    static func ankiFixture(script: Bool = false) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AnkiFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("collection.anki2")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw StudyError.invalidContent }
        defer { sqlite3_close(db) }
        func exec(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StudyError.invalidContent } }
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
        try exec("CREATE TABLE col(id INTEGER PRIMARY KEY,ver INTEGER,models TEXT,decks TEXT)")
        try exec("CREATE TABLE notes(id INTEGER PRIMARY KEY,mid INTEGER,flds TEXT,tags TEXT)")
        try exec("CREATE TABLE cards(id INTEGER PRIMARY KEY,nid INTEGER,did INTEGER,ord INTEGER,reps INTEGER)")
        try exec("CREATE TABLE revlog(id INTEGER PRIMARY KEY,cid INTEGER)")
        let model: (Int, Bool) -> [String: Any] = { type, reverse in
            let first = type == 1 ? "Text" : "Front", second = type == 1 ? "Extra" : "Back"
            let q = type == 1 ? "{{cloze:Text}}" : "{{Front}}"
            let a = type == 1 ? "{{cloze:Text}}<br>{{Extra}}" : "{{FrontSide}}<hr id=answer>{{Back}}"
            var templates: [[String: Any]] = [["ord": 0, "qfmt": q, "afmt": a]]
            if reverse { templates.append(["ord": 1, "qfmt": "{{Back}}", "afmt": "{{FrontSide}}<hr>{{Front}}"] ) }
            return ["type": type, "flds": [["ord": 0, "name": first], ["ord": 1, "name": second]], "tmpls": templates]
        }
        var custom = model(0, false); custom["flds"] = [["ord": 0, "name": "Front"], ["ord": 1, "name": "Back"], ["ord": 2, "name": "More"]]
        let models = try JSONSerialization.data(withJSONObject: ["100": model(0, false), "200": model(0, true), "300": model(1, false), "400": custom])
        let decks = try JSONSerialization.data(withJSONObject: ["1": ["name": "Default::Child"]])
        try exec("INSERT INTO col VALUES(1,11,\(quote(String(decoding: models, as: UTF8.self))),\(quote(String(decoding: decks, as: UTF8.self))))")
        let fields: [(Int, Int, String, [Int])] = [
            (1001, 100, "Anki&nbsp;question<br><img src=\"fixture.png\">[sound:q.wav]\u{1f}Anki answer[sound:a.wav]", [0]),
            (1002, 200, "Reverse front\u{1f}Reverse back", [0, 1]),
            (1003, 300, "{{c1::red}} and {{c2::blue::color}}\u{1f}Extra explanation", [0, 1]),
            (1004, 100, "<script>alert(1)</script>\u{1f}Unsafe", [0]),
            (1005, 400, "Custom front\u{1f}Custom back\u{1f}More", [0])]
        for (id, model, value, ordinals) in fields {
            try exec("INSERT INTO notes VALUES(\(id),\(model),\(quote(value)), ' fixture English ')")
            for ordinal in ordinals { try exec("INSERT INTO cards VALUES(\(id * 10 + ordinal),\(id),1,\(ordinal),3)") }
        }
        try exec("INSERT INTO revlog VALUES(1,10010)")
        if script { try exec("CREATE VIEW sneaky AS SELECT * FROM notes") }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }.pngData()!
        let media = try JSONEncoder().encode(["0": "fixture.png", "1": "q.wav", "2": "a.wav"])
        return try StoredZIP.write(["collection.anki2": Data(contentsOf: url), "media": media, "0": image, "1": silentAudio(), "2": silentAudio()])
    }
    static func prepare(name: String) throws {
        guard UUID(uuidString: name) != nil else { throw StudyError.invalidContent }
        let documents = URL.documentsDirectory
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let deckID = UUID(), noteID = UUID(), audioID = UUID(), audio = silentAudio()
        let content = TextContent(question: "Shared audio question", answer: "Shared audio answer", explanation: "", reverseEnabled: true, questionAudioID: audioID, answerAudioID: audioID)
        let package = DeckPackage(rootID: deckID, decks: [SharedDeck(id: deckID, name: "共有サンプル", parentID: nil)],
            notes: [SharedNote(id: noteID, deckID: deckID, kind: .basic, content: content, responseMode: .mental, tags: ["共有タグ"])],
            media: [SharedMedia(id: audioID, mediaType: "audio/wav", width: 0, height: 0, sha256: BackupArchive.hash(audio))])
        try ankiFixture().write(to: documents.appendingPathComponent("Anki-\(name).apkg"), options: .atomic)
        try DeckExchange.encode(package, bytes: [audioID: audio]).write(to: documents.appendingPathComponent("Deck-\(name).studydeck"), options: .atomic)
        try silentAudio().write(to: documents.appendingPathComponent("Audio-\(name).wav"), options: .atomic)
        try Data("question,answer\nCSV file question,CSV file answer\n".utf8)
            .write(to: documents.appendingPathComponent("UITest-\(name).csv"), options: .atomic)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80), format: format).image { context in
            UIColor.systemBlue.setStroke(); context.cgContext.setLineWidth(2)
            context.cgContext.strokeEllipse(in: CGRect(x: 10, y: 10, width: 60, height: 60))
        }.pngData()!
        let csv = "question,answer,image,tags,deck\n" + (0..<100).map { ",ZIP answer \($0),images/symbol.png,地図記号,社会/地理" }.joined(separator: "\n")
        try StoredZIP.write(["cards.csv": Data(csv.utf8), "images/symbol.png": image])
            .write(to: documents.appendingPathComponent("Images-\(name).zip"), options: .atomic)
        try Data("invalid ZIP fixture".utf8)
            .write(to: documents.appendingPathComponent("Invalid-\(name).studybackup"), options: .atomic)
    }
}
#endif
