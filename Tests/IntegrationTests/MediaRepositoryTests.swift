import XCTest
import UIKit
import SwiftData
@testable import AnkiIOS

@MainActor
final class MediaRepositoryTests: XCTestCase {
    enum Failure: Error { case save }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func imageData() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
            ("TOKYO CAPITAL" as NSString).draw(at: CGPoint(x: 30, y: 80), withAttributes: [.font: UIFont.systemFont(ofSize: 64), .foregroundColor: UIColor.black])
        }.pngData()!
    }
    func testMasksAndImageReferenceSurviveRegenerationAndDiskReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Study.store"), media = MediaStore(root: dir.appendingPathComponent("Media"))
        let expected = try writeMasks(url: url, media: media)
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: url), mediaStore: media)
        try repo.initialize(now: now)
        let items = try repo.noteItems()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map(\.cardID)), expected.ids)
        XCTAssertEqual(try repo.logs().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try repo.assetURL(id: expected.imageID).path))
        XCTAssertEqual(try repo.assets()[0].width, 800)
        let input = try XCTUnwrap(repo.editorDraft(key: "new"))
        XCTAssertEqual(input.imageID, expected.imageID)
        XCTAssertEqual(input.tagNames, ["draft"])
        XCTAssertEqual(input.masks.count, 2)
    }
    private func writeMasks(url: URL, media: MediaStore) throws -> (ids: Set<UUID>, imageID: UUID) {
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: url), mediaStore: media)
        try repo.initialize(now: now)
        let imageID = try repo.addImage(imageData(), now: now)
        let a = ImageMask(rect: MaskRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2), answer: "Tokyo")
        let b = ImageMask(rect: MaskRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), answer: "Capital")
        var input = NoteInput(deckID: try repo.decks()[0].id, kind: .imageOcclusion, question: "Image question", answer: "",
                              imageID: imageID, masks: [a, b])
        let note = try repo.createNote(input, now: now)
        let ids = Set(try repo.cards().map(\.id))
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(revealed: true, now: now); try repo.grade(.good, now: now)
        let states = Dictionary(uniqueKeysWithValues: try repo.cards().map { ($0.id, $0.fsrsPayload) })
        input.masks = [b, a]; input.masks[1].rect.x = 0.2
        try repo.updateNote(id: note, input: input, now: now)
        for card in try repo.cards() { XCTAssertEqual(card.fsrsPayload, states[card.id]) }
        input.tagNames = ["draft"]
        try repo.saveEditorDraft(key: "new", input: input, now: now)
        return (ids, imageID)
    }
    func testFailedAssetSaveCleansFileAndInvalidPathsAreRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = MediaStore(root: dir)
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true), mediaStore: media)
        try repo.initialize(now: now)
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.addImage(imageData(), now: now))
        XCTAssertTrue(try repo.assets().isEmpty)
        let images = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("images"), includingPropertiesForKeys: nil)
        XCTAssertTrue(images.isEmpty)
        XCTAssertThrowsError(try media.url(for: "../outside.jpg"))
        XCTAssertThrowsError(try media.url(for: "/absolute.jpg"))
        XCTAssertThrowsError(try media.store(Data("invalid".utf8)))
    }
    func testNormalizedGeometryAndCrop() throws {
        let rect = MaskRect(x: 0.25, y: 0.2, width: 0.5, height: 0.3)
        XCTAssertTrue(rect.isValid)
        let small = rect.frame(in: CGSize(width: 200, height: 100))
        let large = rect.frame(in: CGSize(width: 400, height: 200))
        XCTAssertEqual(large.origin.x, small.origin.x * 2)
        XCTAssertEqual(large.size.width, small.size.width * 2)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try MediaStore(root: dir).store(imageData(), crop: MaskRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        XCTAssertEqual(result.width, 400); XCTAssertEqual(result.height, 200)
        XCTAssertFalse(MaskRect(x: 0.8, y: 0, width: 0.3, height: 1).isValid)
    }
    func testVisionOCRRecognizesLocalFixture() async throws {
        let result = try await OCRService.recognize(imageData())
        XCTAssertTrue(result.text.uppercased().contains("TOKYO"), result.text)
        XCTAssertFalse(result.languages.isEmpty)
    }
    func testDraftCommitFailureAndOrphanCleanupProtectReferencedImages() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = MediaStore(root: dir)
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true), mediaStore: media)
        try repo.initialize(now: now)
        let id = try repo.addImage(imageData(), now: now)
        let input = NoteInput(deckID: try repo.decks()[0].id, question: "Q", answer: "A", imageID: id)
        try repo.saveEditorDraft(key: "new", input: input, now: now)
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.createNote(input, clearingDraft: "new", now: now))
        XCTAssertEqual(try repo.editorDraft(key: "new")?.imageID, id)
        XCTAssertTrue(try repo.notes().isEmpty)
        repo.save = { try $0.save() }
        let orphan = try media.store(imageData())
        try repo.cleanupUnusedMedia()
        XCTAssertTrue(FileManager.default.fileExists(atPath: try repo.assetURL(id: id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try media.url(for: orphan.relativePath).path))
        try repo.createNote(input, clearingDraft: "new", now: now)
        XCTAssertNil(try repo.editorDraft(key: "new"))
        try repo.cleanupUnusedMedia()
        XCTAssertTrue(FileManager.default.fileExists(atPath: try repo.assetURL(id: id).path))
    }
    func testV2ToV3MigrationKeepsTagsScopeAndPreferences() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Study.store")
        let ids = try writeV2(url)
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(storeURL: url))
        try repo.initialize(now: now)
        XCTAssertEqual(try repo.tags().map(\.id), [ids.tag])
        XCTAssertEqual(try repo.scope(), LearningScope(deckID: ids.deck, tagIDs: [ids.tag]))
        XCTAssertEqual(try repo.options().siblingBuryEnabled, false)
        XCTAssertEqual(try repo.context.fetch(FetchDescriptor<ImportBatch>()).first?.successCount, 2)
        XCTAssertTrue(try repo.assets().isEmpty)
        try repo.saveEditorDraft(key: "new", input: NoteInput(deckID: ids.deck, question: "draft"), now: now)
        XCTAssertEqual(try repo.editorDraft(key: "new")?.question, "draft")
    }
    private func writeV2(_ url: URL) throws -> (deck: UUID, tag: UUID) {
        let schema = Schema(versionedSchema: StudySchemaV2.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration("Study", schema: schema, url: url, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let deck = Deck(name: "V2", now: now), tag = Tag(name: "Tag", normalizedName: "tag")
        context.insert(deck); context.insert(tag); context.insert(StudyPreferences())
        context.insert(try SessionScope(scope: LearningScope(deckID: deck.id, tagIDs: [tag.id])))
        context.insert(try ExtraPreferences(options: StudyOptions(siblingBuryEnabled: false)))
        context.insert(ImportBatch(source: "paste", now: now, success: 2, skipped: 1, errors: []))
        try context.save()
        return (deck.id, tag.id)
    }
    func testDeletionRemovesEditDraftAndBrokenReferencesPreventCleanup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true), mediaStore: MediaStore(root: dir))
        try repo.initialize(now: now)
        let id = try repo.addImage(imageData(), now: now)
        var input = NoteInput(deckID: try repo.decks()[0].id, question: "Q", answer: "A", imageID: id)
        let note = try repo.createNote(input, now: now)
        let key = "edit:\(note.uuidString)"
        try repo.saveEditorDraft(key: key, input: input, now: now)
        try repo.deleteNote(id: note)
        XCTAssertNil(try repo.editorDraft(key: key))
        let file = try repo.assetURL(id: id)
        input.imageID = UUID()
        try repo.saveEditorDraft(key: "new", input: input, now: now)
        XCTAssertThrowsError(try repo.cleanupUnusedMedia())
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try repo.assets().count, 1)
        try repo.discardEditorDraft(key: "new")
        XCTAssertTrue(try repo.assets().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
