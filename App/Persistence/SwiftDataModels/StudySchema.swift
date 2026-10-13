import Foundation
import SwiftData

// Production data lives in Study.store; the Phase 0 schema/store remains intact.
enum StudySchema: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [Deck.self, Note.self, StudyCard.self, StudyReviewLog.self, SessionDraft.self, StudyPreferences.self]
    }

    @Model final class Deck {
        @Attribute(.unique) var id: UUID
        var name: String
        var parentID: UUID?
        var sortOrder: Int
        var createdAt: Date
        var updatedAt: Date
        init(name: String, now: Date) {
            id = UUID(); self.name = name; sortOrder = 0; createdAt = now; updatedAt = now
        }
    }

    @Model final class Note {
        @Attribute(.unique) var id: UUID
        var deckID: UUID
        var type: String
        var contentPayload: Data
        var tagIDs: [UUID]
        var defaultResponseMode: String
        var createdAt: Date
        var updatedAt: Date
        init(input: NoteInput, content: Data, now: Date) {
            id = UUID(); deckID = input.deckID; type = input.kind.rawValue
            contentPayload = content; tagIDs = []; defaultResponseMode = input.responseMode.rawValue
            createdAt = now; updatedAt = now
        }
    }

    @Model final class StudyCard {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var identityKey: String
        var noteID: UUID
        var variantKey: String
        var fsrsPayload: Data
        var dueDate: Date
        var isSuspended: Bool
        var createdAt: Date
        var updatedAt: Date
        init(noteID: UUID, variantKey: String, payload: Data, now: Date) {
            id = UUID(); self.noteID = noteID; self.variantKey = variantKey
            identityKey = "\(noteID.uuidString):\(variantKey)"
            fsrsPayload = payload; dueDate = now; isSuspended = false
            createdAt = now; updatedAt = now
        }
    }

    @Model final class StudyReviewLog {
        @Attribute(.unique) var id: UUID
        var cardID: UUID
        var reviewedAt: Date
        var grade: Int
        var responseMode: String
        var durationMs: Int
        var fsrsBefore: Data
        var fsrsAfter: Data
        var libraryLog: Data
        var algorithmVersion: String
        var wasNew: Bool
        var sequence: Int
        var previousUpdatedAt: Date
        init(card: StudyCard, transition: ReviewTransition, before: Data, after: Data,
             mode: ResponseMode, durationMs: Int, wasNew: Bool, sequence: Int) {
            id = UUID(); cardID = card.id; reviewedAt = transition.reviewedAt
            grade = transition.grade.rawValue; responseMode = mode.rawValue
            self.durationMs = durationMs; fsrsBefore = before; fsrsAfter = after
            libraryLog = transition.logData; algorithmVersion = ReviewScheduler.algorithmVersion
            self.wasNew = wasNew; self.sequence = sequence; previousUpdatedAt = card.updatedAt
        }
    }

    @Model final class SessionDraft {
        @Attribute(.unique) var key: String
        var mode: String
        var cardID: UUID?
        var answerMode: String
        var typedDraft: String
        var answerRevealed: Bool
        var touchedCardIDs: [UUID]
        var reviewStreak: Int
        var undoLogID: UUID?
        var elapsedMs: Int
        var activeSince: Date?
        var updatedAt: Date
        init(mode: StudyMode, now: Date) {
            key = "active"; self.mode = mode.rawValue; answerMode = ResponseMode.mental.rawValue
            typedDraft = ""; answerRevealed = false; touchedCardIDs = []; reviewStreak = 0
            elapsedMs = 0; updatedAt = now
        }
    }

    @Model final class StudyPreferences {
        @Attribute(.unique) var key: String
        var desiredRetention: Double
        var dailyNewLimit: Int
        var dailyGoal: Int?
        var dayStartHour: Int
        init() {
            key = "settings"; desiredRetention = 0.9; dailyNewLimit = 10
            dailyGoal = 20; dayStartHour = 4
        }
    }
}

typealias Deck = StudySchemaV6.Deck
typealias Note = StudySchema.Note
typealias StudyCard = StudySchema.StudyCard
typealias StudyReviewLog = StudySchema.StudyReviewLog
typealias SessionDraft = StudySchema.SessionDraft
typealias StudyPreferences = StudySchema.StudyPreferences
