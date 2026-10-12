import XCTest
import UIKit
import ImageIO
import SwiftData
@testable import AnkiIOS

@MainActor
final class MediaRepositoryTests: XCTestCase {
    func testDisplayThumbnailOrientationAlphaCacheBudgetAndInvalidation() async throws {
        let loader = DisplayImageLoader(maximumBytes: 1_000_000)
        let original = try XCTUnwrap(UIImage(data: imageData())?.cgImage)
        for orientation in 1...8 {
            let bytes = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, original, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let image = try await loader.load(data: bytes as Data, pixels: 512)
            XCTAssertEqual(max(image.width, image.height), 512)
            XCTAssertEqual(image.width, orientation >= 5 ? 256 : 512)
            XCTAssertEqual(image.height, orientation >= 5 ? 512 : 256)
            let cost = await loader.cachedBytes
            XCTAssertLessThanOrEqual(cost, 1_000_000)
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 50, y: 25, width: 100, height: 50))
        }.pngData())
        let transparent = try await loader.load(data: png, pixels: 256)
        XCTAssertTrue([CGImageAlphaInfo.premultipliedFirst, .premultipliedLast, .first, .last].contains(transparent.alphaInfo))
        let before = await loader.decodeCount
        _ = try await loader.load(data: png, pixels: 256)
        let after = await loader.decodeCount
        XCTAssertEqual(before, after)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("image.png"), namespace = UUID()
        try png.write(to: file)
        _ = try await loader.load(file: file, namespace: namespace, pixels: 256)
        _ = try await loader.load(file: file, namespace: UUID(), pixels: 256)
        let namespaces = await loader.decodeCount
        XCTAssertEqual(namespaces, after + 2)
        try imageData().write(to: file)
        let changed = try await loader.load(file: file, namespace: namespace, pixels: 256)
        XCTAssertEqual(changed.width, 256)
        XCTAssertEqual(changed.height, 128)
        try FileManager.default.removeItem(at: file)
        do { _ = try await loader.load(file: file, namespace: namespace, pixels: 256); XCTFail("Deleted file must not use cached pixels") } catch { }
        do { _ = try await loader.load(data: Data("broken".utf8), pixels: 256); XCTFail("Corrupt image accepted") } catch { }
        let cancelled = Task { try await loader.load(data: png, pixels: 256) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled load returned pixels") } catch is CancellationError { }
        await loader.clearCache()
        let empty = await loader.cachedBytes
        XCTAssertEqual(empty, 0)
    }
    func testTwentyLargeImageDisplayDecodesAndCacheStayBounded() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let bytes = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
            ("日本語の図表・細字 / PHOTO" as NSString).draw(at: CGPoint(x: 500, y: 500), withAttributes: [.font: UIFont.systemFont(ofSize: 64), .foregroundColor: UIColor.black])
        }.jpegData(compressionQuality: 0.95))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = (0..<20).map { directory.appendingPathComponent("\($0).jpg") }
        for file in files { try bytes.write(to: file) }
        let legacyStart = Date()
        var fullBytes = 0
        for file in files {
            try autoreleasepool {
                let original = try XCTUnwrap(UIImage(contentsOfFile: file.path))
                let decoded = UIGraphicsImageRenderer(size: original.size, format: format).image { _ in original.draw(at: .zero) }
                let cg = try XCTUnwrap(decoded.cgImage)
                fullBytes = cg.bytesPerRow * cg.height
            }
        }
        let legacyMs = Date().timeIntervalSince(legacyStart) * 1000
        let loader = DisplayImageLoader(), namespace = UUID(), thumbnailStart = Date()
        var thumbnailBytes = 0
        for file in files {
            let image = try await loader.load(file: file, namespace: namespace, pixels: 1536)
            XCTAssertLessThanOrEqual(max(image.width, image.height), 1536)
            thumbnailBytes = image.bytesPerRow * image.height
        }
        let thumbnailMs = Date().timeIntervalSince(thumbnailStart) * 1000
        let held = await loader.cachedBytes
        XCTAssertLessThanOrEqual(held, 24 * 1024 * 1024)
        XCTAssertEqual(try Data(contentsOf: files[0]), bytes)
        print("IMAGE_DISPLAY images=20 source=4000x3000 full_ms=\(legacyMs) thumbnail_ms=\(thumbnailMs) full_bitmap_bytes=\(fullBytes) thumbnail_bitmap_bytes=\(thumbnailBytes) cache_bytes=\(held)")
        await loader.clearCache()
        let cleared = await loader.cachedBytes
        XCTAssertEqual(cleared, 0)
    }
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
    func testDirectoryURLsAndSymlinkEscapeAreHandledSafely() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Media", isDirectory: true)
        let outside = base.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let media = MediaStore(root: root)
        let file = try media.url(for: "images/new.jpg")
        XCTAssertTrue(file.isFileDescendant(of: root))
        XCTAssertFalse(root.isFileDescendant(of: root))
        XCTAssertFalse(outside.isFileDescendant(of: root))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertThrowsError(try media.url(for: "escape/new.jpg"))
    }
    func testVisionOCRRecognizesLocalFixture() async throws {
        let result = try await OCRService.recognize(imageData())
        XCTAssertTrue(result.text.uppercased().contains("TOKYO"), result.text)
        XCTAssertFalse(result.languages.isEmpty)
    }
    func testVisionOCRRecognizesJapaneseLocalFixture() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 400), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 400))
            ("日本の首都は東京です" as NSString).draw(at: CGPoint(x: 40, y: 80), withAttributes: [.font: UIFont.systemFont(ofSize: 80), .foregroundColor: UIColor.black])
        }
        let result = try await OCRService.recognize(XCTUnwrap(image.pngData()))
        XCTAssertTrue(result.text.contains("日本"))
        XCTAssertTrue(result.text.contains("東京"))
        XCTAssertTrue(result.languages.contains("ja-JP"))
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
    func testPNGAndJPEGOriginalBytesStayUntouched() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MediaStore(root: dir)
        let png = imageData()
        let image = try XCTUnwrap(UIImage(data: png))
        let jpg = try XCTUnwrap(image.jpegData(compressionQuality: 0.97))
        for (bytes, kind, ext) in [(png, "image/png", "png"), (jpg, "image/jpeg", "jpg")] {
            let stored = try store.store(bytes)
            XCTAssertEqual(stored.mediaType, kind)
            XCTAssertEqual(URL(fileURLWithPath: stored.relativePath).pathExtension, ext)
            XCTAssertEqual(try Data(contentsOf: store.url(for: stored.relativePath)), bytes)
            XCTAssertEqual(stored.sha256, BackupArchive.hash(bytes))
        }
    }

    func testExifJPEGKeepsBytesAndWorksWithCropOCRAndBackup() async throws {
        func jpeg(_ image: UIImage, orientation: Int) throws -> Data {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage),
                                      [kCGImagePropertyOrientation: orientation,
                                       kCGImageDestinationLossyCompressionQuality: 0.97] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return data as Data
        }
        let original = try XCTUnwrap(UIImage(data: imageData()))
        for orientation in 1...8 {
            let bytes = try jpeg(original, orientation: orientation)
            let prepared = try ImageEncodingPolicy.prepare(bytes)
            XCTAssertEqual(prepared.data, bytes, "EXIF orientation must not cause JPEG recompression")
            XCTAssertEqual(prepared.width, 800)
            XCTAssertEqual(prepared.height, 400)
        }
        // Rotate encoded pixels counterclockwise, then attach EXIF right rotation.
        // The displayed text is upright, just as with a portrait camera JPEG.
        let sideways = UIImage(cgImage: try XCTUnwrap(original.cgImage), scale: 1, orientation: .left)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let encodedPixels = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 800), format: format).image { _ in
            sideways.draw(in: CGRect(x: 0, y: 0, width: 400, height: 800))
        }
        let bytes = try jpeg(encodedPixels, orientation: 6)
        XCTAssertEqual(UIImage(data: bytes)?.imageOrientation, .right)
        let cropped = try ImageEncodingPolicy.prepare(bytes, crop: MaskRect(x: 0, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(cropped.width, 400)
        XCTAssertEqual(cropped.height, 200)
        XCTAssertEqual(UIImage(data: cropped.data)?.imageOrientation, .up)
        let recognized = try await OCRService.recognize(bytes)
        XCTAssertTrue(recognized.text.contains("TOKYO"), recognized.text)
        XCTAssertTrue(recognized.text.contains("CAPITAL"), recognized.text)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = MediaStore(root: root.appendingPathComponent("Media"))
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true), mediaStore: media)
        try repo.initialize(now: now)
        let assetID = try repo.addImage(bytes, now: now)
        let mask = ImageMask(rect: MaskRect(x: 0.1, y: 0.1, width: 0.5, height: 0.25))
        try repo.createNote(NoteInput(deckID: try repo.decks()[0].id, kind: .imageOcclusion,
                                      question: "Rotated image", answer: "Tokyo", imageID: assetID, masks: [mask]), now: now)
        let before = try repo.noteItems()
        let backup = try BackupArchive.decode(await BackupService.export(repository: repo, now: now, appVersion: "audit"))
        let container = try BackupService.restore(backup, location: StudyStorageLocation(canonicalStore: root.appendingPathComponent("Study.store")), mediaStore: media, now: now)
        let restored = StudyRepository(container: container, mediaStore: media)
        XCTAssertEqual(try Data(contentsOf: restored.assetURL(id: assetID)), bytes)
        XCTAssertEqual(try restored.assets()[0].width, 400)
        XCTAssertEqual(try restored.assets()[0].height, 800)
        XCTAssertEqual(Set(try restored.noteItems().map(\.cardID)), Set(before.map(\.cardID)))
        XCTAssertEqual(try restored.noteItems()[0].sourceContent.masks, [mask])
    }

    func testTransparentPNGRemainsLosslessAndCroppedPNGIsStillPNG() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 50, y: 25, width: 100, height: 50))
        }
        let bytes = try XCTUnwrap(image.pngData())
        let result = try ImageEncodingPolicy.prepare(bytes)
        XCTAssertEqual(result.mediaType, "image/png")
        XCTAssertEqual(result.data, bytes)
        let rect = MaskRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let cropped = try ImageEncodingPolicy.prepare(bytes, crop: rect)
        XCTAssertEqual(cropped.mediaType, "image/png")
        XCTAssertEqual(cropped.width, 100)
        XCTAssertEqual(cropped.height, 50)
        XCTAssertNotNil(UIImage(data: cropped.data)?.cgImage)
        // Mask coordinates stay proportional after resampling/cropping.
        XCTAssertEqual(rect.frame(in: CGSize(width: 400, height: 200)).width,
                       2 * rect.frame(in: CGSize(width: 200, height: 100)).width)
    }

    func testPNGRequiresCompleteChunksEndMarkerAndCorrectCRC() throws {
        let image = imageData()
        XCTAssertThrowsError(try ImageEncodingPolicy.prepare(Data(image.dropLast(12))))
        var badCRC = image
        badCRC[29] ^= 1 // IHDR checksum; pixel dimensions are still decodable.
        XCTAssertThrowsError(try ImageEncodingPolicy.prepare(badCRC))
        let valid = try ImageEncodingPolicy.prepare(image)
        XCTAssertEqual(valid.data, image)
    }

    func testLargeCorruptAndUnwritableMediaFailWithoutAssetCreation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = imageData()
        XCTAssertThrowsError(try ImageEncodingPolicy.prepare(Data(repeating: 0, count: 20_000_001))) { error in
            guard case MediaError.tooLarge = error else { return XCTFail("Expected size limit") }
        }
        XCTAssertThrowsError(try ImageEncodingPolicy.prepare(Data(image.prefix(image.count / 2))))
        let store = MediaStore(root: root)
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: root)
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true), mediaStore: store)
        try repo.initialize(now: now)
        XCTAssertThrowsError(try repo.addImage(image, now: now)) { error in
            guard case MediaError.saveFailed = error else { return XCTFail("Expected save failure") }
        }
        XCTAssertTrue(try repo.assets().isEmpty)
    }

    func testReferencedPNGSurvivesOrphanCleanup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MediaStore(root: dir)
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true), mediaStore: store)
        try repo.initialize(now: now)
        let id = try repo.addImage(imageData(), now: now)
        let deck = try XCTUnwrap(repo.decks().first).id
        try repo.saveEditorDraft(key: "new", input: NoteInput(deckID: deck, question: "Draft", imageID: id), now: now)
        let orphan = try store.store(imageData())
        try repo.cleanupUnusedMedia()
        XCTAssertEqual(try repo.assets().first?.mediaType, "image/png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try repo.assetURL(id: id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.url(for: orphan.relativePath).path))
    }
    func testStoredTextScreenshotOCRMatchesOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = imageData()
        let expected = try await OCRService.recognize(image)
        let result = try MediaStore(root: root).store(image)
        let bytes = try Data(contentsOf: MediaStore(root: root).url(for: result.relativePath))
        let recognized = try await OCRService.recognize(bytes)
        XCTAssertEqual(recognized.text, expected.text)
        XCTAssertTrue(recognized.text.uppercased().contains("TOKYO"))
    }
}

