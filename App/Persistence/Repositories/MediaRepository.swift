import Foundation
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
        let noteImages = try notes().compactMap { try JSONDecoder().decode(TextContent.self, from: $0.contentPayload).imageID }
        let drafts = try context.fetch(FetchDescriptor<EditorDraft>())
        let draftImages = try drafts.compactMap { try JSONDecoder().decode(NoteInput.self, from: $0.payload).imageID }
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
        // Scan only the managed images directory, preserving every live asset.
        let retained = Set(try assets().map(\.relativePath))
        let directory = try mediaStore.url(for: "images")
        if FileManager.default.fileExists(atPath: directory.path) {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                let path = "images/" + file.lastPathComponent
                _ = try mediaStore.url(for: path)
                let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if !retained.contains(path), attributes.isRegularFile == true, attributes.isSymbolicLink != true {
                    try mediaStore.remove(path)
                }
            }
        }
        let restored = try mediaStore.url(for: "restored")
        if FileManager.default.fileExists(atPath: restored.path) {
            for folder in try FileManager.default.contentsOfDirectory(at: restored, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                let attributes = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard UUID(uuidString: folder.lastPathComponent) != nil, attributes.isDirectory == true, attributes.isSymbolicLink != true else { continue }
                for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                    guard ["jpg", "png"].contains(file.pathExtension.lowercased()),
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
