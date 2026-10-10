import Foundation
import SwiftData

enum StudySchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var models: [any PersistentModel.Type] { StudySchemaV2.models + [MediaAsset.self, EditorDraft.self] }

    @Model final class MediaAsset {
        @Attribute(.unique) var id: UUID
        var relativePath: String
        var mediaType: String
        var width: Int
        var height: Int
        var sha256: String
        var createdAt: Date
        init(image: StoredImage, now: Date) {
            id = image.id; relativePath = image.relativePath; mediaType = image.mediaType
            width = image.width; height = image.height; sha256 = image.sha256; createdAt = now
        }
    }
    @Model final class EditorDraft {
        @Attribute(.unique) var key: String
        var payload: Data
        var updatedAt: Date
        init(key: String, payload: Data, now: Date) { self.key = key; self.payload = payload; updatedAt = now }
    }
}

typealias MediaAsset = StudySchemaV3.MediaAsset
typealias EditorDraft = StudySchemaV3.EditorDraft
