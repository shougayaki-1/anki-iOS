import XCTest
import UIKit
import SwiftData
import CoreData
import Darwin
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
        let marked = try XCTUnwrap(source.cards().first { $0.id != (try? source.session()?.cardID) })
        try source.setFlags(cardIDs: [marked.id], flag: .blue)
        try source.hideToday(cardID: marked.id, now: now)
        try source.transaction {
            var options = try source.options()
            options.activeSessionProgress?.reviewOrderPolicy = .forgettingRisk
            options.activeSessionProgress?.reviewOrder = try source.cards().map(\.id)
            try source.writeOptionsInTransaction(options)
        }
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
        XCTAssertEqual(try reopened.widgetStreakDays(now: now, settings: reopened.settings()),
                       try source.widgetStreakDays(now: now, settings: source.settings()))
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
    func testTypedAnswersRestoreWithIDsTextPolicyAndUndoAndRejectBadLogLink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root.appendingPathComponent("source"))
        try source.createNote(NoteInput(deckID: source.decks()[0].id, question: "保存対象", answer: "模範解答", responseMode: .typing), now: now)
        try source.updateTypedAnswerPolicy(TypedAnswerPolicy(enabled: true, retentionDays: 90), now: now)
        try source.start(mode: .new, now: now); try source.updateDraft(text: "自分の回答\n複数行", revealed: true, now: now); try source.grade(.good, now: now)
        let expected = try source.savedTypedAnswers(now: now)
        let backup = try BackupArchive.decode(await BackupService.export(repository: source, now: now, appVersion: "test"))
        let destination = try fixture(root.appendingPathComponent("destination"))
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("destination/Study.store"))
        _ = try BackupService.restore(backup, location: location, mediaStore: destination.mediaStore, now: now)
        let reopened = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: location.canonicalStore), mediaStore: destination.mediaStore)
        XCTAssertEqual(try reopened.savedTypedAnswers(now: now), expected)
        XCTAssertEqual(try reopened.options().typedAnswerPolicy, TypedAnswerPolicy(enabled: true, retentionDays: 90))
        try reopened.undo(now: now)
        XCTAssertTrue(try reopened.savedTypedAnswers(now: now).isEmpty); XCTAssertTrue(try reopened.logs().isEmpty)
        var invalid = backup.data
        let value = expected[0]
        invalid.typedAnswers = [TypedAnswerRecord(id: UUID(), cardID: value.cardID, reviewedAt: value.reviewedAt, grade: value.grade,
                                                question: value.question, answer: value.answer, modelAnswer: value.modelAnswer)]
        XCTAssertThrowsError(try BackupValidation.validate(invalid, media: backup.media))
        invalid.typedAnswers = [value, value]
        XCTAssertThrowsError(try BackupValidation.validate(invalid, media: backup.media))
        var legacy = backup.data; legacy.typedAnswers = nil
        let decoded = try BackupArchive.decode(BackupArchive.create(data: legacy, media: backup.media, now: now, appVersion: "legacy"))
        XCTAssertNil(decoded.data.typedAnswers)
        let expired = try BackupArchive.decode(await BackupService.export(repository: source, now: now.addingTimeInterval(91 * 86400), appVersion: "test"))
        XCTAssertNil(expired.data.typedAnswers); XCTAssertEqual(expired.data.logs.count, 1)
        XCTAssertEqual(expired.data.cards.first?.id, backup.data.cards.first?.id)
        XCTAssertEqual(expired.data.cards.first?.fsrsPayload, backup.data.cards.first?.fsrsPayload)
    }
    func testImageZIPBackupRestoreAndCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root.appendingPathComponent("source"))
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.blue.setStroke(); context.cgContext.strokeEllipse(in: CGRect(x: 5, y: 5, width: 30, height: 30))
        }.pngData()!
        let csv = "answer,image\n名称,images/a.png"
        let package = try ImageImportPackage.read(StoredZIP.write(["cards.csv": Data(csv.utf8), "images/a.png": bytes]))
        _ = try source.importImagePackage(package, deckID: source.decks()[0].id, action: .add, now: now)
        try source.start(mode: .new, now: now); try source.updateDraft(revealed: true, now: now); try source.grade(.good, now: now)
        let backup = try BackupArchive.decode(await BackupService.export(repository: source, now: now, appVersion: "test"))
        let destination = try fixture(root.appendingPathComponent("destination"))
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("destination/Study.store"))
        _ = try BackupService.restore(backup, location: location, mediaStore: destination.mediaStore, now: now)
        let reopened = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: location.canonicalStore), mediaStore: destination.mediaStore)
        XCTAssertEqual(try reopened.cards().map(\.id), try source.cards().map(\.id))
        XCTAssertEqual(try reopened.logs().map(\.id), try source.logs().map(\.id))
        XCTAssertEqual(try Data(contentsOf: reopened.assetURL(id: reopened.assets()[0].id)), bytes)
        try reopened.undo(now: now)
        XCTAssertTrue(try reopened.logs().isEmpty)
        let note = try reopened.notes()[0]
        try reopened.deleteNote(id: note.id)
        try reopened.cleanupUnusedMedia()
        XCTAssertTrue(try reopened.assets().isEmpty)
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
    func testUnifiedFileRoutingUsesExistingAtomicDeckAndAnkiImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root.appendingPathComponent("source")); try populate(source)
        let target = try fixture(root.appendingPathComponent("target")); try populate(target)
        let existing = try BackupData.capture(target)
        let data = try await DeckExchange.export(repository: source, rootID: source.decks()[0].id)
        guard case .deck(let deck) = try LocalFileInput.decodeImport(data, extension: "studydeck") else { return XCTFail("Expected deck") }
        let destination = try XCTUnwrap(target.decks().first).id
        let plan = try target.previewDeckImport(deck, destination: .childOf(destination))
        target.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try target.importDeckPackageReceipt(deck, skipDuplicates: false, now: now,
                            destination: .childOf(destination), expectedPreview: plan))
        XCTAssertEqual(try BackupData.capture(target), existing)
        target.save = { try $0.save() }
        let receipt = try target.importDeckPackageReceipt(deck, skipDuplicates: false, now: now,
                            destination: .childOf(destination), expectedPreview: plan)
        XCTAssertGreaterThan(receipt.createdNotes, 0)
        XCTAssertEqual(try target.logs().map(\.id), existing.logs.map(\.id))
        for name in ["latest-media", "legacy2-media"] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "apkg", subdirectory: "Anki"))
            for ext in ["apkg", "zip"] {
                guard case .anki(let anki) = try LocalFileInput.decodeImport(Data(contentsOf: url), extension: ext) else { return XCTFail("Expected Anki") }
                XCTAssertGreaterThan(anki.deck.cardCount, 0)
                XCTAssertGreaterThan(anki.sourceNotes, 0)
            }
        }
    }

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
        let receipt = try destination.importDeckPackageReceipt(validated, skipDuplicates: true, now: now)
        XCTAssertEqual(receipt.createdNotes, 4)
        XCTAssertEqual(receipt.createdCards, 6)
        XCTAssertEqual(receipt.duplicateNotes, 0)
        XCTAssertEqual(receipt.destinationName, "子デッキ（取込 2）")
        XCTAssertTrue(try destination.decks().contains { $0.id == receipt.rootDeckID && $0.name == receipt.destinationName })
        XCTAssertEqual(receipt.outcome, .complete)
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
        let empty = try destination.importDeckPackageReceipt(validated, skipDuplicates: true, now: now)
        XCTAssertEqual(empty.createdNotes, 0); XCTAssertEqual(empty.createdCards, 0)
        XCTAssertEqual(empty.duplicateNotes, 4); XCTAssertNil(empty.rootDeckID); XCTAssertNil(empty.destinationName)
        XCTAssertEqual(empty.outcome, .empty)
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
        XCTAssertEqual(preview.deck.package.notes.count, 4); XCTAssertEqual(preview.deck.cardCount, 6)
        XCTAssertEqual(preview.skipped.count, 1); XCTAssertEqual(preview.scheduledCards, 7); XCTAssertEqual(preview.reviewLogs, 1)
        XCTAssertTrue(preview.skipped.contains { $0.reason.contains("スクリプト") })
        XCTAssertTrue(preview.warnings.contains { $0.reason.contains("フィールド") })
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
        XCTAssertEqual(try repo.importDeckPackage(preview.deck, skipDuplicates: true, now: now), 4)
        XCTAssertEqual(try repo.cards().count, 6); XCTAssertTrue(try repo.logs().isEmpty)
        XCTAssertEqual(try repo.settings().desiredRetention, before.preferences[0].desiredRetention)
        XCTAssertTrue(try repo.noteItems().allSatisfy { $0.summary.repetitions == 0 })
        XCTAssertEqual(try repo.previewDeckImport(preview.deck).duplicates.count, 4)
        _ = try BackupArchive.decode(await BackupService.export(repository: repo, now: now, appVersion: "test"))
        var legacy2 = try StoredZIP.read(bytes)
        legacy2["collection.anki21"] = legacy2["collection.anki2"]; legacy2["meta"] = Data([8, 2])
        XCTAssertEqual(try AnkiImport.decode(StoredZIP.write(legacy2)).deck.cardCount, 6)
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


