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
            var input = NoteInput(deckID: deck, kind: kind, question: kind == .cloze ? "{{c1::東京}}と{{c2::京都}}" : "問題", answer: "答え", responseMode: .typing, tagNames: ["日本"], reverseEnabled: kind == .basic)
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
        try repo.saveEditorDraft(key: "new", input: NoteInput(deckID: deck, question: "下書き", imageID: image), now: now)
        var options = try repo.settings(); options.notification.enabled = true; options.hapticsMode = .rich
        try repo.updateSettings(options)
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
        XCTAssertEqual(try reopened.settings().hapticsMode, .rich)
        XCTAssertEqual(try reopened.session()?.typedDraft, "未確定の回答")
        let previous = try XCTUnwrap(reopened.logs().last)
        let cardID = previous.cardID, before = previous.fsrsBefore
        try reopened.undo(now: now.addingTimeInterval(10))
        XCTAssertEqual(try reopened.logs().count, 3)
        XCTAssertEqual(try reopened.cards().first(where: { $0.id == cardID })?.fsrsPayload, before)
        XCTAssertEqual(try original.notes().count, 1) // Original store remains intact.
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
        let location = StudyStorageLocation(canonicalStore: root.appendingPathComponent("Study.store"))
        try Data("{\"schemaVersion\":1,\"relativePath\":\"../outside.store\"}".utf8).write(to: location.pointer)
        XCTAssertThrowsError(try PersistenceController.makeStudyContainer(storeURL: location.canonicalStore))
        XCTAssertEqual(try repo.logs().count, 1)
    }
}
