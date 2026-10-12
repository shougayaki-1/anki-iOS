import Foundation
import SQLite3
import CoreData

struct SnapshotPolicy: Codable, Equatable, Sendable {
    var enabled = true
    var intervalHours = 24
    static let maximumCount = 7
    static let maximumBytes = 512 * 1024 * 1024
    var interval: TimeInterval { Double(intervalHours) * 3600 }
}

enum SnapshotKind: String, Codable, Sendable {
    case automatic, beforeChange, manual
    var title: String {
        switch self { case .automatic: "自動"; case .beforeChange: "変更前"; case .manual: "手動" }
    }
}

struct LocalSnapshot: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let bytes: Int
    let decks: Int
    let cards: Int
    let kind: SnapshotKind
    let reason: String
    let checksum: String
}

/// Separate from Media: snapshot archives are never recursively captured.
/// Hidden staging directories become visible only after a complete archive is verified.
struct LocalSnapshots: Sendable {
    let root: URL
    init(location: StudyStorageLocation) {
        root = location.canonicalStore.deletingPathExtension().appendingPathExtension("snapshots")
    }
    init(root: URL) { self.root = root }
    private var policyURL: URL { root.appendingPathComponent("policy.json") }
    func policy() throws -> SnapshotPolicy {
        guard FileManager.default.fileExists(atPath: policyURL.path) else { return SnapshotPolicy() }
        let value = try JSONDecoder().decode(SnapshotPolicy.self, from: Data(contentsOf: policyURL))
        guard [6, 12, 24, 48].contains(value.intervalHours) else { throw BackupError.invalidData }
        return value
    }
    func savePolicy(_ value: SnapshotPolicy) throws {
        guard [6, 12, 24, 48].contains(value.intervalHours) else { throw BackupError.invalidData }
        try prepareDirectory()
        try JSONEncoder().encode(value).write(to: policyURL, options: [.atomic, .completeFileProtection])
    }
    func list() throws -> [LocalSnapshot] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .compactMap { directory in
                guard let id = UUID(uuidString: directory.lastPathComponent) else { return nil }
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("info.json")), data.count <= 16_384,
                      let value = try? JSONDecoder().decode(LocalSnapshot.self, from: data),
                      value.id == id, value.bytes > 0, value.bytes <= StoredZIP.maximumBytes,
                      value.decks >= 0, value.cards >= 0, value.createdAt.timeIntervalSince1970.isFinite,
                      value.checksum.count == 64, value.reason.count <= 200,
                      FileManager.default.fileExists(atPath: archiveURL(id).path) else { return nil }
                return value
            }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString > $1.id.uuidString : $0.createdAt > $1.createdAt }
    }
    func unreadableCount(entries: [LocalSnapshot]) -> Int {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return max(0, folders.filter { UUID(uuidString: $0.lastPathComponent) != nil }.count - entries.count)
    }
    var diskBytes: Int64 {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        var total: Int64 = 0
        while let url = files?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            if values.isSymbolicLink == true { files?.skipDescendants(); continue }
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }
    /// Only stale unpublished UUID staging folders are removable. Active/recent work and generations stay intact.
    func cleanAbandonedStaging(now: Date) {
        let directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey])) ?? []
        for directory in directories {
            guard directory.lastPathComponent.hasPrefix(".pending-"),
                  UUID(uuidString: String(directory.lastPathComponent.dropFirst(9))) != nil,
                  let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) > 86_400 else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }
    func isDue(now: Date, policy: SnapshotPolicy, entries: [LocalSnapshot]) -> Bool {
        guard policy.enabled else { return false }
        let last = entries.filter { $0.kind == .automatic }.map(\.createdAt).max()
        return last.map { now.timeIntervalSince($0) >= policy.interval } ?? true
    }
    func archiveURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString).appendingPathComponent("snapshot.studybackup") }
    func read(_ entry: LocalSnapshot) throws -> ValidatedBackup {
        let url = archiveURL(entry.id)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) == entry.bytes else { throw BackupError.checksum }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard BackupArchive.hash(data) == entry.checksum else { throw BackupError.checksum }
        return try BackupArchive.decode(data)
    }
    @discardableResult
    func save(_ bytes: Data, kind: SnapshotKind, reason: String, now: Date,
              maximumCount: Int = SnapshotPolicy.maximumCount, maximumBytes: Int = SnapshotPolicy.maximumBytes,
              write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: [.atomic, .completeFileProtection]) }) throws -> LocalSnapshot {
        try Task.checkCancellation()
        guard bytes.count <= maximumBytes, maximumCount > 0 else { throw BackupError.tooLarge }
        let validated = try BackupArchive.decode(bytes)
        try prepareDirectory()
        cleanAbandonedStaging(now: now)
        let id = UUID(), staging = root.appendingPathComponent(".pending-\(UUID().uuidString)")
        let target = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let info = LocalSnapshot(id: id, createdAt: now, bytes: bytes.count, decks: validated.data.decks.count,
                                 cards: validated.data.cards.count, kind: kind, reason: reason, checksum: BackupArchive.hash(bytes))
        let archive = staging.appendingPathComponent("snapshot.studybackup")
        try write(bytes, archive)
        let saved = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard BackupArchive.hash(saved) == info.checksum else { throw BackupError.checksum }
        _ = try BackupArchive.decode(saved)
        let infoURL = staging.appendingPathComponent("info.json")
        try write(JSONEncoder().encode(info), infoURL)
        guard try JSONDecoder().decode(LocalSnapshot.self, from: Data(contentsOf: infoURL)) == info else { throw BackupError.invalidData }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: target) // sole publication point
        // Nothing is deleted until the new generation is fully committed.
        // A pruning failure retains extra generations rather than reporting a successful write as failed.
        if let entries = try? list() {
            var keptBytes = bytes.count, keptCount = 1
            for entry in entries where entry.id != id {
                if keptCount < maximumCount, keptBytes + entry.bytes <= maximumBytes {
                    keptCount += 1; keptBytes += entry.bytes
                } else { try? FileManager.default.removeItem(at: root.appendingPathComponent(entry.id.uuidString)) }
            }
        }
        return info
    }
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.complete])
        var directory = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }
}