extension BackupRepositoryTests {
    private func exportedAnki(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: BackupRepositoryTests.self).url(forResource: name, withExtension: "apkg", subdirectory: "Anki"))
        return try Data(contentsOf: url)
    }
    func testActualAnkiLatestAndLegacyExportsAndAtomicFreshImport() async throws {
        for name in ["latest-media", "legacy2-media"] {
            let preview = try AnkiImport.decode(exportedAnki(name))
            XCTAssertEqual(preview.sourceNotes, 3); XCTAssertEqual(preview.sourceCards, 5)
            XCTAssertEqual(preview.deck.package.notes.count, 3); XCTAssertEqual(preview.deck.cardCount, 5)
            XCTAssertTrue(preview.skipped.isEmpty, preview.skipped.map(\.reason).joined(separator: ";")); XCTAssertTrue(preview.warnings.isEmpty)
            XCTAssertEqual(preview.deck.package.media.count, 2)
            XCTAssertTrue(preview.deck.package.decks.contains { $0.name == "日本語" })
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let repo = try fixture(root); try populate(repo)
            let before = try BackupData.capture(repo)
            func mediaFiles() throws -> Set<String> {
                let entries = (FileManager.default.enumerator(at: repo.mediaStore.root, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL]) ?? []
                return try Set(entries.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }.map(\.path))
            }
            let mediaPaths = try mediaFiles()
            _ = try repo.previewDeckImport(preview.deck)
            XCTAssertEqual(try BackupData.capture(repo), before)
            repo.save = { _ in throw Failure.save }
            XCTAssertThrowsError(try repo.importDeckPackage(preview.deck, skipDuplicates: true, now: now))
            XCTAssertEqual(try BackupData.capture(repo), before)
            XCTAssertEqual(try mediaFiles(), mediaPaths)
            repo.save = { try $0.save() }
            XCTAssertEqual(try repo.importDeckPackage(preview.deck, skipDuplicates: true, now: now), 3)
            let after = try BackupData.capture(repo)
            XCTAssertEqual(Set(before.cards.map(\.id)).subtracting(after.cards.map(\.id)), [])
            XCTAssertEqual(after.logs, before.logs)
            XCTAssertEqual(after.cards.filter { Set(before.cards.map(\.id)).contains($0.id) }, before.cards)
            XCTAssertEqual(try repo.previewDeckImport(preview.deck).duplicates.count, 3)
            XCTAssertEqual(try repo.importDeckPackage(preview.deck, skipDuplicates: true, now: now), 0)
            let backup = try BackupArchive.decode(await BackupService.export(repository: repo, now: now, appVersion: "test"))
            let restored = try fixture(root.appendingPathComponent("restored"))
            let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("restored/Study.store"))
            _ = try BackupService.restore(backup, location: location, mediaStore: restored.mediaStore, now: now)
            let reopened = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: location.canonicalStore), mediaStore: restored.mediaStore)
            XCTAssertEqual(Set(try reopened.cards().map(\.id)), Set(after.cards.map(\.id)))
            XCTAssertEqual(try reopened.logs().count, before.logs.count)
            for item in preview.deck.package.media {
                let restoredAsset = try XCTUnwrap(try reopened.assets().first { $0.sha256 == item.sha256 })
                XCTAssertEqual(try Data(contentsOf: reopened.assetURL(id: restoredAsset.id)), preview.deck.bytes[item.id])
            }
        }
    }
    func testActualAnkiVocabulary1900AndMissingMediaWarnings() throws {
        let started = Date()
        let preview = try AnkiImport.decode(exportedAnki("latest-vocabulary-1900"))
        print("Anki 1900-note preview seconds:", Date().timeIntervalSince(started))
        XCTAssertEqual(preview.sourceNotes, 1900); XCTAssertEqual(preview.sourceCards, 1900)
        XCTAssertEqual(preview.deck.package.notes.count, 1900); XCTAssertEqual(preview.deck.cardCount, 1900)
        XCTAssertTrue(preview.skipped.isEmpty); XCTAssertEqual(preview.warnings.count, 3800)
        XCTAssertTrue(preview.deck.package.media.isEmpty)
        XCTAssertEqual(preview.deck.package.decks.filter { $0.name.hasPrefix("Lesson") }.count, 19)
        let note = try XCTUnwrap(preview.deck.package.notes.first)
        XCTAssertTrue(note.content.question.contains("fictional"))
        XCTAssertTrue(note.content.answer.contains("架空"))
        XCTAssertNil(note.content.questionAudioID); XCTAssertNil(note.content.answerAudioID)
        let missing = try AnkiImport.decode(exportedAnki("latest-no-media"))
        XCTAssertEqual(missing.deck.package.notes.count, 2); XCTAssertEqual(missing.deck.cardCount, 4)
        XCTAssertEqual(missing.skipped.count, 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try fixture(root); try populate(repo)
        let before = try BackupData.capture(repo)
        _ = try repo.previewDeckImport(preview.deck)
        XCTAssertEqual(try BackupData.capture(repo), before)
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.importDeckPackage(preview.deck, skipDuplicates: true, now: now))
        XCTAssertEqual(try BackupData.capture(repo), before)
        repo.save = { try $0.save() }
        XCTAssertEqual(try repo.importDeckPackage(preview.deck, skipDuplicates: true, now: now), 1900)
        XCTAssertEqual(try repo.previewDeckImport(preview.deck).duplicates.count, 1900)
        XCTAssertEqual(try BackupData.capture(repo).cards.filter { Set(before.cards.map(\.id)).contains($0.id) }, before.cards)
    }
    func testLatestAnkiMetaChecksumTruncationAndNoDummyFallback() throws {
        let bytes = try exportedAnki("latest-media")
        let files = try AnkiPackageZIP.read(bytes, budget: AnkiReadBudget())
        var altered = files; altered["meta"] = Data([8, 99])
        XCTAssertThrowsError(try AnkiImport.decode(StoredZIP.write(altered)))
        altered = files; altered["meta"] = nil
        XCTAssertThrowsError(try AnkiImport.decode(StoredZIP.write(altered)))
        altered = files; altered["meta"] = Data([8, 1])
        XCTAssertThrowsError(try AnkiImport.decode(StoredZIP.write(altered)))
        altered = files; altered["collection.anki21b"] = Data(files["collection.anki21b"]!.dropLast())
        XCTAssertThrowsError(try AnkiImport.decode(StoredZIP.write(altered)))
        altered = files; altered["0"] = files["1"]
        XCTAssertThrowsError(try AnkiImport.decode(StoredZIP.write(altered)))
        altered = files; altered["orphan"] = Data([1])
        XCTAssertThrowsError(try AnkiImport.decode(StoredZIP.write(altered)))
        XCTAssertThrowsError(try AnkiProto(Data([0x0a, 0xff])))
        XCTAssertThrowsError(try AnkiZstd.decode(Data([0x28, 0xb5, 0x2f, 0xfd]), limit: 100, budget: AnkiReadBudget()))
    }
}


