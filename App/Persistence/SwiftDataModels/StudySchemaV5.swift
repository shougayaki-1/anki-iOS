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

// Keep all historical Deck definitions unchanged for staged migration.
enum StudySchemaV6: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(6, 0, 0) }
    static var models: [any PersistentModel.Type] {
        StudySchemaV5.models.filter { $0 != StudySchema.Deck.self } + [Deck.self]
    }
    @Model final class Deck {
        @Attribute(.unique) var id: UUID
        var name: String
        var parentID: UUID?
        var sortOrder: Int
        var createdAt: Date
        var updatedAt: Date
        // Optional storage allows existing rows to migrate without rewriting data.
        var studyPaused: Bool? = nil
        var isStudyPaused: Bool {
            get { studyPaused ?? false }
            set { studyPaused = newValue }
        }
        init(name: String, now: Date) {
            id = UUID(); self.name = name; sortOrder = 0; createdAt = now; updatedAt = now
        }
    }
}

// One lookup per deck tree, never an ancestor fetch per card. Cycles terminate;
// all members of a malformed cycle inherit any pause within that cycle.
enum DeckStudyEligibility {
    static func pausedIDs(_ links: [(id: UUID, parentID: UUID?, paused: Bool)]) -> Set<UUID> {
        let parents = Dictionary(uniqueKeysWithValues: links.map { ($0.id, $0.parentID) })
        let direct = Set(links.filter { $0.paused }.map { $0.id })
        var resolved: [UUID: Bool] = [:]
        for link in links {
            var path: [UUID] = [], seen = Set<UUID>(), cursor: UUID? = link.id
            var paused = false
            while let id = cursor, seen.insert(id).inserted {
                if direct.contains(id) { paused = true; break }
                if let cached = resolved[id] { paused = cached; break }
                path.append(id); cursor = parents[id] ?? nil
            }
            for id in path { resolved[id] = paused }
            resolved[link.id] = paused
        }
        return direct.union(resolved.filter { $0.value }.map { $0.key })
    }
}