extension MediaRepositoryTests {
    func imagePackage(count: Int = 1) throws -> ImageImportPackage {
        let csv = "question,answer,image,explanation,tags,deck\n" + (0..<count).map { ",答え\($0),images/test.png,解説,日本;地理,教材/図版" }.joined(separator: "\n")
        return try ImageImportPackage.read(StoredZIP.write(["cards.csv": Data(csv.utf8), "images/test.png": imageData()]))
    }
    func testImageZIP300RowsDeduplicatedImagesAndUpdatePreserveSchedules() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true), mediaStore: MediaStore(root: dir))
        try repo.initialize(now: now)
        let deck = try repo.decks()[0].id, package = try imagePackage(count: 300)
        XCTAssertEqual(try repo.assets().count, 0) // Preview has no side effects.
        XCTAssertEqual(try repo.importImagePackage(package, deckID: deck, action: .skip, now: now).imported, 300)
        XCTAssertEqual(try repo.assets().count, 1)
        XCTAssertEqual(try repo.cards().count, 300)
        XCTAssertEqual(try repo.tags().count, 2)
        XCTAssertTrue(try repo.notes().allSatisfy { (try? JSONDecoder().decode(TextContent.self, from: $0.contentPayload).question) == "画像を見て答えてください" })
        XCTAssertEqual(try repo.importImagePackage(package, deckID: deck, action: .skip, now: now).skipped, 300)
        try repo.start(mode: .new, now: now)
        try repo.updateDraft(revealed: true, now: now); try repo.grade(.good, now: now)
        let schedules = Dictionary(uniqueKeysWithValues: try repo.cards().map { ($0.id, $0.fsrsPayload) })
        let logs = try repo.logs().map(\.id)
        var changed = package
        changed.rows = Array(changed.rows.prefix(1)); changed.rows[0].explanation = "更新した解説"
        XCTAssertEqual(try repo.importImagePackage(changed, deckID: deck, action: .update, now: now).imported, 1)
        XCTAssertEqual(try repo.logs().map(\.id), logs)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try repo.cards().map { ($0.id, $0.fsrsPayload) }), schedules)
    }
    func testImageZIPSaveFailureRollsBackDecksCardsAndFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true), mediaStore: MediaStore(root: dir))
        try repo.initialize(now: now)
        let deck = try repo.decks()[0].id, count = try repo.decks().count
        try repo.createNote(NoteInput(deckID: deck, question: "既存", answer: "履歴保持"), now: now)
        try repo.start(mode: .new, now: now); try repo.updateDraft(revealed: true, now: now); try repo.grade(.good, now: now)
        let before = try BackupData.capture(repo)
        repo.save = { _ in throw Failure.save }
        XCTAssertThrowsError(try repo.importImagePackage(imagePackage(), deckID: deck, action: .add, now: now))
        XCTAssertTrue(try repo.assets().isEmpty); XCTAssertEqual(try repo.notes().count, 1)
        XCTAssertEqual(try BackupData.capture(repo), before); XCTAssertEqual(try repo.decks().count, count)
        let images = dir.appendingPathComponent("images")
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: images.path).isEmpty) ?? true)
    }
    func testImageZIPRowErrorsAndExcludedRows() throws {
        let csv = "answer,image\n答え,images/missing.png\n答え,../test.png\n答え,images/broken.png\n,images/test.png\n答え,images/test.png"
        var package = try ImageImportPackage.read(StoredZIP.write(["cards.csv": Data(csv.utf8), "images/broken.png": Data([1,2]), "images/test.png": imageData()]))
        XCTAssertEqual(package.rows.filter { $0.error != nil }.count, 4)
        package.rows[4].included = false
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true))
        try repo.initialize(now: now)
        let result = try repo.importImagePackage(package, deckID: repo.decks()[0].id, action: .skip, now: now)
        XCTAssertEqual(result.imported, 0); XCTAssertEqual(result.errors.count, 4); XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(try repo.assets().isEmpty)
    }
    func testImageZIPRejectsAmbiguousPathsCorruptionAndMultipleTables() throws {
        let image = imageData()
        XCTAssertThrowsError(try ImageImportZIP.read(StoredZIP.write(["images/A.png": image, "images/a.png": image])))
        XCTAssertThrowsError(try ImageImportPackage.read(StoredZIP.write(["cards.csv": Data(), "cards.tsv": Data()])))
        var corrupt = try StoredZIP.write(["cards.csv": Data("answer,image\nA,images/a.png".utf8), "images/a.png": image])
        corrupt[40] ^= 1
        XCTAssertThrowsError(try ImageImportZIP.read(corrupt))
        XCTAssertThrowsError(try ImageImportZIP.read(Data([1,2,3])))
    }
}