extension BackupRepositoryTests {
    func testAnkiDescriptorExtraFieldsAndStreamingExpansionLimit() throws {
        let bytes = try exportedAnki("latest-descriptor-extra")
        XCTAssertEqual(try AnkiImport.decode(bytes).deck.cardCount, 5)
        // The backup/studydeck reader intentionally continues rejecting this ZIP profile.
        XCTAssertThrowsError(try StoredZIP.read(bytes, allowDeflate: true))
        let url = try XCTUnwrap(Bundle(for: BackupRepositoryTests.self).url(forResource: "expansion-limit", withExtension: "zst", subdirectory: "Anki"))
        XCTAssertThrowsError(try AnkiZstd.decode(Data(contentsOf: url), limit: 50_000_000, budget: AnkiReadBudget())) { error in
            guard case BackupError.tooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
        var files = try AnkiPackageZIP.read(bytes, budget: AnkiReadBudget())
        files["Media"] = files["media"]
        XCTAssertThrowsError(try AnkiPackageZIP.read(StoredZIP.write(files), budget: AnkiReadBudget()))
    }
    func testCancelledAnkiPreviewDoesNotChangeStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try fixture(root); try populate(repo)
        let before = try BackupData.capture(repo), bytes = try exportedAnki("latest-vocabulary-1900")
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AnkiImport.decode(bytes)
        }
        do { _ = try await task.value; XCTFail("Cancelled preview completed") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try BackupData.capture(repo), before)
    }
}

extension BackupRepositoryTests {
    func testRestoreOutcomeCountsCommittedStoreAndPreservesIDsAndHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root.appendingPathComponent("source")); try populate(source)
        let backup = try BackupArchive.decode(await BackupService.export(repository: source, now: now, appVersion: "test"))
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("destination/Study.store"))
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now },
            mediaStore: MediaStore(root: root.appendingPathComponent("destination/Media")), storageLocation: location)
        try store.repository.createNote(NoteInput(deckID: store.repository.decks()[0].id, question: "Before", answer: "Old"), now: now)
        let result = try store.restoreBackup(backup)
        XCTAssertNil(result.warning); XCTAssertNil(store.failure)
        let summary = try XCTUnwrap(result.summary)
        XCTAssertEqual(summary.decks, try store.repository.decks().count)
        XCTAssertEqual(summary.notes, try store.repository.notes().count)
        XCTAssertEqual(summary.cards, try store.repository.cards().count)
        XCTAssertEqual(summary.logs, try store.repository.logs().count)
        XCTAssertEqual(summary.media, try store.repository.assets().count)
        XCTAssertEqual(Set(try store.repository.cards().map(\.id)), Set(backup.data.cards.map(\.id)))
        XCTAssertEqual(try BackupData.capture(store.repository).canonical().cards, backup.data.canonical().cards)
        XCTAssertEqual(try BackupData.capture(store.repository).canonical().logs, backup.data.canonical().logs)
        store.selectedTab = 3
        store.selectedTab = 0
        store.refreshHome()
        XCTAssertTrue(store.hasCards)
    }
}

