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