extension MediaRepositoryTests {
    func testImageZIPReadsStandardDeflateDirectoriesAndComment() throws {
        let archive = Data(base64Encoded: "UEsDBBQAAAAIAINJS10d1e5AGAAAABsAAAAJAAAAY2FyZHMuY3N2S8wrLk8t0snMTUxP5XKE0MX6iXoFeekAUEsDBBQAAAAIAINJS10AAAAAAgAAAAAAAAAHAAAAaW1hZ2VzLwMAUEsBAhQDFAAAAAgAg0lLXR3V7kAYAAAAGwAAAAkAAAAAAAAAAAAAAIABAAAAAGNhcmRzLmNzdlBLAQIUAxQAAAAIAINJS10AAAAAAgAAAAAAAAAHAAAAAAAAAAAAEAD9QT8AAABpbWFnZXMvUEsFBgAAAAACAAIAbAAAAGYAAAAHAGZpeHR1cmU=")!
        let files = try ImageImportZIP.read(archive)
        XCTAssertEqual(String(data: files["cards.csv"]!, encoding: .utf8), "answer,image\nA,images/a.png")
        XCTAssertNil(files["images/"])
        XCTAssertThrowsError(try StoredZIP.read(archive)) // Backup profile remains strict.
    }
}

extension MediaRepositoryTests {
    func testImageZIPDescriptorsBombAndSymlink() throws {
        let descriptor = Data(base64Encoded: "UEsDBBQACAAIAA9KS10AAAAAAAAAAAAAAAAJAAAAY2FyZHMuY3N2S8wrLk8t0snMTUxP5XKE0MX6iXoFeekAUEsHCB3V7kAYAAAAGwAAAFBLAQIUAxQACAAIAA9KS10d1e5AGAAAABsAAAAJAAAAAAAAAAAAAACAAQAAAABjYXJkcy5jc3ZQSwUGAAAAAAEAAQA3AAAATwAAAAAA")!
        XCTAssertEqual(try ImageImportZIP.read(descriptor)["cards.csv"], Data("answer,image\nA,images/a.png".utf8))
        let bomb = Data(base64Encoded: "UEsDBBQAAAAIAA9KS10bEJrYJQAAACBOAAAJAAAAY2FyZHMuY3N27cExAQAAAMKgbOtfyhoeQAEAAAAAAAAAAAAAAAAAAAAAAADwYFBLAQIUAxQAAAAIAA9KS10bEJrYJQAAACBOAAAJAAAAAAAAAAAAAACAAQAAAABjYXJkcy5jc3ZQSwUGAAAAAAEAAQA3AAAATAAAAAAA")!
        XCTAssertThrowsError(try ImageImportZIP.read(bomb))
        let link = Data(base64Encoded: "UEsDBBQAAAAAAAAAIQCgveGDDAAAAAwAAAAPAAAAaW1hZ2VzL2xpbmsucG5nL3RtcC9vdXRzaWRlUEsBAhQDFAAAAAAAAAAhAKC94YMMAAAADAAAAA8AAAAAAAAAAAAAAP+hAAAAAGltYWdlcy9saW5rLnBuZ1BLBQYAAAAAAQABAD0AAAA5AAAAAAA=")!
        XCTAssertThrowsError(try ImageImportZIP.read(link))
        var traversal = try StoredZIP.write(["images/a.png": Data([0])])
        let original = Data("images/a.png".utf8), replacement = Data("../evilx.png".utf8)
        while let range = traversal.range(of: original) { traversal.replaceSubrange(range, with: replacement) }
        XCTAssertThrowsError(try ImageImportZIP.read(traversal))
    }
}