extension BackupRepositoryTests {
    func testSnapshotGenerationsRetentionFailureCancellationAndCorruptionIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try fixture(root.appendingPathComponent("store")); try populate(repo)
        let before = try BackupData.capture(repo).canonical()
        let bytes = try await BackupService.export(repository: repo, now: now, appVersion: "test", pruneExpiredAnswers: false)
        let manager = LocalSnapshots(root: root.appendingPathComponent("snapshots"))
        let first = try manager.save(bytes, kind: .automatic, reason: "test", now: now, maximumCount: 2)
        let second = try manager.save(bytes, kind: .beforeChange, reason: "test", now: now.addingTimeInterval(1), maximumCount: 2)
        XCTAssertThrowsError(try manager.save(bytes, kind: .automatic, reason: "write fails", now: now.addingTimeInterval(2), maximumCount: 2, write: { _, _ in throw Failure.save }))
        XCTAssertThrowsError(try manager.save(bytes, kind: .automatic, reason: "no space", now: now, maximumBytes: bytes.count - 1))
        XCTAssertThrowsError(try manager.save(bytes, kind: .automatic, reason: "short write", now: now, write: { data, url in try Data(data.prefix(10)).write(to: url) }))
        let cancelled = Task.detached { () throws -> LocalSnapshot in
            withUnsafeCurrentTask { $0?.cancel() }
            return try manager.save(bytes, kind: .automatic, reason: "cancelled", now: Date())
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled generation published") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(Set(try manager.list().map(\.id)), [first.id, second.id])
        let third = try manager.save(bytes, kind: .manual, reason: "test", now: now.addingTimeInterval(2), maximumCount: 2)
        XCTAssertEqual(Set(try manager.list().map(\.id)), [second.id, third.id])
        XCTAssertEqual(try manager.read(third).data.canonical(), before)
        try Data("broken info".utf8).write(to: manager.root.appendingPathComponent(second.id.uuidString).appendingPathComponent("info.json"))
        XCTAssertEqual(try manager.list().map(\.id), [third.id])
        XCTAssertEqual(manager.unreadableCount(entries: try manager.list()), 1)
        XCTAssertEqual(try manager.read(third).data.canonical(), before)
        try Data("broken archive".utf8).write(to: manager.archiveURL(third.id))
        XCTAssertThrowsError(try manager.read(third))
        XCTAssertEqual(try BackupData.capture(repo).canonical(), before)
        let stale = manager.root.appendingPathComponent(".pending-\(UUID().uuidString)")
        let recent = manager.root.appendingPathComponent(".pending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-172_800)], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: recent.path)
        manager.cleanAbandonedStaging(now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertGreaterThan(manager.diskBytes, 0)
        // Abandoned staging is never offered as a generation.
        try FileManager.default.createDirectory(at: manager.root.appendingPathComponent(".pending-abandoned"), withIntermediateDirectories: true)
        XCTAssertEqual(try manager.list().map(\.id), [third.id])
    }
    func testSnapshotAutomaticPolicyAndByteRetention() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try fixture(root.appendingPathComponent("store"))
        let bytes = try await BackupService.export(repository: repo, now: now, appVersion: "test", pruneExpiredAnswers: false)
        let manager = LocalSnapshots(root: root.appendingPathComponent("snapshots"))
        var policy = try manager.policy()
        XCTAssertTrue(manager.isDue(now: now, policy: policy, entries: []))
        let first = try manager.save(bytes, kind: .automatic, reason: "automatic", now: now)
        XCTAssertFalse(manager.isDue(now: now.addingTimeInterval(86_399), policy: policy, entries: [first]))
        XCTAssertTrue(manager.isDue(now: now.addingTimeInterval(86_400), policy: policy, entries: [first]))
        policy.enabled = false; policy.intervalHours = 6; try manager.savePolicy(policy)
        XCTAssertEqual(try manager.policy(), policy)
        XCTAssertFalse(manager.isDue(now: now.addingTimeInterval(86_400), policy: policy, entries: [first]))
        let next = try manager.save(bytes, kind: .manual, reason: "limit", now: now.addingTimeInterval(1), maximumBytes: bytes.count)
        XCTAssertEqual(try manager.list().map(\.id), [next.id])
    }
    func testLocalSnapshotFullRestoreWithMediaHistoryAndFSRS() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try fixture(root.appendingPathComponent("source")); try populate(repo)
        let manager = LocalSnapshots(root: root.appendingPathComponent("snapshots"))
        let bytes = try await BackupService.export(repository: repo, now: now, appVersion: "test", pruneExpiredAnswers: false)
        let entry = try manager.save(bytes, kind: .beforeChange, reason: "完全復元", now: now)
        let backup = try manager.read(entry)
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("dest/Study.store"))
        let media = MediaStore(root: root.appendingPathComponent("dest/Media"))
        _ = try BackupService.restore(backup, location: location, mediaStore: media, now: now)
        let restored = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: location.canonicalStore, mediaStore: media), mediaStore: media)
        XCTAssertEqual(try BackupData.capture(restored).canonical().cards, backup.data.canonical().cards)
        XCTAssertEqual(try BackupData.capture(restored).canonical().logs, backup.data.canonical().logs)
        for asset in try restored.assets() { XCTAssertEqual(try Data(contentsOf: restored.assetURL(id: asset.id)), backup.media[asset.id]) }
        XCTAssertEqual(try manager.read(entry).data.canonical(), backup.data.canonical())
    }
    func testMigrationRescueIncludesWALAndSkipsCurrentSchemaWithoutReadingOversizeMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try fixture(root.appendingPathComponent("source")); try populate(repo)
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("source/Study.store"))
        let rescue = MigrationRescue(location: location)
        try FileManager.default.removeItem(at: rescue.marker)
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: location.canonicalStore, options: [NSReadOnlyPersistentStoreOption: true])
        XCTAssertEqual(metadata[NSStoreModelVersionIdentifiersKey] as? [String], ["6.0.0"])
        let large = repo.mediaStore.root.appendingPathComponent("unreferenced-large.bin")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let file = try FileHandle(forWritingTo: large); try file.truncate(atOffset: UInt64(StoredZIP.maximumBytes + 1)); try file.close()
        try rescue.preserveIfNeeded(schema: "6.0.0", mediaStore: repo.mediaStore)
        XCTAssertTrue(rescue.archives.isEmpty)
        try FileManager.default.removeItem(at: large)
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.canonicalStore.path + "-wal"))
        // Simulate a future V6 → V7 migration without defining a production V7 schema.
        try rescue.preserveIfNeeded(schema: "7.0.0", mediaStore: repo.mediaStore)
        let archive = try XCTUnwrap(rescue.archives.first)
        XCTAssertEqual(archive.lastPathComponent, "before-7.0.0.zip")
        let files = try StoredZIP.read(Data(contentsOf: archive))
        let copyRoot = root.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: copyRoot, withIntermediateDirectories: true)
        let copyURL = copyRoot.appendingPathComponent("Study.store")
        try XCTUnwrap(files["Study.store"]).write(to: copyURL)
        let copied = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: copyURL), mediaStore: repo.mediaStore)
        XCTAssertEqual(try BackupData.capture(copied).canonical(), try BackupData.capture(repo).canonical())
        let original = try Data(contentsOf: archive)
        try rescue.preserveIfNeeded(schema: "7.0.0", mediaStore: repo.mediaStore)
        XCTAssertEqual(try Data(contentsOf: archive), original)
        XCTAssertTrue(files.keys.contains { $0.hasPrefix("Media/") })
    }
    func testBackgroundBackupReadsCommittedDataAndPreservesModelsAndMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try fixture(root)
        try populate(repo)
        let expected = try BackupData.capture(repo).canonical()
        // Unsaved edits in the UI context must not leak into an automatic archive.
        try repo.notes()[0].contentPayload = Data("unsaved".utf8)
        let bytes = try await BackupService.exportCommitted(container: repo.context.container,
            mediaStore: repo.mediaStore, now: now, appVersion: "test")
        let backup = try BackupArchive.decode(bytes)
        XCTAssertEqual(backup.data.canonical(), expected)
        XCTAssertEqual(backup.media.count, expected.media.count)
        repo.context.rollback()
        XCTAssertEqual(try BackupData.capture(repo).canonical(), expected)
        let cancelled = Task { () throws -> Data in
            try Task.checkCancellation()
            return try await BackupService.exportCommitted(container: repo.context.container,
                mediaStore: repo.mediaStore, now: now, appVersion: "test")
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled capture must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSnapshot3000CardsWithMediaMeasuresMainCaptureAndFullArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try fixture(root.appendingPathComponent("source")); try populate(repo)
        let remaining = 3_000 - (try repo.cards().count)
        let rows = try ImportParser.pasted((0..<remaining).map { "scale-\($0)\tanswer-\($0)" }.joined(separator: "\n"))
        _ = try repo.importRows(rows, deckID: repo.decks()[0].id, kind: .basic, tagNames: [], action: .skip, source: "scale", now: now)
        XCTAssertEqual(try repo.cards().count, 3_000)
        let start = Date(); let data = try BackupData.capture(repo)
        let captureSeconds = Date().timeIntervalSince(start)
        let started = Date()
        let bytes = try await BackupService.exportCommitted(container: repo.context.container, mediaStore: repo.mediaStore, now: now, appVersion: "test")
        let manager = LocalSnapshots(root: root.appendingPathComponent("snapshots"))
        let job = Task.detached { try manager.save(bytes, kind: .automatic, reason: "scale", now: Date()) }
        let entry = try await job.value
        XCTAssertEqual(entry.cards, 3_000)
        XCTAssertEqual(try manager.read(entry).data.canonical(), data.canonical())
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("SNAPSHOT_SCALE cards=3000 media=\(data.media.count) captureMainSeconds=\(captureSeconds) totalSeconds=\(Date().timeIntervalSince(started)) archiveBytes=\(bytes.count) processPeakBytes=\(usage.ru_maxrss)")
    }
}

