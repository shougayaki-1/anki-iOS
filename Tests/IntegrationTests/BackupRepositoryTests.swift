import XCTest
import UIKit
import SwiftData
@testable import AnkiIOS

@MainActor
final class BackupRepositoryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    enum Failure: Error { case save }
    func fixture(_ root: URL) throws -> StudyRepository {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: root.appendingPathComponent("Study.store")), mediaStore: MediaStore(root: root.appendingPathComponent("Media")))
        try repo.initialize(now: now)
        return repo
    }
    func populate(_ repo: StudyRepository) throws {
        let deck = try repo.createDeck(name: "子デッキ", parentID: repo.decks()[0].id, now: now)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }.pngData()!
        let image = try repo.addImage(bytes, now: now)
        for kind in NoteKind.allCases {
            var input = NoteInput(deckID: deck, kind: kind, question: kind == .cloze ? "{{c1::東京}}と{{c2::京都}}" : "問題", answer: "答え", hint: "共通の手がかり\n二行目", responseMode: .typing, tagNames: ["日本"], reverseEnabled: kind == .basic)
            if kind == .imageOcclusion {
                input.imageID = image
                input.masks = [ImageMask(rect: MaskRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2), answer: "赤")]
            }
            try repo.createNote(input, now: now)
        }
        for grade in ReviewGrade.allCases {
            try repo.start(mode: .new, now: now)
            try repo.updateDraft(revealed: true, now: now)
            try repo.grade(grade, now: now.addingTimeInterval(2))
        }
        try repo.updateDraft(mode: .typing, text: "未確定の回答", now: now)
        try repo.saveEditorDraft(key: "new", input: NoteInput(deckID: deck, question: "下書き", hint: "下書きヒント", imageID: image), now: now)
        var options = try repo.settings(); options.dailyNewLimit = 500; options.dailyGoal = 1; options.dayStartHour = 23; options.desiredRetention = 0.97; options.notification.enabled = true; options.hapticsMode = .rich
        options.reviewAppearance = ReviewAppearance(gesturesEnabled: true, textSize: .extraLarge, imageDisplay: .hidden, answerFirst: true, animationsEnabled: false)
        let homeScope = LearningScope(deckID: deck, tagIDs: try repo.tags().map(\.id))
        try repo.applyHomeScope(homeScope)
        try repo.updateSettings(options)
        XCTAssertEqual(try repo.homeScope(), homeScope)
        try repo.applyHomeScope(LearningScope())
        XCTAssertEqual(try repo.settings().reviewAppearance, options.reviewAppearance)
        try repo.applyHomeScope(homeScope)
        try repo.transaction {
            repo.context.insert(ImportBatch(source: "CSV", now: now, success: 4, skipped: 1, errors: ["行エラー"]))
            try repo.setScopeInTransaction(LearningScope(deckID: deck, tagIDs: repo.tags().map(\.id)))
        }
    }
    func testFullBackupRestoresAllModelsMediaAndUndoAfterReopening() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root.appendingPathComponent("source")); try populate(source)
        let bytes = try await BackupService.export(repository: source, now: now, appVersion: "test")
        let backup = try BackupArchive.decode(bytes)
        let destinationRoot = root.appendingPathComponent("destination")
        let original = try fixture(destinationRoot)
        try original.createNote(NoteInput(deckID: original.decks()[0].id, question: "置換前", answer: "元データ"), now: now)
        let location = StudyStorageLocation(canonicalStore: destinationRoot.appendingPathComponent("Study.store"))
        _ = try BackupService.restore(backup, location: location, mediaStore: original.mediaStore, now: now)
        let reopened = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: location.canonicalStore), mediaStore: original.mediaStore)
        var expected = backup.data.canonical(), actual = try BackupData.capture(reopened).canonical()
        for index in expected.sessions.indices { expected.sessions[index].activeSince = nil }
        for index in actual.media.indices {
            let asset = actual.media[index]
            XCTAssertEqual(try Data(contentsOf: reopened.assetURL(id: asset.id)), backup.media[asset.id])
            actual.media[index].relativePath = expected.media[index].relativePath
        }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(try reopened.homeScope(), try source.homeScope())
        XCTAssertEqual(try reopened.scope(), try source.scope())
        XCTAssertEqual(try reopened.settings().hapticsMode, .rich)
        XCTAssertEqual(try reopened.settings().reviewAppearance, try source.settings().reviewAppearance)
        XCTAssertEqual(try reopened.session()?.typedDraft, "未確定の回答")
        XCTAssertTrue(try reopened.noteItems().allSatisfy { $0.sourceContent.hint == "共通の手がかり\n二行目" })
        XCTAssertEqual(try reopened.editorDraft(key: "new")?.hint, "下書きヒント")
        let previous = try XCTUnwrap(reopened.logs().last)
        let cardID = previous.cardID, before = previous.fsrsBefore
        try reopened.undo(now: now.addingTimeInterval(10))
        XCTAssertEqual(try reopened.logs().count, 3)
        XCTAssertEqual(try reopened.cards().first(where: { $0.id == cardID })?.fsrsPayload, before)
        XCTAssertEqual(try original.notes().count, 1) // Original store remains intact.
    }
    func testLegacyBackupWithoutHintKeysRestoresNotesAndEditorDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root.appendingPathComponent("source")); try populate(source)
        let current = try BackupArchive.decode(await BackupService.export(repository: source, now: now, appVersion: "test"))
        var legacy = current.data
        func withoutHint(_ data: Data) throws -> Data {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            json.removeValue(forKey: "hint")
            return try JSONSerialization.data(withJSONObject: json)
        }
        for index in legacy.notes.indices { legacy.notes[index].contentPayload = try withoutHint(legacy.notes[index].contentPayload) }
        for index in legacy.editorDrafts.indices { legacy.editorDrafts[index].payload = try withoutHint(legacy.editorDrafts[index].payload) }
        let backup = try BackupArchive.decode(BackupArchive.create(data: legacy, media: current.media, now: now, appVersion: "legacy"))
        let destination = try fixture(root.appendingPathComponent("destination"))
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("destination/Study.store"))
        _ = try BackupService.restore(backup, location: location, mediaStore: destination.mediaStore, now: now)
        let reopened = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: location.canonicalStore), mediaStore: destination.mediaStore)
        XCTAssertTrue(try reopened.noteItems().allSatisfy { $0.sourceContent.hint == nil })
        XCTAssertNil(try reopened.editorDraft(key: "new")?.hint)
        XCTAssertEqual(Set(try reopened.cards().map(\.id)), Set(try source.cards().map(\.id)))
        XCTAssertEqual(try reopened.logs().map(\.id), try source.logs().map(\.id))
    }
    func testFailedStagedSavePreservesActivePointerAndOriginalData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try fixture(root); try populate(repo)
        let backup = try BackupArchive.decode(await BackupService.export(repository: repo, now: now, appVersion: "test"))
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("Study.store"))
        _ = try BackupService.restore(backup, location: location, mediaStore: repo.mediaStore, now: now)
        let pointer = try Data(contentsOf: location.pointer), active = try location.activeStore()
        let before = try BackupData.capture(repo)
        XCTAssertThrowsError(try BackupService.restore(backup, location: location, mediaStore: repo.mediaStore, now: now, save: { _ in throw Failure.save }))
        XCTAssertEqual(try Data(contentsOf: location.pointer), pointer)
        XCTAssertEqual(try location.activeStore(), active)
        XCTAssertEqual(try BackupData.capture(repo), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Restores"), includingPropertiesForKeys: nil).count, 1)
    }
    func testRehashedMalformedDataIsRejectedBeforeRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try fixture(root); try populate(repo)
        let bytes = try await BackupService.export(repository: repo, now: now, appVersion: "test")
        let original = try BackupArchive.decode(bytes)
        var mutations: [BackupData] = []
        var duplicate = original.data; duplicate.cards.append(duplicate.cards[0]); mutations.append(duplicate)
        var cycle = original.data; cycle.decks[0].parentID = cycle.decks[0].id; mutations.append(cycle)
        var invalidFSRS = original.data; invalidFSRS.cards[0].fsrsPayload = Data("{}".utf8); mutations.append(invalidFSRS)
        var missingMedia = original.data; missingMedia.media = []; mutations.append(missingMedia)
        var invalidAppearance = original.data
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: invalidAppearance.options[0].payload) as? [String: Any])
        var appearance = try XCTUnwrap(payload["reviewAppearance"] as? [String: Any])
        appearance["textSize"] = "unsupported"; payload["reviewAppearance"] = appearance
        invalidAppearance.options[0].payload = try JSONSerialization.data(withJSONObject: payload)
        mutations.append(invalidAppearance)
        for snapshot in mutations {
            var files = try StoredZIP.read(bytes)
            files["data.json"] = try JSONEncoder().encode(snapshot)
            files["manifest.json"] = try JSONEncoder().encode(BackupManifest(createdAt: now, appVersion: "test", files: files.filter { $0.key != "manifest.json" }.mapValues(BackupArchive.hash)))
            XCTAssertThrowsError(try BackupArchive.decode(StoredZIP.write(files)))
            XCTAssertThrowsError(try BackupService.restore(ValidatedBackup(data: snapshot, media: original.media, manifest: original.manifest), location: StudyStorageLocation(canonicalStore: root.appendingPathComponent("Study.store")), mediaStore: repo.mediaStore, now: now))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Study.active.json").path))
        XCTAssertEqual(try repo.logs().count, 4)
    }
    func testHistoricalDeletedCardsAndLegacyOptionsRemainValid() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try fixture(root)
        let note = try repo.createNote(NoteInput(deckID: repo.decks()[0].id, question: "Q", answer: "A"), now: now)
        try repo.start(mode: .new, now: now); try repo.updateDraft(revealed: true, now: now); try repo.grade(.good, now: now)
        try repo.deleteNote(id: note)
        repo.context.insert(try ExtraPreferences(options: StudyOptions(schemaVersion: 1)))
        try repo.context.save()
        let backup = try BackupArchive.decode(await BackupService.export(repository: repo, now: now, appVersion: "test"))
        XCTAssertEqual(backup.data.logs.count, 1); XCTAssertTrue(backup.data.cards.isEmpty)
        XCTAssertFalse(try repo.settings().notification.enabled)
        XCTAssertEqual(try repo.settings().hapticsMode, .standard)
        XCTAssertEqual(try repo.settings().reviewAppearance, ReviewAppearance())
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("Study.store"))
        try Data("{\"schemaVersion\":1,\"relativePath\":\"../outside.store\"}".utf8).write(to: location.pointer)
        XCTAssertThrowsError(try PersistenceController.makeStudyContainer(storeURL: location.canonicalStore))
        XCTAssertEqual(try repo.logs().count, 1)
    }
    func testLegacyJPEGAndNewPNGMixedBackupRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root.appendingPathComponent("source"))
        let canvas = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        let png = try XCTUnwrap(canvas.pngData())
        let jpg = try XCTUnwrap(canvas.jpegData(compressionQuality: 0.9))
        let a = try source.addImage(png, now: now)
        let b = try source.addImage(jpg, now: now)
        let deck = try XCTUnwrap(source.decks().first).id
        try source.saveEditorDraft(key: "new", input: NoteInput(deckID: deck, question: "PNG", imageID: a), now: now)
        try source.createNote(NoteInput(deckID: deck, question: "JPEG", answer: "A", imageID: b), now: now)
        let zip = try await BackupService.export(repository: source, now: now, appVersion: "test")
        let decoded = try BackupArchive.decode(zip)
        XCTAssertEqual(decoded.media[a], png)
        XCTAssertEqual(decoded.media[b], jpg)
        XCTAssertEqual(Set(decoded.data.media.map(\.mediaType)), Set(["image/png", "image/jpeg"]))
        let destination = try fixture(root.appendingPathComponent("destination"))
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("destination/Study.store"))
        _ = try BackupService.restore(decoded, location: location, mediaStore: destination.mediaStore, now: now)
        let reopened = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: location.canonicalStore), mediaStore: destination.mediaStore)
        XCTAssertEqual(try Data(contentsOf: reopened.assetURL(id: a)), png)
        XCTAssertEqual(try Data(contentsOf: reopened.assetURL(id: b)), jpg)
        XCTAssertTrue(try reopened.assets().contains { $0.relativePath.hasSuffix(".png") })
        XCTAssertTrue(try reopened.assets().contains { $0.relativePath.hasSuffix(".jpg") })
        try reopened.cleanupUnusedMedia()
        XCTAssertEqual(try Data(contentsOf: reopened.assetURL(id: a)), png)
        XCTAssertEqual(try Data(contentsOf: reopened.assetURL(id: b)), jpg)
    }
}

