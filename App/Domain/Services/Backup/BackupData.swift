import Foundation
import SwiftData

// Value snapshots keep SwiftData objects on the main actor while ZIP and hash work can run elsewhere.
struct BackupData: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var decks: [BackupDeck] = []
    var notes: [BackupNote] = []
    var cards: [BackupStudyCard] = []
    var logs: [BackupStudyReviewLog] = []
    var sessions: [BackupSessionDraft] = []
    var orderingDrafts: [BackupOrderingDraft]? = nil
    var preferences: [BackupStudyPreferences] = []
    var tags: [BackupTag] = []
    var imports: [BackupImportBatch] = []
    var scopes: [BackupSessionScope] = []
    var options: [BackupExtraPreferences] = []
    var media: [BackupMediaAsset] = []
    var editorDrafts: [BackupEditorDraft] = []
}

struct BackupDeck: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var parentID: UUID?
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
}
extension BackupDeck {
    @MainActor init(_ model: Deck) {
        id = model.id
        name = model.name
        parentID = model.parentID
        sortOrder = model.sortOrder
        createdAt = model.createdAt
        updatedAt = model.updatedAt
    }
}

struct BackupNote: Codable, Equatable, Sendable {
    var id: UUID
    var deckID: UUID
    var type: String
    var contentPayload: Data
    var tagIDs: [UUID]
    var defaultResponseMode: String
    var createdAt: Date
    var updatedAt: Date
}
extension BackupNote {
    @MainActor init(_ model: Note) {
        id = model.id
        deckID = model.deckID
        type = model.type
        contentPayload = model.contentPayload
        tagIDs = model.tagIDs
        defaultResponseMode = model.defaultResponseMode
        createdAt = model.createdAt
        updatedAt = model.updatedAt
    }
}

struct BackupStudyCard: Codable, Equatable, Sendable {
    var id: UUID
    var identityKey: String
    var noteID: UUID
    var variantKey: String
    var fsrsPayload: Data
    var dueDate: Date
    var isSuspended: Bool
    var createdAt: Date
    var updatedAt: Date
}
extension BackupStudyCard {
    @MainActor init(_ model: StudyCard) {
        id = model.id
        identityKey = model.identityKey
        noteID = model.noteID
        variantKey = model.variantKey
        fsrsPayload = model.fsrsPayload
        dueDate = model.dueDate
        isSuspended = model.isSuspended
        createdAt = model.createdAt
        updatedAt = model.updatedAt
    }
}

struct BackupStudyReviewLog: Codable, Equatable, Sendable {
    var id: UUID
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
}
extension BackupStudyReviewLog {
    @MainActor init(_ model: StudyReviewLog) {
        id = model.id
        cardID = model.cardID
        reviewedAt = model.reviewedAt
        grade = model.grade
        responseMode = model.responseMode
        durationMs = model.durationMs
        fsrsBefore = model.fsrsBefore
        fsrsAfter = model.fsrsAfter
        libraryLog = model.libraryLog
        algorithmVersion = model.algorithmVersion
        wasNew = model.wasNew
        sequence = model.sequence
        previousUpdatedAt = model.previousUpdatedAt
    }
}

struct BackupSessionDraft: Codable, Equatable, Sendable {
    var key: String
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
}
extension BackupSessionDraft {
    @MainActor init(_ model: SessionDraft) {
        key = model.key
        mode = model.mode
        cardID = model.cardID
        answerMode = model.answerMode
        typedDraft = model.typedDraft
        answerRevealed = model.answerRevealed
        touchedCardIDs = model.touchedCardIDs
        reviewStreak = model.reviewStreak
        undoLogID = model.undoLogID
        elapsedMs = model.elapsedMs
        activeSince = model.activeSince
        updatedAt = model.updatedAt
    }
}