extension BackupRepositoryTests {
    func testFailedRestorePointAbortsMutationAndPreservesOriginalStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("Study.store"))
        let media = MediaStore(root: root.appendingPathComponent("Media"))
        let store = try StudyStore(container: PersistenceController.makeStudyContainer(inMemory: true), clock: { self.now }, mediaStore: media, storageLocation: location)
        try populate(store.repository)
        let before = try BackupData.capture(store.repository).canonical()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: store.localSnapshots.root)
        var mutated = false
        do {
            try await store.createRestorePoint("完全復元の直前")
            mutated = true
        } catch {}
        XCTAssertFalse(mutated)
        XCTAssertFalse(store.snapshotWorking)
        XCTAssertEqual(try BackupData.capture(store.repository).canonical(), before)
    }
}

extension BackupRepositoryTests {
    func testDeckImportDestinationsAndStalePlanPreserveExistingData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root.appendingPathComponent("source"))
        let sourceRoot = try source.decks()[0].id
        let child = try source.createDeck(name: "Child", parentID: sourceRoot, now: now)
        try source.createNote(NoteInput(deckID: child, question: "Imported", answer: "Answer", hint: "Hint", tagNames: ["Tag"]), now: now)
        let package = try DeckExchange.decode(try await DeckExchange.export(repository: source, rootID: sourceRoot))
        for mode in 0..<3 {
            let target = try fixture(root.appendingPathComponent("target\(mode)"))
            try populate(target)
            let parent = try target.decks()[0].id
            let existingChild = try target.createDeck(name: "Child", parentID: parent, now: now)
            let before = try BackupData.capture(target)
            let destination: DeckImportDestination = mode == 0 ? .newRoot : mode == 1 ? .childOf(parent) : .mergeInto(parent)
            let preview = try target.previewDeckImport(package, destination: destination)
            XCTAssertEqual(preview.mappings.filter(\.reused).count, mode == 2 ? 2 : 0)
            let receipt = try target.importDeckPackageReceipt(package, skipDuplicates: true, now: now, destination: destination, expectedPreview: preview)
            XCTAssertEqual(receipt.createdNotes, 1)
            XCTAssertEqual(receipt.createdCards, 1)
            let imported = try XCTUnwrap(target.noteItems().first { $0.content.question == "Imported" })
            XCTAssertEqual(imported.content.hint, "Hint")
            XCTAssertEqual(imported.tagNames, ["Tag"])
            XCTAssertEqual(imported.deckName, preview.mappings.first { $0.id == child }?.destinationPath)
            if mode == 2 { XCTAssertEqual(imported.deckID, existingChild); XCTAssertEqual(receipt.rootDeckID, parent) }
            let after = try BackupData.capture(target)
            XCTAssertEqual(after.logs, before.logs)
            XCTAssertEqual(after.cards.filter { card in before.cards.contains { $0.id == card.id } }, before.cards)
            XCTAssertEqual(after.notes.filter { note in before.notes.contains { $0.id == note.id } }, before.notes)
            let duplicate = try target.previewDeckImport(package, destination: destination)
            let count = try target.decks().count
            XCTAssertEqual(try target.importDeckPackageReceipt(package, skipDuplicates: true, now: now, destination: destination, expectedPreview: duplicate).createdNotes, 0)
            XCTAssertEqual(try target.decks().count, count)
        }
        let target = try fixture(root.appendingPathComponent("stale"))
        let parent = try target.decks()[0].id
        let destination = DeckImportDestination.mergeInto(parent)
        let preview = try target.previewDeckImport(package, destination: destination)
        try target.createDeck(name: "Child", parentID: parent, now: now)
        let before = try BackupData.capture(target)
        XCTAssertThrowsError(try target.importDeckPackageReceipt(package, skipDuplicates: true, now: now, destination: destination, expectedPreview: preview))
        XCTAssertEqual(try BackupData.capture(target), before)
        let fresh = try target.previewDeckImport(package, destination: destination)
        target.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try target.importDeckPackageReceipt(package, skipDuplicates: false, now: now, destination: destination, expectedPreview: fresh))
        XCTAssertEqual(try BackupData.capture(target), before)
        XCTAssertThrowsError(try target.previewDeckImport(package, destination: .mergeInto(UUID())))
    }
}