extension BackupRepositoryTests {
    func testAudioBackupRestoresBothFacesDraftAndUndoAndRejectsWrongMediaRole() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root.appendingPathComponent("source"))
        let prepared = try AudioEncodingPolicy.prepare(SpeechReadoutTests.silence())
        let audio = try source.addAudio(prepared, now: now)
        XCTAssertEqual(try source.addAudio(prepared, now: now), audio)
        var input = NoteInput(deckID: try source.decks()[0].id, question: "Question", answer: "Answer", reverseEnabled: true, questionAudioID: audio, answerAudioID: audio)
        let note = try source.createNote(input, now: now)
        try source.saveEditorDraft(key: "new", input: input, now: now)
        try source.start(mode: .new, now: now); try source.updateDraft(revealed: true, now: now)
        try source.grade(.good, now: now.addingTimeInterval(1))
        let before = try source.cards().map { ($0.id, $0.fsrsPayload) }
        let logs = try source.logs().map(\.id)
        input.answerAudioID = nil
        try source.updateNote(id: note, input: input, now: now.addingTimeInterval(2))
        XCTAssertEqual(try source.cards().map(\.id), before.map(\.0))
        XCTAssertEqual(try source.cards().map(\.fsrsPayload), before.map(\.1))
        XCTAssertEqual(try source.logs().map(\.id), logs)
        let backup = try BackupArchive.decode(await BackupService.export(repository: source, now: now, appVersion: "test"))
        XCTAssertEqual(backup.manifest.schemaVersion, 2)
        XCTAssertEqual(backup.media[audio], prepared.data)
        let destination = try fixture(root.appendingPathComponent("destination"))
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("destination/Study.store"))
        _ = try BackupService.restore(backup, location: location, mediaStore: destination.mediaStore, now: now)
        let reopened = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: location.canonicalStore), mediaStore: destination.mediaStore)
        XCTAssertEqual(try reopened.noteItems().first?.sourceContent.questionAudioID, audio)
        XCTAssertEqual(try reopened.editorDraft(key: "new")?.answerAudioID, audio)
        XCTAssertEqual(try Data(contentsOf: reopened.assetURL(id: audio)), prepared.data)
        try reopened.undo(now: now.addingTimeInterval(5))
        XCTAssertTrue(try reopened.logs().isEmpty)
        input.imageID = audio
        XCTAssertThrowsError(try source.updateNote(id: note, input: input, now: now))
        var files = try StoredZIP.read(await BackupService.export(repository: source, now: now, appVersion: "test"))
        var manifest = backup.manifest; manifest.schemaVersion = 1
        files["manifest.json"] = try JSONEncoder().encode(manifest)
        XCTAssertThrowsError(try BackupArchive.decode(StoredZIP.write(files)))
    }
}