struct BackupStudyPreferences: Codable, Equatable, Sendable {
    var key: String
    var desiredRetention: Double
    var dailyNewLimit: Int
    var dailyGoal: Int?
    var dayStartHour: Int
}
extension BackupStudyPreferences {
    @MainActor init(_ model: StudyPreferences) {
        key = model.key
        desiredRetention = model.desiredRetention
        dailyNewLimit = model.dailyNewLimit
        dailyGoal = model.dailyGoal
        dayStartHour = model.dayStartHour
    }
}

struct BackupTag: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var normalizedName: String
}
extension BackupTag {
    @MainActor init(_ model: Tag) {
        id = model.id
        name = model.name
        normalizedName = model.normalizedName
    }
}

struct BackupImportBatch: Codable, Equatable, Sendable {
    var id: UUID
    var sourceType: String
    var createdAt: Date
    var status: String
    var successCount: Int
    var skippedCount: Int
    var errorCount: Int
    var errorSummary: String
}
extension BackupImportBatch {
    @MainActor init(_ model: ImportBatch) {
        id = model.id
        sourceType = model.sourceType
        createdAt = model.createdAt
        status = model.status
        successCount = model.successCount
        skippedCount = model.skippedCount
        errorCount = model.errorCount
        errorSummary = model.errorSummary
    }
}

struct BackupSessionScope: Codable, Equatable, Sendable {
    var key: String
    var payload: Data
}
extension BackupSessionScope {
    @MainActor init(_ model: SessionScope) {
        key = model.key
        payload = model.payload
    }
}

struct BackupExtraPreferences: Codable, Equatable, Sendable {
    var key: String
    var payload: Data
}
extension BackupExtraPreferences {
    @MainActor init(_ model: ExtraPreferences) {
        key = model.key
        payload = model.payload
    }
}

struct BackupMediaAsset: Codable, Equatable, Sendable {
    var id: UUID
    var relativePath: String
    var mediaType: String
    var width: Int
    var height: Int
    var sha256: String
    var createdAt: Date
}
extension BackupMediaAsset {
    @MainActor init(_ model: MediaAsset) {
        id = model.id
        relativePath = model.relativePath
        mediaType = model.mediaType
        width = model.width
        height = model.height
        sha256 = model.sha256
        createdAt = model.createdAt
    }
}

struct BackupEditorDraft: Codable, Equatable, Sendable {
    var key: String
    var payload: Data
    var updatedAt: Date
}
extension BackupEditorDraft {
    @MainActor init(_ model: EditorDraft) {
        key = model.key
        payload = model.payload
        updatedAt = model.updatedAt
    }
}

struct BackupOrderingDraft: Codable, Equatable, Sendable {
    var key: String
    var payload: Data
}

extension BackupData {
    @MainActor static func capture(_ repository: StudyRepository) throws -> Self {
        var result = Self()
        result.decks = try repository.decks().map(BackupDeck.init)
        result.notes = try repository.notes().map(BackupNote.init)
        result.cards = try repository.cards().map(BackupStudyCard.init)
        result.logs = try repository.logs().map(BackupStudyReviewLog.init)
        result.sessions = try repository.context.fetch(FetchDescriptor<SessionDraft>()).map(BackupSessionDraft.init)
        let ordering = try repository.context.fetch(FetchDescriptor<OrderingDraftRecord>())
        result.orderingDrafts = ordering.isEmpty ? nil : ordering.map { BackupOrderingDraft(key: $0.key, payload: $0.payload) }
        result.preferences = try repository.context.fetch(FetchDescriptor<StudyPreferences>()).map(BackupStudyPreferences.init)
        result.tags = try repository.tags().map(BackupTag.init)
        result.imports = try repository.context.fetch(FetchDescriptor<ImportBatch>()).map(BackupImportBatch.init)
        result.scopes = try repository.context.fetch(FetchDescriptor<SessionScope>()).map(BackupSessionScope.init)
        result.options = try repository.context.fetch(FetchDescriptor<ExtraPreferences>()).map(BackupExtraPreferences.init)
        result.media = try repository.assets().map(BackupMediaAsset.init)
        result.editorDrafts = try repository.context.fetch(FetchDescriptor<EditorDraft>()).map(BackupEditorDraft.init)
        return result
    }
}