extension BackupRepositoryTests {
    func testDeckMergeDoesNotCollapseAmbiguousSiblingNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root.appendingPathComponent("source"))
        let sourceRoot = try source.decks()[0].id
        let first = try source.createDeck(name: "Same", parentID: sourceRoot, now: now)
        let second = try source.createDeck(name: "Same", parentID: sourceRoot, now: now)
        try source.createNote(NoteInput(deckID: first, question: "First", answer: "A"), now: now)
        try source.createNote(NoteInput(deckID: second, question: "Second", answer: "A"), now: now)
        let package = try DeckExchange.decode(try await DeckExchange.export(repository: source, rootID: sourceRoot))
        let target = try fixture(root.appendingPathComponent("target"))
        let parent = try target.decks()[0].id
        let existing = try target.createDeck(name: "Same", parentID: parent, now: now)
        let preview = try target.previewDeckImport(package, destination: .mergeInto(parent))
        XCTAssertEqual(preview.mappings.filter(\.reused).count, 1)
        XCTAssertEqual(Set(preview.mappings.map(\.destinationPath)).count, 3)
        try target.importDeckPackageReceipt(package, skipDuplicates: true, now: now, destination: .mergeInto(parent), expectedPreview: preview)
        let items = try target.noteItems()
        XCTAssertEqual(Set(items.map(\.deckID)).count, 2)
        XCTAssertFalse(items.contains { $0.deckID == existing })
        let another = try target.createDeck(name: "Same", parentID: parent, now: now)
        XCTAssertNotEqual(existing, another)
        let single = try DeckExchange.decode(try await DeckExchange.export(repository: source, rootID: first))
        let ambiguous = try target.previewDeckImport(single, destination: .childOf(parent))
        XCTAssertTrue(ambiguous.mappings.allSatisfy { !$0.reused })
    }
}

