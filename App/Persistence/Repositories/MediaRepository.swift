import Foundation
import CryptoKit
import SwiftData

extension StudyRepository {
    func assets() throws -> [MediaAsset] { try context.fetch(FetchDescriptor<MediaAsset>()) }
    func assetURL(id: UUID) throws -> URL {
        guard let asset = try assets().first(where: { $0.id == id }) else { throw StudyError.missingRecord }
        return try mediaStore.url(for: asset.relativePath)
    }
    func addImage(_ data: Data, crop: MaskRect? = nil, now: Date) throws -> UUID {
        let image = try mediaStore.store(data, crop: crop)
        do {
            return try transaction {
                context.insert(MediaAsset(image: image, now: now)); return image.id
            }
        } catch {
            try? mediaStore.remove(image.relativePath)
            throw error
        }
    }
    func editorDraft(key: String) throws -> NoteInput? {
        guard let row = try context.fetch(FetchDescriptor<EditorDraft>()).first(where: { $0.key == key }) else { return nil }
        var input = try JSONDecoder().decode(NoteInput.self, from: row.payload)
        let available = try decks()
        if !available.contains(where: { $0.id == input.deckID }), let fallback = available.first { input.deckID = fallback.id }
        return input
    }
    func saveEditorDraft(key: String, input: NoteInput, now: Date) throws {
        let payload = try JSONEncoder().encode(input)
        try transaction {
            if let row = try context.fetch(FetchDescriptor<EditorDraft>()).first(where: { $0.key == key }) {
                row.payload = payload; row.updatedAt = now
            } else { context.insert(EditorDraft(key: key, payload: payload, now: now)) }
        }
    }
    func removeEditorDraftInTransaction(key: String?) throws {
        guard let key, let row = try context.fetch(FetchDescriptor<EditorDraft>()).first(where: { $0.key == key }) else { return }
        context.delete(row)
    }
    func discardEditorDraft(key: String) throws {
        try transaction { try removeEditorDraftInTransaction(key: key) }
        try cleanupUnusedMedia()
    }
    func cleanupUnusedMedia() throws {
        let noteImages = try notes().flatMap { note -> [UUID] in
            let content = try JSONDecoder().decode(TextContent.self, from: note.contentPayload)
            return [content.imageID].compactMap { $0 } + content.audioIDs
        }
        let drafts = try context.fetch(FetchDescriptor<EditorDraft>())
        let draftImages = try drafts.flatMap { draft -> [UUID] in
            let input = try JSONDecoder().decode(NoteInput.self, from: draft.payload)
            return [input.imageID].compactMap { $0 } + input.audioIDs
        }
        let used = Set(noteImages + draftImages)
        let all = try assets()
        guard used.isSubset(of: Set(all.map(\.id))) else { throw StudyError.missingRecord }
        let unused = all.filter { !used.contains($0.id) }
        let paths = unused.map(\.relativePath)
        // Remove metadata only after every path has been validated.
        for path in paths { _ = try mediaStore.url(for: path) }
        try transaction { for asset in unused { context.delete(asset) } }
        for path in paths { try mediaStore.remove(path) }
        // A process can terminate between writing a file and inserting its row.
        // Scan only managed media directories, preserving every live asset.
        let retained = Set(try assets().map(\.relativePath))
        for directoryName in ["images", "audio"] {
            let directory = try mediaStore.url(for: directoryName)
            if FileManager.default.fileExists(atPath: directory.path) {
                for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                    let path = directoryName + "/" + file.lastPathComponent
                    _ = try mediaStore.url(for: path)
                    let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if !retained.contains(path), attributes.isRegularFile == true, attributes.isSymbolicLink != true {
                        try mediaStore.remove(path)
                    }
                }
            }
        }
        let restored = try mediaStore.url(for: "restored")
        if FileManager.default.fileExists(atPath: restored.path) {
            for folder in try FileManager.default.contentsOfDirectory(at: restored, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                let attributes = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard UUID(uuidString: folder.lastPathComponent) != nil, attributes.isDirectory == true, attributes.isSymbolicLink != true else { continue }
                for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                    guard (["jpg", "png"] + Array(AudioEncodingPolicy.extensions.values)).contains(file.pathExtension.lowercased()),
                          UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
                    let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    let path = "restored/\(folder.lastPathComponent)/\(file.lastPathComponent)"
                    if !retained.contains(path), attributes.isRegularFile == true, attributes.isSymbolicLink != true { try mediaStore.remove(path) }
                }
                if try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty { try FileManager.default.removeItem(at: folder) }
            }
        }
    }
}


