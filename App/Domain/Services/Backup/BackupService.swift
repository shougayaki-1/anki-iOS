import Foundation
import SwiftData

@MainActor
struct BackupService {
    static func read(_ url: URL) async throws -> ValidatedBackup {
        try await Task.detached(priority: .utility) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= StoredZIP.maximumBytes else { throw BackupError.tooLarge }
            return try BackupArchive.decode(Data(contentsOf: url, options: .mappedIfSafe))
        }.value
    }
    static func export(repository: StudyRepository, now: Date, appVersion: String) async throws -> Data {
        try repository.pruneTypedAnswers(now: now)
        let snapshot = try BackupData.capture(repository)
        let urls = try repository.assets().map { ($0.id, try repository.mediaStore.url(for: $0.relativePath)) }
        return try await Task.detached(priority: .utility) {
            var media: [UUID: Data] = [:]
            for (id, url) in urls {
                try Task.checkCancellation()
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= ImageEncodingPolicy.maximumBytes else { throw BackupError.tooLarge }
                media[id] = try Data(contentsOf: url, options: .mappedIfSafe)
            }
            return try BackupArchive.create(data: snapshot, media: media, now: now, appVersion: appVersion)
        }.value
    }

    static func restore(_ backup: ValidatedBackup, location: StudyStorageLocation, mediaStore: MediaStore, now: Date,
                        save: (ModelContext) throws -> Void = { try $0.save() }) throws -> ModelContainer {
        // Revalidate even if a caller constructed ValidatedBackup directly.
        try BackupValidation.validate(backup.data, media: backup.media)
        let id = UUID()
        let storeURL = location.restorationStore(id: id)
        let directory = storeURL.deletingLastPathComponent()
        let root = location.canonicalStore.deletingLastPathComponent().resolvingSymlinksInPath()
        guard directory.isFileDescendant(of: root) else { throw BackupError.invalidData }
        let mediaPrefix = "restored/\(id.uuidString)"
        var snapshot = backup.data
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in snapshot.media.indices {
                let assetID = snapshot.media[index].id
                let ext = AudioEncodingPolicy.extensions[snapshot.media[index].mediaType] ?? (snapshot.media[index].mediaType == "image/png" ? "png" : "jpg")
                let path = "\(mediaPrefix)/\(assetID.uuidString).\(ext)"
                let file = try mediaStore.url(for: path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard let data = backup.media[assetID] else { throw BackupError.invalidData }
                try data.write(to: file, options: .atomic)
                snapshot.media[index].relativePath = path
            }
            for index in snapshot.sessions.indices { snapshot.sessions[index].activeSince = nil }
            let container = try PersistenceController.makeStudyContainer(storeURL: storeURL)
            let context = ModelContext(container); context.autosaveEnabled = false
            try snapshot.insert(into: context)
            try save(context)
            let repository = StudyRepository(container: container, mediaStore: mediaStore)
            _ = try repository.noteItems(); _ = try repository.settings()
            let stored = try BackupData.capture(repository)
            guard stored.canonical() == snapshot.canonical() else { throw BackupError.invalidData }
            // This atomic pointer replacement is the sole commit point. A crash before
            // it leaves the original store active; a crash after it opens the validated store.
            try location.activate(id: id)
            return container
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if let folder = try? mediaStore.url(for: mediaPrefix) { try? FileManager.default.removeItem(at: folder) }
            throw error
        }
    }
}

extension BackupData {
    @MainActor func insert(into context: ModelContext) throws {
        for row in decks { try row.insert(into: context) }
        for row in tags { try row.insert(into: context) }
        for row in media { try row.insert(into: context) }
        for row in notes { try row.insert(into: context) }
        for row in cards { try row.insert(into: context) }
        for row in logs { try row.insert(into: context) }
        for row in preferences { try row.insert(into: context) }
        for row in options { try row.insert(into: context) }
        for row in scopes { try row.insert(into: context) }
        for row in sessions { try row.insert(into: context) }
        for row in orderingDrafts ?? [] { row.insert(into: context) }
        for row in typedAnswers ?? [] { context.insert(try SavedTypedAnswer(row)) }
        for row in imports { try row.insert(into: context) }
        for row in editorDrafts { try row.insert(into: context) }
    }
    func canonical() -> Self {
        var value = self
        if value.typedAnswers?.isEmpty == true { value.typedAnswers = nil }
        value.typedAnswers?.sort { $0.id.uuidString < $1.id.uuidString }
        if value.orderingDrafts?.isEmpty == true { value.orderingDrafts = nil }
        value.orderingDrafts?.sort { $0.key < $1.key }
        value.decks.sort { $0.id.uuidString < $1.id.uuidString }; value.notes.sort { $0.id.uuidString < $1.id.uuidString }
        value.cards.sort { $0.id.uuidString < $1.id.uuidString }; value.logs.sort { $0.sequence < $1.sequence }
        value.tags.sort { $0.id.uuidString < $1.id.uuidString }; value.media.sort { $0.id.uuidString < $1.id.uuidString }
        value.imports.sort { $0.id.uuidString < $1.id.uuidString }; value.editorDrafts.sort { $0.key < $1.key }
        return value
    }
}