extension BackupRepositoryTests {
    private func updatePackage(_ repo: StudyRepository, noteID: UUID, edit: (SharedNote) -> SharedNote) throws -> ValidatedDeckPackage {
        let (original, urls) = try repo.captureDeckPackage(rootID: repo.decks()[0].id)
        let package = DeckPackage(rootID: original.rootID, decks: original.decks,
            notes: original.notes.map { $0.id == noteID ? edit($0) : $0 }, media: original.media)
        return try DeckExchange.validated(package: package, bytes: urls.mapValues { try Data(contentsOf: $0) })
    }
    private func updateFixture(_ root: URL) throws -> (StudyRepository, UUID, DeckImportDestination) {
        let repo = try fixture(root); try populate(repo)
        try repo.transaction { if let draft = try repo.session() { draft.cardID = nil; draft.undoLogID = nil } }
        let id = try XCTUnwrap(repo.notes().first { $0.type == NoteKind.basic.rawValue }).id
        return (repo, id, .mergeInto(try repo.decks()[0].id))
    }
    func testDeckNoteUpdateIdentityAndConsentAreStrict() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, id, destination) = try updateFixture(root)
        let package = try updatePackage(repo, noteID: id) { note in
            var content = note.content; content.hint = "新しいヒント"
            return SharedNote(id: note.id, deckID: note.deckID, kind: note.kind, content: content, responseMode: note.responseMode, tags: ["更新"])
        }
        XCTAssertTrue(try repo.previewDeckImport(package).updates.isEmpty)
        XCTAssertTrue(try repo.previewDeckImport(package, destination: .childOf(repo.decks()[0].id)).updates.isEmpty)
        let preview = try repo.previewDeckImport(package, destination: destination)
        XCTAssertEqual(preview.updates.map(\.id), [id]); XCTAssertFalse(preview.updates[0].requiresReset)
        let before = try BackupData.capture(repo)
        XCTAssertThrowsError(try repo.importDeckPackageReceipt(package, skipDuplicates: true, now: now, destination: destination, updates: [id: .preserveHistory]))
        XCTAssertThrowsError(try repo.importDeckPackageReceipt(package, skipDuplicates: true, now: now, destination: destination, expectedPreview: preview, updates: [id: .resetSchedule]))
        XCTAssertThrowsError(try repo.importDeckPackageReceipt(package, skipDuplicates: true, now: now, destination: destination, expectedPreview: preview, updates: [UUID(): .preserveHistory]))
        XCTAssertEqual(try BackupData.capture(repo), before)
        let skipped = try repo.importDeckPackageReceipt(package, skipDuplicates: true, now: now, destination: destination, expectedPreview: preview)
        XCTAssertEqual(skipped.updatedNotes, 0); XCTAssertEqual(skipped.createdNotes, 0)
        XCTAssertEqual(try BackupData.capture(repo), before)
        // Even exact content matches with different UUIDs must never be update candidates.
        let otherID = try updatePackage(repo, noteID: id) { note in
            SharedNote(id: UUID(), deckID: note.deckID, kind: note.kind, content: note.content, responseMode: note.responseMode, tags: ["更新"])
        }
        XCTAssertTrue(try repo.previewDeckImport(otherID, destination: destination).updates.isEmpty)
        let structure = try updatePackage(repo, noteID: id) { note in
            var content = note.content; content.reverseEnabled = false; content.hint = "変更"
            return SharedNote(id: note.id, deckID: note.deckID, kind: note.kind, content: content, responseMode: note.responseMode, tags: note.tags)
        }
        let blocked = try repo.previewDeckImport(structure, destination: destination)
        XCTAssertTrue(blocked.updates.isEmpty); XCTAssertNotNil(blocked.updateBlocked[id])
        let clozeID = try XCTUnwrap(repo.notes().first { $0.type == NoteKind.cloze.rawValue }).id
        let clozeChange = try updatePackage(repo, noteID: clozeID) { note in
            var content = note.content; content.question = "{{c1::大阪}}と{{c2::京都}}"
            return SharedNote(id: note.id, deckID: note.deckID, kind: note.kind, content: content, responseMode: note.responseMode, tags: note.tags)
        }
        let ambiguous = try repo.previewDeckImport(clozeChange, destination: destination)
        XCTAssertTrue(ambiguous.updates.isEmpty); XCTAssertNotNil(ambiguous.updateBlocked[clozeID])
        let wrongDeck = try repo.createDeck(name: "別の統合先", now: now)
        let wrongDestination = try repo.previewDeckImport(package, destination: .mergeInto(wrongDeck))
        XCTAssertTrue(wrongDestination.updates.isEmpty); XCTAssertNotNil(wrongDestination.updateBlocked[id])
        try repo.transaction { let draft = try XCTUnwrap(repo.session()); draft.cardID = try repo.cards().first { $0.noteID == id }?.id }
        XCTAssertNotNil(try repo.previewDeckImport(package, destination: destination).updateBlocked[id])
    }
    func testDeckNoteUpdatePreservesHistoryAndBackupCompatibility() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, id, destination) = try updateFixture(root)
        let package = try updatePackage(repo, noteID: id) { note in
            var content = note.content; content.hint = "保持更新"
            return SharedNote(id: note.id, deckID: note.deckID, kind: note.kind, content: content, responseMode: note.responseMode, tags: ["地理"])
        }
        let preview = try repo.previewDeckImport(package, destination: destination)
        let before = try BackupData.capture(repo)
        let receipt = try repo.importDeckPackageReceipt(package, skipDuplicates: true, now: now.addingTimeInterval(40), destination: destination, expectedPreview: preview, updates: [id: .preserveHistory])
        XCTAssertEqual(receipt.updatedNotes, 1); XCTAssertEqual(receipt.createdNotes, 0); XCTAssertEqual(receipt.createdCards, 0)
        XCTAssertEqual(receipt.outcome, .partial)
        let after = try BackupData.capture(repo)
        XCTAssertEqual(after.cards, before.cards); XCTAssertEqual(after.logs, before.logs)
        XCTAssertEqual(after.decks, before.decks); XCTAssertEqual(after.sessions, before.sessions)
        XCTAssertEqual(after.notes.filter { $0.id != id }, before.notes.filter { $0.id != id })
        XCTAssertEqual(after.media, before.media)
        XCTAssertEqual(try repo.noteItems().first { $0.noteID == id }?.sourceContent.hint, "保持更新")
        let backup = try BackupArchive.decode(try await BackupService.export(repository: repo, now: now, appVersion: "test"))
        XCTAssertEqual(backup.data.canonical(), try BackupData.capture(repo).canonical())
        // v1 exchange remains readable and contains no schedule/history transfer.
        let exchange = try await DeckExchange.export(repository: repo, rootID: repo.decks()[0].id)
        XCTAssertEqual(try DeckExchange.decode(exchange).package.schemaVersion, 1)
    }
    func testDeckNoteResetRequiresConsentRetainsLogsAndRollsBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, id, destination) = try updateFixture(root)
        let package = try updatePackage(repo, noteID: id) { note in
            var content = note.content; content.answer = "修正版の答え"
            return SharedNote(id: note.id, deckID: note.deckID, kind: note.kind, content: content, responseMode: note.responseMode, tags: ["新規タグ"])
        }
        let preview = try repo.previewDeckImport(package, destination: destination)
        XCTAssertTrue(try XCTUnwrap(preview.updates.first).requiresReset)
        let before = try BackupData.capture(repo)
        XCTAssertThrowsError(try repo.importDeckPackageReceipt(package, skipDuplicates: true, now: now, destination: destination, expectedPreview: preview, updates: [id: .preserveHistory]))
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.importDeckPackageReceipt(package, skipDuplicates: true, now: now, destination: destination, expectedPreview: preview, updates: [id: .resetSchedule]))
        XCTAssertEqual(try BackupData.capture(repo).canonical(), before.canonical())
        let reopened = StudyRepository(container: repo.context.container, mediaStore: repo.mediaStore)
        XCTAssertEqual(try BackupData.capture(reopened).canonical(), before.canonical())
        repo.save = { try $0.save() }
        XCTAssertThrowsError(try repo.importDeckPackageReceipt(package, skipDuplicates: true, now: now, destination: destination, expectedPreview: preview, updates: [id: .resetSchedule])) // failed save invalidates consent
        let fresh = try repo.previewDeckImport(package, destination: destination)
        let resetTime = now.addingTimeInterval(100)
        let receipt = try repo.importDeckPackageReceipt(package, skipDuplicates: true, now: resetTime, destination: destination, expectedPreview: fresh, updates: [id: .resetSchedule])
        XCTAssertEqual(receipt.resetNotes, 1)
        let after = try BackupData.capture(repo)
        XCTAssertEqual(after.logs, before.logs); XCTAssertEqual(after.decks, before.decks); XCTAssertEqual(after.sessions, before.sessions)
        XCTAssertEqual(after.cards.filter { $0.noteID != id }, before.cards.filter { $0.noteID != id })
        let scheduler = try ReviewScheduler(desiredRetention: repo.settings().desiredRetention)
        let expectedSummary = try scheduler.summary(scheduler.newCard(now: resetTime))
        for card in after.cards where card.noteID == id {
            var expected = try XCTUnwrap(before.cards.first { $0.id == card.id })
            XCTAssertEqual(try scheduler.summary(JSONDecoder().decode(SchedulerSnapshot.self, from: card.fsrsPayload)), expectedSummary)
            expected.fsrsPayload = card.fsrsPayload; expected.dueDate = resetTime; expected.updatedAt = resetTime
            XCTAssertEqual(card, expected)
        }
        XCTAssertEqual(try repo.noteItems().first { $0.noteID == id }?.sourceContent.answer, "修正版の答え")
    }
    func testDeckUpdateStaleContentTagsAndScheduleRejectConsent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, id, destination) = try updateFixture(root)
        let package = try updatePackage(repo, noteID: id) { note in
            var content = note.content; content.hint = "受信ヒント"
            return SharedNote(id: note.id, deckID: note.deckID, kind: note.kind, content: content, responseMode: note.responseMode, tags: note.tags)
        }
        for change in 0..<3 {
            let preview = try repo.previewDeckImport(package, destination: destination)
            try repo.transaction {
                let note = try XCTUnwrap(repo.notes().first { $0.id == id })
                if change == 0 { var content = try JSONDecoder().decode(TextContent.self, from: note.contentPayload); content.hint = "同時編集"; note.contentPayload = try JSONEncoder().encode(content) }
                if change == 1 { note.tagIDs = try repo.tagIDs(for: ["同時タグ"]) }
                if change == 2 { let card = try XCTUnwrap(repo.cards().first { $0.noteID == id }); card.dueDate = now.addingTimeInterval(500) }
            }
            let before = try BackupData.capture(repo)
            XCTAssertThrowsError(try repo.importDeckPackageReceipt(package, skipDuplicates: true, now: now, destination: destination, expectedPreview: preview, updates: [id: .preserveHistory]))
            XCTAssertEqual(try BackupData.capture(repo), before)
        }
    }
}

