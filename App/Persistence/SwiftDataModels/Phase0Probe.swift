import Foundation
import SwiftData

// A separate diagnostic entity. Production Deck/Note/Card/ReviewLog belong to Phase 1.
enum Phase0Schema: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Phase0Probe.self] }

    @Model
    final class Phase0Probe {
        @Attribute(.unique) var id: UUID
        var createdAt: Date
        var snapshotData: Data
        var transitionsData: Data
        var dueDate: Date

        init(id: UUID = UUID(), createdAt: Date, snapshotData: Data,
             transitionsData: Data, dueDate: Date) {
            self.id = id
            self.createdAt = createdAt
            self.snapshotData = snapshotData
            self.transitionsData = transitionsData
            self.dueDate = dueDate
        }
    }
}

typealias Phase0Probe = Phase0Schema.Phase0Probe