extension MediaRepositoryTests {
    func testImageZIPRejectsDisguisedGIFAndDetectsTSVBOM() throws {
        let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
        let table = "\u{feff}answer\timage\n名称\timages/fake.png"
        let package = try ImageImportPackage.read(StoredZIP.write(["cards.tsv": Data(table.utf8), "images/fake.png": gif]))
        XCTAssertEqual(package.rows[0].answer, "名称")
        XCTAssertNotNil(package.rows[0].error)
        XCTAssertTrue(package.images.isEmpty)
    }
}

extension MediaRepositoryTests {
    func testRegistrationCountsMatchBasicReverseClozeAndMasksAndZIPUpdates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true), mediaStore: MediaStore(root: root))
        try repo.initialize(now: now)
        let deck = try repo.decks()[0].id, image = try repo.addImage(imageData(), now: now)
        try repo.createNote(NoteInput(deckID: deck, question: "Normal", answer: "A"), now: now)
        try repo.createNote(NoteInput(deckID: deck, question: "Reverse", answer: "A", reverseEnabled: true), now: now)
        try repo.createNote(NoteInput(deckID: deck, kind: .cloze, question: "{{c1::one}} {{c2::two}}"), now: now)
        let masks = [ImageMask(rect: MaskRect(x: 0, y: 0, width: 0.3, height: 0.3), answer: "one"), ImageMask(rect: MaskRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3), answer: "two")]
        try repo.createNote(NoteInput(deckID: deck, kind: .imageOcclusion, question: "Masks", imageID: image, masks: masks), now: now)
        let items = try repo.noteItems()
        XCTAssertEqual(Set(items.map(\.noteID)).count, 4); XCTAssertEqual(items.count, 7)
        XCTAssertEqual(Dictionary(grouping: items, by: \.noteID).values.map(\.count).sorted(), [1,2,2,2])
        let package = try imagePackage(count: 2)
        let created = try repo.importImagePackage(package, deckID: deck, action: .skip, now: now)
        XCTAssertEqual(created.createdNotes, 2); XCTAssertEqual(created.createdCards, 2)
        XCTAssertEqual(created.affectedCardIDs.count, 2)
        XCTAssertEqual(created.destinations.count, 1)
        XCTAssertFalse(created.destinations[0].name.isEmpty)
        var repeated = package; repeated.rows = [package.rows[0], package.rows[0]]
        let updated = try repo.importImagePackage(repeated, deckID: deck, action: .update, now: now)
        XCTAssertEqual(updated.imported, 2); XCTAssertEqual(updated.updatedNotes, 1); XCTAssertEqual(updated.maintainedCards, 1)
        XCTAssertEqual(updated.affectedCardIDs.count, 1)
        XCTAssertTrue(updated.affectedCardIDs.isSubset(of: created.affectedCardIDs))
        let skipped = try repo.importImagePackage(package, deckID: deck, action: .skip, now: now)
        XCTAssertEqual(skipped.duplicateRows, 2); XCTAssertEqual(skipped.createdCards + skipped.maintainedCards, 0)
        XCTAssertEqual(skipped.outcome, .empty)
        XCTAssertTrue(skipped.affectedCardIDs.isEmpty)
    }
}
