import Foundation
import SwiftData

// Optional answer history is separate from FSRS payloads and preferences.
enum StudySchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }
    static var models: [any PersistentModel.Type] { StudySchemaV4.models + [SavedTypedAnswer.self] }
    @Model final class SavedTypedAnswer {
        @Attribute(.unique) var id: UUID // The associated ReviewLog UUID.
        var reviewedAt: Date
        var payload: Data
        init(_ value: TypedAnswerRecord) throws {
            id = value.id; reviewedAt = value.reviewedAt; payload = try JSONEncoder().encode(value)
        }
    }
}
typealias SavedTypedAnswer = StudySchemaV5.SavedTypedAnswer