extension BackupRepositoryTests {
    func testDeckUpdateMediaRollbackAndUnchangedAttachmentIDs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, id, destination) = try updateFixture(root)
        let imageID = try XCTUnwrap(repo.assets().first).id
        try repo.transaction {
            let note = try XCTUnwrap(repo.notes().first { $0.id == id })
            var content = try JSONDecoder().decode(TextContent.self, from: note.contentPayload)
            content.imageID = imageID; note.contentPayload = try JSONEncoder().encode(content)
        }
        let keep = try updatePackage(repo, noteID: id) { note in
            var content = note.content; content.hint = "画像維持"
            return SharedNote(id: note.id, deckID: note.deckID, kind: note.kind, content: content, responseMode: note.responseMode, tags: note.tags)
        }
        let before = try BackupData.capture(repo)
        let preview = try repo.previewDeckImport(keep, destination: destination)
        try repo.importDeckPackageReceipt(keep, skipDuplicates: true, now: now, destination: destination, expectedPreview: preview, updates: [id: .preserveHistory])
        XCTAssertEqual(try BackupData.capture(repo).media, before.media)
        XCTAssertEqual(try repo.noteItems().first { $0.noteID == id }?.sourceContent.imageID, imageID)
        let original = keep.package
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40), format: format).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }.pngData()!
        let replacement = UUID()
        let media = original.media + [SharedMedia(id: replacement, mediaType: "image/png", width: 80, height: 40, sha256: BackupArchive.hash(bytes))]
        let notes = original.notes.map { note -> SharedNote in
            guard note.id == id else { return note }
            var content = note.content; content.imageID = replacement
            return SharedNote(id: note.id, deckID: note.deckID, kind: note.kind, content: content, responseMode: note.responseMode, tags: note.tags)
        }
        var mediaBytes = keep.bytes; mediaBytes[replacement] = bytes
        let changed = try DeckExchange.validated(package: DeckPackage(rootID: original.rootID, decks: original.decks, notes: notes, media: media), bytes: mediaBytes)
        let changedPreview = try repo.previewDeckImport(changed, destination: destination)
        XCTAssertTrue(try XCTUnwrap(changedPreview.updates.first).requiresReset)
        XCTAssertTrue(changedPreview.updates[0].changes.contains { $0.id == "画像" })
        let failureBefore = try BackupData.capture(repo)
        func files() -> Set<String> {
            let enumerator = FileManager.default.enumerator(at: repo.mediaStore.root, includingPropertiesForKeys: [.isRegularFileKey])
            return Set((enumerator?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.map(\.path))
        }
        let beforeFiles = files()
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.importDeckPackageReceipt(changed, skipDuplicates: true, now: now, destination: destination, expectedPreview: changedPreview, updates: [id: .resetSchedule]))
        XCTAssertEqual(try BackupData.capture(repo).canonical(), failureBefore.canonical())
        XCTAssertEqual(files(), beforeFiles)
        repo.save = { try $0.save() }
        let fresh = try repo.previewDeckImport(changed, destination: destination)
        try repo.importDeckPackageReceipt(changed, skipDuplicates: true, now: now, destination: destination, expectedPreview: fresh, updates: [id: .resetSchedule])
        let updated = try XCTUnwrap(repo.noteItems().first { $0.noteID == id })
        let updatedImage = try XCTUnwrap(updated.sourceContent.imageID)
        XCTAssertNotEqual(updatedImage, imageID); XCTAssertNotEqual(updatedImage, replacement)
        XCTAssertEqual(try Data(contentsOf: repo.assetURL(id: updatedImage)), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try repo.assetURL(id: imageID).path))
        XCTAssertEqual(try repo.logs().map(BackupStudyReviewLog.init), failureBefore.logs)
        XCTAssertEqual(try BackupData.capture(repo).cards.filter { $0.noteID != id }, failureBefore.cards.filter { $0.noteID != id })
    }
}

extension BackupRepositoryTests {
    func testExamPlansOptionalBackupRestoreAndValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root.appendingPathComponent("source"))
        let deck = try source.decks()[0].id
        let legacy = try await BackupService.export(repository: source, now: now, appVersion: "test")
        XCTAssertNil(try JSONDecoder().decode(StudyOptions.self, from: BackupArchive.decode(legacy).data.options[0].payload).examPlans)
        let plan = ExamPlan(name: "試験", year: 2026, month: 10, day: 20, scope: LearningScope(deckID: deck))
        try source.saveExamPlan(plan)
        let decoded = try BackupArchive.decode(await BackupService.export(repository: source, now: now, appVersion: "test"))
        let destination = try fixture(root.appendingPathComponent("destination"))
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("destination/Study.store"))
        _ = try BackupService.restore(decoded, location: location, mediaStore: destination.mediaStore, now: now)
        let reopened = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: location.canonicalStore), mediaStore: destination.mediaStore)
        XCTAssertEqual(try reopened.options().examPlans, [plan])
        XCTAssertEqual(try BackupData.capture(reopened).cards, decoded.data.cards)
        var invalid = decoded.data, options = try source.options()
        var bad = plan; bad.day = 32; options.examPlans = [bad]
        invalid.options[0].payload = try JSONEncoder().encode(options)
        XCTAssertThrowsError(try BackupValidation.validate(invalid, media: decoded.media))
        options.examPlans = [plan, plan]; invalid.options[0].payload = try JSONEncoder().encode(options)
        XCTAssertThrowsError(try BackupValidation.validate(invalid, media: decoded.media))
    }
}