extension BackupRepositoryTests {
    func testAudioDraftPreventsCleanupAndFailedSaveRemovesNewFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try fixture(root)
        let prepared = try AudioEncodingPolicy.prepare(SpeechReadoutTests.silence())
        let id = try repo.addAudio(prepared, now: now), url = try repo.assetURL(id: id)
        let input = NoteInput(deckID: try repo.decks()[0].id, question: "Q", answer: "A", questionAudioID: id)
        try repo.saveEditorDraft(key: "new", input: input, now: now)
        try repo.cleanupUnusedMedia(); XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try repo.discardEditorDraft(key: "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)); XCTAssertTrue(try repo.assets().isEmpty)
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.addAudio(prepared, now: now))
        XCTAssertTrue(try repo.assets().isEmpty)
        let folder = try repo.mediaStore.url(for: "audio")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}

extension BackupRepositoryTests {
    func testDeckExchangeExportsOnlySelectedContentAndImportsFreshCardsWithMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root.appendingPathComponent("source")); try populate(source)
        let child = try XCTUnwrap(source.decks().first(where: { $0.parentID != nil }))
        let audio = try source.addAudio(AudioEncodingPolicy.prepare(SpeechReadoutTests.silence()), now: now)
        let note = try XCTUnwrap(source.notes().first)
        try source.transaction {
            var content = try JSONDecoder().decode(TextContent.self, from: note.contentPayload)
            content.questionAudioID = audio; content.answerAudioID = audio; content.speechOverrides = ["basic:front": .both]
            note.contentPayload = try JSONEncoder().encode(content)
        }
        try source.createNote(NoteInput(deckID: source.decks()[0].id, question: "Private unrelated", answer: "Do not share"), now: now)
        let before = try BackupData.capture(source)
        let bytes = try await DeckExchange.export(repository: source, rootID: child.id)
        XCTAssertEqual(try BackupData.capture(source), before)
        let validated = try DeckExchange.decode(bytes)
        XCTAssertEqual(validated.package.notes.count, 4)
        XCTAssertEqual(validated.cardCount, 6)
        XCTAssertEqual(validated.package.decks.count, 1)
        XCTAssertNil(validated.package.decks[0].parentID)
        XCTAssertEqual(Set(validated.package.notes.map(\.kind)), Set(NoteKind.allCases))
        XCTAssertTrue(validated.package.notes.allSatisfy { $0.content.speechOverrides == nil })
        XCTAssertEqual(validated.bytes[audio], SpeechReadoutTests.silence())
        let files = try StoredZIP.read(bytes)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: files["deck.json"]!) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["schemaVersion", "rootID", "decks", "notes", "media"])
        XCTAssertNil(files["data.json"])
        let destination = try fixture(root.appendingPathComponent("destination"))
        try destination.createDeck(name: child.name, now: now)
        try destination.createNote(NoteInput(deckID: destination.decks()[0].id, question: "Existing", answer: "Keep"), now: now)
        try destination.start(mode: .new, now: now); try destination.updateDraft(revealed: true, now: now)
        try destination.grade(.good, now: now.addingTimeInterval(1))
        let savedLogs = try destination.logs().map(\.id), savedSettings = try destination.settings()
        let savedCard = try XCTUnwrap(destination.cards().first)
        let savedPayload = savedCard.fsrsPayload
        let preview = try destination.previewDeckImport(validated)
        XCTAssertTrue(preview.duplicates.isEmpty); XCTAssertEqual(preview.destinationName, "子デッキ（取込 2）")
        XCTAssertEqual(try destination.importDeckPackage(validated, skipDuplicates: true, now: now), 4)
        XCTAssertEqual(try destination.logs().map(\.id), savedLogs)
        XCTAssertEqual(try destination.settings(), savedSettings)
        XCTAssertEqual(savedCard.fsrsPayload, savedPayload)
        let imported = try destination.cards().filter { $0.id != savedCard.id }
        XCTAssertEqual(imported.count, 6)
        for card in imported {
            XCTAssertFalse(card.isSuspended)
            let summary = try ReviewScheduler().summary(JSONDecoder().decode(SchedulerSnapshot.self, from: card.fsrsPayload))
            XCTAssertEqual(summary.repetitions, 0)
        }
        let audioIDs = try destination.noteItems().flatMap { $0.sourceContent.audioIDs }
        XCTAssertFalse(audioIDs.isEmpty)
        XCTAssertFalse(audioIDs.contains(audio))
        for id in audioIDs { XCTAssertEqual(try Data(contentsOf: destination.assetURL(id: id)), validated.bytes[audio]) }
        let repeated = try destination.previewDeckImport(validated)
        XCTAssertEqual(repeated.duplicates.count, 4)
        let after = try BackupData.capture(destination)
        XCTAssertEqual(try destination.importDeckPackage(validated, skipDuplicates: true, now: now), 0)
        XCTAssertEqual(try BackupData.capture(destination), after)
        XCTAssertEqual(try destination.importDeckPackage(validated, skipDuplicates: false, now: now), 4)
        _ = try BackupArchive.decode(await BackupService.export(repository: destination, now: now, appVersion: "test"))
    }
    func testDeckExchangeRejectsCorruptionAndRollsBackAllModelsAndFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root.appendingPathComponent("source")); try populate(source)
        let child = try XCTUnwrap(source.decks().first(where: { $0.parentID != nil }))
        let bytes = try await DeckExchange.export(repository: source, rootID: child.id)
        let validated = try DeckExchange.decode(bytes)
        var version = validated.package; version.schemaVersion = 2
        XCTAssertThrowsError(try DeckExchange.validate(version, bytes: validated.bytes))
        let cycle = DeckPackage(rootID: child.id, decks: [SharedDeck(id: child.id, name: child.name, parentID: child.id)], notes: validated.package.notes, media: validated.package.media)
        XCTAssertThrowsError(try DeckExchange.validate(cycle, bytes: validated.bytes))
        var invalidNotes = validated.package.notes
        invalidNotes[0].content.questionAudioID = validated.package.media[0].id
        let invalidRole = DeckPackage(rootID: child.id, decks: validated.package.decks, notes: invalidNotes, media: validated.package.media)
        XCTAssertThrowsError(try DeckExchange.validate(invalidRole, bytes: validated.bytes))
        var damaged = validated.bytes; damaged[validated.package.media[0].id] = Data("broken".utf8)
        XCTAssertThrowsError(try DeckExchange.validate(validated.package, bytes: damaged))
        XCTAssertThrowsError(try DeckExchange.decode(Data(bytes.dropLast())))
        var files = try StoredZIP.read(bytes)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: files["deck.json"]!) as? [String: Any])
        json["logs"] = []
        files["deck.json"] = try JSONSerialization.data(withJSONObject: json)
        files["manifest.json"] = try JSONEncoder().encode(DeckFileManifest(files: files.filter { $0.key != "manifest.json" }.mapValues(BackupArchive.hash)))
        XCTAssertThrowsError(try DeckExchange.decode(StoredZIP.write(files)))
        let destination = try fixture(root.appendingPathComponent("destination"))
        let before = try BackupData.capture(destination)
        destination.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try destination.importDeckPackage(validated, skipDuplicates: false, now: now))
        XCTAssertEqual(try BackupData.capture(destination), before)
        if let enumerator = FileManager.default.enumerator(at: destination.mediaStore.root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator { XCTAssertNotEqual(try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, true) }
        }
        destination.save = { try $0.save() }
        let task = Task { try destination.importDeckPackage(validated, skipDuplicates: false, now: now) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled import must not succeed") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try BackupData.capture(destination), before)
    }
}

