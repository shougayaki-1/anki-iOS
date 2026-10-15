#if DEBUG
import Foundation
import UIKit
import SwiftData
import SQLite3

// Only explicit UI-test launch arguments create fixtures, in the app's sandbox.
enum UITestFixtures {
    static func deckUpdatePreview() -> ValidatedDeckPackage? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-study-test-deck-update"), let index = args.firstIndex(of: "-study-test-store"),
              args.count > index + 1, UUID(uuidString: args[index + 1]) != nil else { return nil }
        let mode = args.contains("-study-test-deck-update-reset") ? "Reset" : "Keep"
        let file = URL.documentsDirectory.appendingPathComponent("Update-\(mode)-\(args[index + 1]).studydeck")
        return try? DeckExchange.decode(Data(contentsOf: file))
    }

    @MainActor static func populateDeckUpdate(_ store: StudyStore, name: String) throws {
        let repo = store.repository, now = store.clock()
        guard try repo.notes().isEmpty else { return }
        let deck = try repo.decks()[0].id
        func image(_ title: String, color: UIColor) -> Data {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: 240, height: 100), format: format).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 240, height: 100))
                title.draw(at: CGPoint(x: 24, y: 32), withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.white])
            }.pngData()!
        }
        let oldImage = try repo.addImage(image("東京", color: .systemIndigo), now: now)
        let replacementID = UUID(), replacementBytes = image("東京都", color: .systemTeal)
        try repo.createNote(NoteInput(deckID: deck, question: "日本の首都は？", answer: "東京", hint: "関東地方", tagNames: ["地理"], imageID: oldImage), now: now)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(revealed: true, now: now)
        try repo.grade(.good, now: now.addingTimeInterval(3))
        try repo.transaction { if let draft = try repo.session() { draft.cardID = nil; draft.undoLogID = nil } }
        let (original, urls) = try repo.captureDeckPackage(rootID: deck)
        let originalBytes = try urls.mapValues { try Data(contentsOf: $0) }
        for reset in [false, true] {
            let notes = original.notes.map { note -> SharedNote in
                var content = note.content
                content.hint = "日本の政治・行政の中心"
                if reset { content.answer = "東京都（日本の首都）"; content.imageID = replacementID }
                return SharedNote(id: note.id, deckID: note.deckID, kind: note.kind, content: content,
                    responseMode: note.responseMode, tags: ["地理", "日本"])
            }
            let media = reset ? [SharedMedia(id: replacementID, mediaType: "image/png", width: 240, height: 100,
                sha256: BackupArchive.hash(replacementBytes))] : original.media
            let package = DeckPackage(rootID: deck, decks: original.decks, notes: notes, media: media)
            let file = URL.documentsDirectory.appendingPathComponent("Update-\(reset ? "Reset" : "Keep")-\(name).studydeck")
            try DeckExchange.encode(package, bytes: reset ? [replacementID: replacementBytes] : originalBytes).write(to: file, options: .atomic)
        }
        try store.reload()
    }

    @MainActor static func populateGarden(_ store: StudyStore, scenario: String) throws {
        let repo = store.repository, now = store.clock()
        guard try repo.notes().isEmpty else { return }
        let deck = try repo.decks()[0].id, scheduler = try ReviewScheduler()
        let past = now.addingTimeInterval(-60 * 86400)
        let seed = try scheduler.newCard(now: past)
        let sprout = try scheduler.review(seed, grade: .good, now: past).after
        let plant = try scheduler.review(seed, grade: .easy, now: past).after
        let flower = try scheduler.review(plant, grade: .easy, now: now.addingTimeInterval(-30 * 86400)).after
        let amounts = scenario == "growth" ? [1, 0, 0, 0] : scenario == "empty" ? [0, 0, 0, 0] : scenario == "mature" ? [2, 2, 4, 32] : scenario == "scale" ? [600, 600, 900, 900] : [8, 8, 12, 12]
        let snapshots = [seed, sprout, plant, flower]
        try repo.transaction {
            for stage in GardenStage.allCases {
                let payload = try JSONEncoder().encode(snapshots[stage.rawValue])
                for index in 0..<amounts[stage.rawValue] {
                    let input = NoteInput(deckID: deck, question: "\(stage.title)の記憶 \(index + 1)", answer: "学習サンプル", tagNames: [])
                    let note = Note(input: input, content: try JSONEncoder().encode(TextContent(question: input.question, answer: input.answer, explanation: "")), now: past)
                    repo.context.insert(note)
                    let card = StudyCard(noteID: note.id, variantKey: "basic:front", payload: payload, now: past)
                    card.dueDate = now; repo.context.insert(card)
                }
            }
        }
        try store.reload()
    }

    @MainActor static func populateDashboard(_ store: StudyStore) throws {
        let repo = store.repository, now = store.clock()
        guard try repo.notes().isEmpty else { return }
        let root = try repo.createDeck(name: "英語", now: now)
        let child = try repo.createDeck(name: "日常のことば", parentID: root, now: now)
        let other = try repo.createDeck(name: "読書", now: now)
        for index in 0..<90 {
            try repo.createNote(NoteInput(deckID: index < 65 ? child : other,
                question: "記憶のサンプル \(index + 1)", answer: "意味と使い方", tagNames: index.isMultiple(of: 2) ? ["日常", "重点"] : ["日常"]), now: now)
        }
        let scheduler = try ReviewScheduler()
        try repo.transaction {
            var sequence = 0
            for (index, card) in try repo.cards().enumerated() where index < 72 {
                for offset in stride(from: 110 - index % 5, through: index % 8, by: -7) {
                    let date = Calendar.current.date(byAdding: .day, value: -offset, to: now)!.addingTimeInterval(-1800)
                    let before = try repo.snapshot(card)
                    let grade: ReviewGrade = index % 11 == 0 ? .again : index % 7 == 0 ? .hard : index % 3 == 0 ? .easy : .good
                    let transition = try scheduler.review(before, grade: grade, now: date)
                    let payload = try JSONEncoder().encode(transition.after)
                    sequence += 1
                    repo.context.insert(StudyReviewLog(card: card, transition: transition, before: card.fsrsPayload, after: payload,
                        mode: .mental, durationMs: 12000 + index * 200, wasNew: try scheduler.summary(before).state == "new", sequence: sequence))
                    card.fsrsPayload = payload
                }
                card.dueDate = Calendar.current.date(byAdding: .day, value: index % 24 - 3, to: now)!
            }
        }
        var settings = try repo.settings(); settings.dailyGoal = 20
        try repo.updateSettings(settings)
        try store.reload()
    }

    @MainActor static func populateCelebrationFlow(_ store: StudyStore) throws {
        guard try store.repository.notes().isEmpty else { return }
        let deck = try store.repository.decks()[0].id
        for index in 1...4 {
            try store.repository.createNote(NoteInput(deckID: deck, question: "セレブレーション確認 \(index)", answer: "回答 \(index)"), now: store.clock())
        }
        var settings = try store.repository.settings(); settings.dailyGoal = 3
        try store.repository.updateSettings(settings)
        try store.reload()
    }

    @MainActor static func celebration(_ scenario: String) -> CelebrationSummary {
        let now = Date()
        func event(_ kind: AchievementKind, _ value: Int, threshold: Int = 1) -> AchievementEvent {
            AchievementEvent(record: AchievementRecord(id: UUID().uuidString, kind: kind,
                studyDay: AchievementProgress.dayKey(now, calendar: .current, startHour: 4),
                threshold: threshold, value: value, occurredAt: now, sourceLogID: UUID(),
                timeZoneID: TimeZone.current.identifier, startHour: 4))
        }
        let events: [AchievementEvent]
        switch scenario {
        case "normal": events = [event(.streakAdvanced, 12)]
        case "milestone": events = [event(.streakAdvanced, 7)]
        case "goal": events = [event(.dailyGoalReached, 20, threshold: 20)]
        case "mature": events = [event(.matureMilestone, 100, threshold: 100)]
        case "multiple": events = [event(.firstStudyToday, 1), event(.streakAdvanced, 7), event(.dailyGoalReached, 20, threshold: 20)]
        default: events = [event(.firstStudyToday, 1)]
        }
        let days = (-6...0).map { offset in
            let date = Calendar.current.date(byAdding: .day, value: offset, to: now)!
            return CelebrationDay(date: date, studied: true, label: String(Calendar.current.component(.day, from: date)))
        }
        return CelebrationSummary(events: events, days: days)!
    }

    @MainActor static func configureAccessibilityScene(largeText: Bool = true) {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            if largeText { scene.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge }
            scene.traitOverrides.userInterfaceStyle = .dark
        }
    }
    @MainActor static func populateLibraryTree(_ repository: StudyRepository, now: Date) throws {
        guard try repository.notes().isEmpty else { return }
        let root = try repository.createDeck(name: "Tree English", now: now)
        let child = try repository.createDeck(name: "Tree Draft", parentID: root, now: now)
        let leaf = try repository.createDeck(name: "Tree Lesson", parentID: child, now: now)
        try repository.createNote(NoteInput(deckID: root, question: "Tree parent question", answer: "Parent"), now: now)
        try repository.createNote(NoteInput(deckID: leaf, question: "Tree leaf question", answer: "Leaf"), now: now)
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
    @MainActor static func populateCustomMedia(_ repository: StudyRepository, now: Date) throws {
        guard try repository.notes().isEmpty else { return }
        let audio = try repository.addAudio(AudioEncodingPolicy.prepare(silentAudio()), now: now)
        try repository.createNote(NoteInput(deckID: repository.decks()[0].id,
            question: "縦書きの問題", answer: "縦書きの解答",
            questionAudioID: audio, answerAudioID: audio,
            questionLayout: .vertical, answerLayout: .vertical), now: now)
    }
    @MainActor static func populateCustomScale(_ repository: StudyRepository, now: Date) throws {
        guard try repository.notes().isEmpty else { return }
        try populateScale(repository, now: now, basic: true)
        let cards = try repository.cards(), scheduler = try ReviewScheduler()
        let day = StudyDay(calendar: repository.calendar, startHour: try repository.settings().dayStartHour).interval(containing: now)
        let step = now.timeIntervalSince(day.start) / 10_000
        try repository.transaction {
            for index in 0..<10_000 {
                let card = cards[index % cards.count], date = day.start.addingTimeInterval(Double(index) * step)
                let before = try repository.snapshot(card), wasNew = try scheduler.summary(before).state == "new"
                let transition = try scheduler.review(before, grade: .good, now: date)
                let after = try JSONEncoder().encode(transition.after)
                repository.context.insert(StudyReviewLog(card: card, transition: transition, before: card.fsrsPayload, after: after,
                    mode: .mental, durationMs: 1000, wasNew: wasNew, sequence: index + 1))
                card.fsrsPayload = after; card.dueDate = try scheduler.summary(transition.after).dueDate
            }
        }
    }

    @MainActor static func populateScale(_ repository: StudyRepository, now: Date, basic: Bool = false, multipleDecks: Bool = false) throws {
        guard try repository.notes().isEmpty else { return }
        let base = now.addingTimeInterval(-300 * 86400), scheduler = try ReviewScheduler()
        let fresh = try JSONEncoder().encode(scheduler.newCard(now: base)), deck = try repository.decks()[0].id
        try repository.transaction {
            var cards: [StudyCard] = []
            let decks = [deck] + (1..<(multipleDecks ? 20 : 1)).map { _ in UUID() }
            for (index, id) in decks.dropFirst().enumerated() {
                let model = Deck(name: "Scale deck \(index + 1)", now: base); model.id = id; repository.context.insert(model)
            }
            for index in 0..<(basic ? 3000 : 1000) {
                let input = NoteInput(deckID: decks[index % decks.count], kind: basic ? .basic : .cloze,
                    question: basic ? "Scale \(index)" : "Scale \(index) {{c1::one}} {{c2::two}} {{c3::three}}", answer: basic ? "Answer" : "")
                let note = Note(input: input, content: try JSONEncoder().encode(TextContent(question: input.question, answer: input.answer, explanation: "")), now: base)
                repository.context.insert(note)
                for variant in 1...(basic ? 1 : 3) {
                    let card = StudyCard(noteID: note.id, variantKey: basic ? "basic:front" : "cloze:\(variant)", payload: fresh, now: base)
                    repository.context.insert(card); cards.append(card)
                }
            }
            for index in 0..<(basic ? 0 : 10000) {
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
    @MainActor static func populateHomeRecommendation(_ store: StudyStore, scenario: String) throws {
        let repository = store.repository, now = store.clock()
        guard try repository.notes().isEmpty else { return }
        let count = scenario == "many" ? 200 : (scenario == "five" ? 5 : 1)
        let deck = try repository.decks()[0].id
        for index in 0..<count {
            try repository.createNote(NoteInput(deckID: deck, question: "今日の復習 \(index + 1)", answer: "回答"), now: now)
        }
        let scheduler = try ReviewScheduler()
        let past = now.addingTimeInterval(-864000)
        let transition = try scheduler.review(scheduler.newCard(now: past), grade: .easy, now: past)
        let payload = try JSONEncoder().encode(transition.after)
        try repository.transaction {
            for card in try repository.cards() {
                card.fsrsPayload = payload
                card.dueDate = scenario == "empty" ? now.addingTimeInterval(86400) : now.addingTimeInterval(-60)
            }
            if let card = try repository.cards().first {
                for sequence in 1...5 {
                    let log = StudyReviewLog(card: card, transition: transition, before: payload, after: payload,
                        mode: .mental, durationMs: 24000, wasNew: false, sequence: sequence)
                    log.reviewedAt = now.addingTimeInterval(-86400)
                    repository.context.insert(log)
                }
            }
        }
        if scenario == "resume" {
            try repository.start(mode: .review, now: now)
            try repository.updateDraft(text: "保持される下書き", now: now)
        }
        try store.reload()
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
    @MainActor static func populateTagFilters(_ repository: StudyRepository, now: Date) throws {
        guard try repository.notes().isEmpty else { return }
        try populateHomeFilters(repository, now: now)
        guard let other = try repository.decks().first(where: { $0.name == "Other" }) else { throw StudyError.missingRecord }
        try repository.createNote(NoteInput(deckID: other.id, question: "Outside tag", answer: "Answer", tagNames: ["他分野"]), now: now)
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

import Foundation
#if DEBUG
import os
#endif

// Constant interval names only. Available solely for an explicit isolated profiling run.
enum PerformanceProbe {
    struct Interval {
        #if DEBUG
        let name: StaticString
        let state: OSSignpostIntervalState
        #endif
    }
    #if DEBUG
    private static let signposter = OSSignposter(subsystem: "dev.shoug.AnkiIOS", category: "Performance")
    private static let enabled: Bool = {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-study-performance"), let index = args.firstIndex(of: "-study-test-store"),
              args.count > index + 1, UUID(uuidString: args[index + 1]) != nil else { return false }
        return true
    }()
    #endif
    @inline(__always) static func begin(_ name: StaticString) -> Interval? {
        #if DEBUG
        guard enabled else { return nil }
        return Interval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()))
        #else
        return nil
        #endif
    }
    @inline(__always) static func end(_ interval: Interval?) {
        #if DEBUG
        if let interval { signposter.endInterval(interval.name, interval.state) }
        #endif
    }
    static func counters(_ name: StaticString, projections: Int, notes: Int, cardRows: Int, history: Int, answerTimes: Int, decodes: Int) {
        #if DEBUG
        guard enabled else { return }
        signposter.emitEvent(name, "projections=\(projections) noteFetches=\(notes) cardRows=\(cardRows) historyFetches=\(history) answerTimeFetches=\(answerTimes) fsrsDecodes=\(decodes)")
        #endif
    }
}

#if DEBUG
import Combine

// Enabled only for isolated profiling launches. Samples the UI's frame callback
// gap from detail onAppear through the first frame after report publication.
@MainActor
final class ExamPlanFrameProbe: NSObject, ObservableObject {
    static let shared = ExamPlanFrameProbe()
    @Published private(set) var measurement: String?
    private var link: CADisplayLink?
    private var started = 0.0
    private var previous = 0.0
    private var maximumGap = 0.0
    private var frames = 0
    private var completed: ExamPlanLoad?
    private var publicationSeconds = 0.0
    private var enabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-study-performance"), let index = args.firstIndex(of: "-study-test-store"), args.count > index + 1 else { return false }
        return UUID(uuidString: args[index + 1]) != nil
    }
    func begin() {
        guard enabled, link == nil else { return }
        measurement = nil; completed = nil; maximumGap = 0; frames = 0
        started = ProcessInfo.processInfo.systemUptime; previous = started
        let displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink.add(to: .main, forMode: .common); link = displayLink
    }
    func finish(_ value: ExamPlanLoad) {
        guard link != nil else { return }
        completed = value; publicationSeconds = ProcessInfo.processInfo.systemUptime - started
    }
    func cancel() { link?.invalidate(); link = nil; completed = nil }
    @objc private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        maximumGap = max(maximumGap, now - previous); previous = now; frames += 1
        guard let value = completed else { return }
        let text = String(format: "EXAM_PLAN cards=%d logs=%d capture_ms=%.2f calculate_ms=%.2f main_frame_max_gap_ms=%.2f publication_ms=%.2f frames=%d",
                          value.cardCount, value.logCount, value.captureSeconds * 1000, value.calculationSeconds * 1000,
                          maximumGap * 1000, publicationSeconds * 1000, frames)
        cancel(); measurement = text; print(text)
    }
}
#endif
