import Foundation
import SwiftData

// Add one temporary-answer entity; all existing models and UUIDs stay unchanged.
enum StudySchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }
    static var models: [any PersistentModel.Type] { StudySchemaV3.models + [OrderingDraftRecord.self] }

    @Model final class OrderingDraftRecord {
        @Attribute(.unique) var key: String
        var payload: Data
        init(payload: Data) { key = "active"; self.payload = payload }
    }
}

typealias OrderingDraftRecord = StudySchemaV4.OrderingDraftRecord