/// Runs before SwiftData opens/migrates the database. SQLite's online backup API
/// includes committed WAL pages without racing separate database/sidecar copies.
struct MigrationRescue {
    let location: StudyStorageLocation
    var root: URL { location.canonicalStore.deletingPathExtension().appendingPathExtension("migration-rescue") }
    var marker: URL { root.appendingPathComponent("opened-schema.txt") }
    var archives: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "zip" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    func preserveIfNeeded(schema: String, mediaStore: MediaStore) throws {
        guard (try? String(contentsOf: marker, encoding: .utf8)) != schema else { return }
        let archive = root.appendingPathComponent("before-\(schema).zip")
        let source = try location.activeStore()
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        // Bootstrap a newly installed backup feature without making a full copy
        // when Core Data metadata confirms the store already uses this schema.
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: source, options: [NSReadOnlyPersistentStoreOption: true])
        if let versions = metadata[NSStoreModelVersionIdentifiersKey] as? [String], versions.contains(schema) { return }
        // Do not overwrite the only pre-migration rescue after a failed open/retry.
        guard !FileManager.default.fileExists(atPath: archive.path) else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let temporary = root.appendingPathComponent(".sqlite-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var input: OpaquePointer?, output: OpaquePointer?
        defer { if let input { sqlite3_close(input) }; if let output { sqlite3_close(output) } }
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_open_v2(temporary.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let backup = sqlite3_backup_init(output, "main", input, "main") else { throw BackupError.invalidData }
        let result = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else { throw BackupError.invalidData }
        var files = ["Study.store": try Data(contentsOf: temporary),
                     "README.txt": Data("移行前SQLiteとメディアの救済コピーです。.studybackupではありません。旧アプリでの救済・調査用で、このアプリからの完全復元は保証できません。".utf8)]
        if let enumerator = FileManager.default.enumerator(at: mediaStore.root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { enumerator.skipDescendants(); continue }
                if values.isRegularFile == true {
                    guard url.isFileDescendant(of: mediaStore.root) else { throw BackupError.invalidData }
                    let path = url.pathComponents.dropFirst(mediaStore.root.pathComponents.count).joined(separator: "/")
                    files["Media/" + path] = try Data(contentsOf: url, options: .mappedIfSafe)
                }
            }
        }
        let bytes = try StoredZIP.write(files)
        _ = try StoredZIP.read(bytes)
        try bytes.write(to: archive, options: [.atomic, .completeFileProtection])
    }
    func markOpened(schema: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(schema.utf8).write(to: marker, options: [.atomic, .completeFileProtection])
    }
}