extension StudyRepository {
    func addAudio(_ prepared: AudioEncodingPolicy.Prepared, now: Date) throws -> UUID {
        let hash = BackupArchive.hash(prepared.data)
        if let existing = try assets().first(where: { $0.sha256 == hash && $0.mediaType == prepared.mediaType }),
           let url = try? assetURL(id: existing.id),
           let current = try? Data(contentsOf: url), current == prepared.data { return existing.id }
        let asset = try mediaStore.storeAudio(prepared)
        do {
            return try transaction { context.insert(MediaAsset(image: asset, now: now)); return asset.id }
        } catch { try? mediaStore.remove(asset.relativePath); throw error }
    }
}

extension StudyRepository {
    func importImagePackage(_ package: ImageImportPackage, deckID: UUID, action: DuplicateAction, now: Date) throws -> ImportResult {
        let initialNotes = try notes()
        let initialNoteIDs = Set(initialNotes.map(\.id))
        var createdNoteIDs = Set<UUID>(), updatedNoteIDs = Set<UUID>(), createdCardIDs = Set<UUID>(), maintainedCardIDs = Set<UUID>()
        var duplicates = 0
        let selected = package.rows.filter { $0.included && $0.error == nil }
        guard try decks().contains(where: { $0.id == deckID }) else { throw StudyError.missingRecord }
        let fresh = try JSONEncoder().encode(ReviewScheduler(desiredRetention: settings().desiredRetention).newCard(now: now))
        var createdPaths: [String] = []
        do {
            return try transaction {
                var imported = 0, skipped = package.rows.filter { !$0.included }.count
                var errors = package.rows.filter { $0.included }.compactMap { row in row.error.map { "\(row.line)行: \($0)" } }
                var deckCache = try decks(), imageCache: [String: UUID] = [:]
                let known = try assets()
                var assetHashes: [UUID: String] = [:], assetIDsByHash: [String: UUID] = [:]
                for asset in known {
                    assetHashes[asset.id] = asset.sha256
                    if assetIDsByHash[asset.sha256] == nil { assetIDsByHash[asset.sha256] = asset.id }
                }
                var notesByImage: [[String]: Note] = [:], hashCache: [String: String] = [:]
                for note in initialNotes where note.type == NoteKind.basic.rawValue {
                    guard let content = try? JSONDecoder().decode(TextContent.self, from: note.contentPayload),
                          let id = content.imageID, let hash = assetHashes[id] else { continue }
                    let key = [note.deckID.uuidString, ImportParser.normalized(content.question), ImportParser.normalized(content.answer), hash]
                    if notesByImage[key] == nil { notesByImage[key] = note }
                }
                for row in selected {
                    try Task.checkCancellation()
                    guard !ImportParser.normalized(row.question).isEmpty, !ImportParser.normalized(row.answer).isEmpty,
                          let bytes = package.images[row.imagePath] else { errors.append("\(row.line)行: 問題・解答・画像を確認してください。"); continue }
                    var destination = deckID
                    if !row.deckPath.isEmpty {
                        var parent: UUID?
                        for segment in row.deckPath.split(separator: "/") {
                            let name = String(segment)
                            if let existing = deckCache.first(where: { $0.parentID == parent && $0.name == name }) { parent = existing.id }
                            else {
                                let deck = Deck(name: name, now: now); deck.parentID = parent
                                context.insert(deck); deckCache.append(deck); parent = deck.id
                            }
                        }
                        destination = parent ?? deckID
                    }
                    let hash = hashCache[row.imagePath] ?? SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    hashCache[row.imagePath] = hash
                    let key = [destination.uuidString, ImportParser.normalized(row.question), ImportParser.normalized(row.answer), hash]
                    let existing = notesByImage[key]
                    if existing != nil && action == .skip { skipped += 1; duplicates += 1; continue }
                    let imageID: UUID
                    if let cached = imageCache[row.imagePath] { imageID = cached }
                    else if let id = assetIDsByHash[hash] { imageID = id; imageCache[row.imagePath] = imageID }
                    else {
                        let image = try mediaStore.store(bytes); createdPaths.append(image.relativePath)
                        let asset = MediaAsset(image: image, now: now); context.insert(asset); assetIDsByHash[asset.sha256] = image.id; imageID = image.id; imageCache[row.imagePath] = imageID
                    }
                    let input = NoteInput(deckID: destination, question: row.question, answer: row.answer,
                                          explanation: row.explanation, tagNames: row.tags, imageID: imageID)
                    let payload = try validate(input)
                    if let existing, action == .update {
                        if initialNoteIDs.contains(existing.id) {
                            updatedNoteIDs.insert(existing.id)
                            let noteID = existing.id
                            maintainedCardIDs.formUnion(try context.fetch(FetchDescriptor<StudyCard>(predicate: #Predicate { $0.noteID == noteID })).map(\.id))
                        }
                        var content = try JSONDecoder().decode(TextContent.self, from: existing.contentPayload)
                        content.explanation = row.explanation
                        existing.contentPayload = try JSONEncoder().encode(content)
                        existing.tagIDs = try tagIDs(for: row.tags); existing.updatedAt = now
                    } else {
                        let note = Note(input: input, content: payload, now: now)
                        note.tagIDs = try tagIDs(for: row.tags); context.insert(note); createdNoteIDs.insert(note.id)
                        if notesByImage[key] == nil { notesByImage[key] = note }
                        let card = StudyCard(noteID: note.id, variantKey: "basic:front", payload: fresh, now: now)
                        context.insert(card); createdCardIDs.insert(card.id)
                    }
                    imported += 1
                }
                context.insert(ImportBatch(source: "画像ZIP", now: now, success: imported, skipped: skipped, errors: errors))
                return ImportResult(affectedCardIDs: createdCardIDs.union(maintainedCardIDs),
                                    destinations: try importDestinations(noteIDs: createdNoteIDs.union(updatedNoteIDs)),
                                    imported: imported, skipped: skipped, errors: errors, createdNotes: createdNoteIDs.count,
                                    updatedNotes: updatedNoteIDs.count, createdCards: createdCardIDs.count, maintainedCards: maintainedCardIDs.count,
                                    duplicateRows: duplicates, excludedRows: package.rows.filter { !$0.included }.count)
            }
        } catch {
            for path in createdPaths { try? mediaStore.remove(path) }
            throw error
        }
    }
}

extension StudyRepository {
    func imageImportDuplicates(_ package: ImageImportPackage, deckID: UUID) throws -> Set<UUID> {
        let assetHashes = Dictionary(uniqueKeysWithValues: try assets().map { ($0.id, $0.sha256) })
        var keys = Set<[String]>()
        for note in try notes() where note.type == NoteKind.basic.rawValue {
            let content = try JSONDecoder().decode(TextContent.self, from: note.contentPayload)
            if let image = content.imageID, let hash = assetHashes[image] {
                keys.insert([try deckPath(note.deckID), ImportParser.normalized(content.question), ImportParser.normalized(content.answer), hash])
            }
        }
        let fallback = try deckPath(deckID)
        var duplicates = Set<UUID>(), hashCache: [String: String] = [:]
        for row in package.rows where row.error == nil {
            guard let bytes = package.images[row.imagePath] else { continue }
            let hash = hashCache[row.imagePath] ?? SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            hashCache[row.imagePath] = hash
            let key = [row.deckPath.isEmpty ? fallback : row.deckPath, ImportParser.normalized(row.question), ImportParser.normalized(row.answer), hash]
            if !keys.insert(key).inserted { duplicates.insert(row.id) }
        }
        return duplicates
    }
}
