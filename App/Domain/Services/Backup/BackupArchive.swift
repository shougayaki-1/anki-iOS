import Foundation
import CryptoKit

struct BackupManifest: Codable, Sendable {
    var schemaVersion = 1
    let createdAt: Date
    let appVersion: String
    let files: [String: String]
}

struct ValidatedBackup: Sendable {
    let data: BackupData
    let media: [UUID: Data]
    let manifest: BackupManifest
}

struct BackupArchive {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func mediaPath(_ id: UUID) -> String { "media/\(id.uuidString).jpg" }

    static func create(data: BackupData, media: [UUID: Data], now: Date, appVersion: String) throws -> Data {
        try BackupValidation.validate(data, media: media)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var files = ["data.json": try encoder.encode(data)]
        for (id, bytes) in media { files[mediaPath(id)] = bytes }
        let manifest = BackupManifest(createdAt: now, appVersion: appVersion, files: files.mapValues(hash))
        files["manifest.json"] = try encoder.encode(manifest)
        return try StoredZIP.write(files)
    }
    static func decode(_ bytes: Data) throws -> ValidatedBackup {
        let files = try StoredZIP.read(bytes)
        guard let manifestData = files["manifest.json"], manifestData.count <= 1_000_000,
              let data = files["data.json"] else { throw BackupError.invalidArchive }
        let manifest: BackupManifest, snapshot: BackupData
        do {
            manifest = try JSONDecoder().decode(BackupManifest.self, from: manifestData)
            snapshot = try JSONDecoder().decode(BackupData.self, from: data)
        } catch { throw BackupError.invalidData }
        guard manifest.schemaVersion == 1, snapshot.schemaVersion == 1 else { throw BackupError.unsupportedVersion }
        guard manifest.createdAt.timeIntervalSince1970.isFinite, !manifest.appVersion.isEmpty,
              Set(manifest.files.keys) == Set(files.keys).subtracting(["manifest.json"]) else { throw BackupError.invalidArchive }
        for (path, checksum) in manifest.files {
            guard let bytes = files[path], hash(bytes) == checksum else { throw BackupError.checksum }
        }
        var media: [UUID: Data] = [:]
        for asset in snapshot.media {
            guard let bytes = files[mediaPath(asset.id)], media[asset.id] == nil else { throw BackupError.invalidData }
            media[asset.id] = bytes
        }
        guard files.count == media.count + 2 else { throw BackupError.invalidArchive }
        try BackupValidation.validate(snapshot, media: media)
        return ValidatedBackup(data: snapshot, media: media, manifest: manifest)
    }
}
