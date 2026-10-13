import Foundation
import SwiftData

// V1's model declarations are frozen. V2 only adds entities; their UUID references
// keep existing Deck/Note/Card/ReviewLog rows and historical IDs intact.
enum StudySchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        StudySchema.models + [Tag.self, ImportBatch.self, SessionScope.self, ExtraPreferences.self]
    }

    @Model final class Tag {
        @Attribute(.unique) var id: UUID
        var name: String
        @Attribute(.unique) var normalizedName: String
        init(name: String, normalizedName: String) {
            id = UUID(); self.name = name; self.normalizedName = normalizedName
        }
    }
    @Model final class ImportBatch {
        @Attribute(.unique) var id: UUID
        var sourceType: String
        var createdAt: Date
        var status: String
        var successCount: Int
        var skippedCount: Int
        var errorCount: Int
        var errorSummary: String
        init(source: String, now: Date, success: Int, skipped: Int, errors: [String]) {
            id = UUID(); sourceType = source; createdAt = now; status = "completed"
            successCount = success; skippedCount = skipped; errorCount = errors.count
            errorSummary = errors.joined(separator: "\n")
        }
    }
    @Model final class SessionScope {
        @Attribute(.unique) var key: String
        var payload: Data
        init(scope: LearningScope) throws { key = "active"; payload = try JSONEncoder().encode(scope) }
    }
    @Model final class ExtraPreferences {
        @Attribute(.unique) var key: String
        var payload: Data
        init(options: StudyOptions = StudyOptions()) throws {
            key = "options"; payload = try JSONEncoder().encode(options)
        }
    }
}

enum StudyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [StudySchema.self, StudySchemaV2.self, StudySchemaV3.self, StudySchemaV4.self, StudySchemaV5.self, StudySchemaV6.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: StudySchema.self, toVersion: StudySchemaV2.self),
         .lightweight(fromVersion: StudySchemaV2.self, toVersion: StudySchemaV3.self),
         .lightweight(fromVersion: StudySchemaV3.self, toVersion: StudySchemaV4.self),
         .lightweight(fromVersion: StudySchemaV4.self, toVersion: StudySchemaV5.self),
         .lightweight(fromVersion: StudySchemaV5.self, toVersion: StudySchemaV6.self)]
    }
}

typealias Tag = StudySchemaV2.Tag
typealias ImportBatch = StudySchemaV2.ImportBatch
typealias SessionScope = StudySchemaV2.SessionScope
typealias ExtraPreferences = StudySchemaV2.ExtraPreferences