extension BackupRepositoryTests {
    func testLegacyAnkiStandardModelsMediaAndCountsImportAsFreshLearning() async throws {
        let bytes = try UITestFixtures.ankiFixture()
        let preview = try AnkiImport.decode(bytes)
        XCTAssertEqual(preview.sourceNotes, 5); XCTAssertEqual(preview.sourceCards, 7)
        XCTAssertEqual(preview.deck.package.notes.count, 3); XCTAssertEqual(preview.deck.cardCount, 5)
        XCTAssertEqual(preview.skipped.count, 2); XCTAssertEqual(preview.scheduledCards, 7); XCTAssertEqual(preview.reviewLogs, 1)
        XCTAssertTrue(preview.skipped.contains { $0.reason.contains("スクリプト") })
        XCTAssertTrue(preview.skipped.contains { $0.reason.contains("2フィールド") })
        let basic = try XCTUnwrap(preview.deck.package.notes.first { $0.content.question.contains("Anki question") })
        XCTAssertEqual(basic.content.question, "Anki question")
        XCTAssertEqual(basic.content.answer, "Anki answer")
        XCTAssertNotNil(basic.content.imageID); XCTAssertNotNil(basic.content.questionAudioID); XCTAssertNotNil(basic.content.answerAudioID)
        XCTAssertEqual(preview.deck.package.media.count, 3)
        let cloze = try XCTUnwrap(preview.deck.package.notes.first { $0.kind == .cloze })
        XCTAssertEqual(cloze.content.question, "{{c1::red}} and {{c2::blue::color}}")
        XCTAssertEqual(cloze.content.explanation, "Extra explanation")
        let reverse = try XCTUnwrap(preview.deck.package.notes.first { $0.content.reverseEnabled == true })
        XCTAssertEqual(try CardGeneration.variants(kind: reverse.kind, content: reverse.content).count, 2)
        XCTAssertEqual(Set(preview.deck.package.decks.map(\.name)), ["Anki取込", "Default", "Child"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try fixture(root)
        let before = try BackupData.capture(repo)
        XCTAssertEqual(try repo.importDeckPackage(preview.deck, skipDuplicates: true, now: now), 3)
        XCTAssertEqual(try repo.cards().count, 5); XCTAssertTrue(try repo.logs().isEmpty)
        XCTAssertEqual(try repo.settings().desiredRetention, before.preferences[0].desiredRetention)
        XCTAssertTrue(try repo.noteItems().allSatisfy { $0.summary.repetitions == 0 })
        XCTAssertEqual(try repo.previewDeckImport(preview.deck).duplicates.count, 3)
        _ = try BackupArchive.decode(await BackupService.export(repository: repo, now: now, appVersion: "test"))
        var legacy2 = try StoredZIP.read(bytes)
        legacy2["collection.anki21"] = legacy2["collection.anki2"]; legacy2["meta"] = Data([8, 2])
        XCTAssertEqual(try AnkiImport.decode(StoredZIP.write(legacy2)).deck.cardCount, 5)
    }
    func testAnkiRejectsModernDamagedUnsafeSchemaAndPathsWithoutChangingStore() throws {
        let bytes = try UITestFixtures.ankiFixture(), files = try StoredZIP.read(bytes)
        var modern = files; modern["collection.anki21b"] = Data([1, 2, 3])
        XCTAssertThrowsError(try AnkiImport.decode(StoredZIP.write(modern)))
        var badDB = files; badDB["collection.anki2"] = Data("not sqlite".utf8)
        XCTAssertThrowsError(try AnkiImport.decode(StoredZIP.write(badDB)))
        var truncated = files; truncated["collection.anki2"] = Data(files["collection.anki2"]!.prefix(200))
        XCTAssertThrowsError(try AnkiImport.decode(StoredZIP.write(truncated)))
        XCTAssertThrowsError(try AnkiImport.decode(UITestFixtures.ankiFixture(script: true)))
        var paths = files; paths["media"] = try JSONEncoder().encode(["0": "../escape.png", "1": "q.wav", "2": "a.wav"])
        XCTAssertThrowsError(try AnkiImport.decode(StoredZIP.write(paths)))
        var missing = files; missing["1"] = nil
        XCTAssertThrowsError(try AnkiImport.decode(StoredZIP.write(missing)))
        var unknown = files; unknown["unexpected.sql"] = Data("ATTACH".utf8)
        XCTAssertThrowsError(try AnkiImport.decode(StoredZIP.write(unknown)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try fixture(root), before = try BackupData.capture(repo)
        let preview = try AnkiImport.decode(bytes)
        XCTAssertEqual(try BackupData.capture(repo), before)
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.importDeckPackage(preview.deck, skipDuplicates: true, now: now))
        XCTAssertEqual(try BackupData.capture(repo), before)
    }
}


extension BackupRepositoryTests {
    // Independent Python sqlite3 + zipfile fixture, rather than our app's ZIP writer.
    func testDeflatedLegacyAnkiPackage() throws {
        let data = Data(base64Encoded: "UEsDBBQAAAAIAJVzS13VNwudBAIAAABQAAAQAAAAY29sbGVjdGlvbi5hbmtpMu3Yz2rUQBwH8Jl2d20Ru4UeluLBMSC0sJQt3kTFbc1KsbV1u0KL9BB3Jm1oktmdzFZLmEN9Ai++i+/gxVfwLTw6SfYvUjyJaL8fJsOP30x+v8lxcvh6N9CC+VJFnmYPyTKhlDxjjBBSHj4jpeEzQsnvlcnG5693sheXPpHql+qbpe82AAAAAAAAgBtvv1Spra7SVHvvQqHERShPi7m83XabHZd1mlu7LityawFnO6867gu3zQ7aO3vN9jF76R7Xu5P8upq/VavV6NV2XrHrKZ7kU2mmXp66rlw8ydf5VCzVJFail4x7enNFz/t5z1hqkeTT/EzPPHVdz2iqjx/yhHXco05de6dFtN6ildrKCh0UXyVDO+Zmv0iGaxdCjYtEkotwWIaL7vmwTnY3p9UHxA4AAAAAAACAm+3qiJbpx/7e7dTZbDScRyx19GVP2KBRZ052Pbfh29SRig9zsRdly05LyVg7ps5Gi5tTi1te99wxJzajo174S42+H+lsW5rmVYxxbNKbTR4GXBjz+EyxgD/x4uS9UE/TNCtst5sTY+yJ8/OOeh5c6jMZt4IPeqCEY0xx//9G7AAAAAAAAACAf8QGLRO6f5c/F37oacFZfyASHcj43jhT/Cbwi18Axf3/B7EDAAAAAAAAAP4zFVohi4sLC9n9nyz/7dMAAAAAAAAAwJ/0E1BLAwQUAAAACACVc0tdQ7+mowQAAAACAAAABQAAAG1lZGlhq64FAFBLAQIUAxQAAAAIAJVzS13VNwudBAIAAABQAAAQAAAAAAAAAAAAAACAAQAAAABjb2xsZWN0aW9uLmFua2kyUEsBAhQDFAAAAAgAlXNLXUO/pqMEAAAAAgAAAAUAAAAAAAAAAAAAAIABMgIAAG1lZGlhUEsFBgAAAAACAAIAcQAAAFkCAAAAAA==")!
        let preview = try AnkiImport.decode(data)
        XCTAssertEqual(preview.deck.cardCount, 1)
        XCTAssertEqual(preview.deck.package.notes.first?.content.question, "Deflated question")
        XCTAssertEqual(preview.deck.package.notes.first?.content.answer, "Deflated answer")
    }
}
