import Foundation
import SwiftData

// Restore inserts into a new, unreferenced store. The current store remains untouched.
extension BackupDeck {
    @MainActor func insert(into context: ModelContext) throws {
        let model = Deck(name: name, now: createdAt)
        model.id = id
        model.name = name
        model.parentID = parentID
        model.sortOrder = sortOrder
        model.createdAt = createdAt
        model.updatedAt = updatedAt
        context.insert(model)
    }
}

extension BackupNote {
    @MainActor func insert(into context: ModelContext) throws {
        let model = Note(input: NoteInput(deckID: deckID, kind: NoteKind(rawValue: type) ?? .basic, responseMode: ResponseMode(rawValue: defaultResponseMode) ?? .mental), content: contentPayload, now: createdAt)
        model.id = id
        model.deckID = deckID
        model.type = type
        model.contentPayload = contentPayload
        model.tagIDs = tagIDs
        model.defaultResponseMode = defaultResponseMode
        model.createdAt = createdAt
        model.updatedAt = updatedAt
        context.insert(model)
    }
}

extension BackupStudyCard {
    @MainActor func insert(into context: ModelContext) throws {
        let model = StudyCard(noteID: noteID, variantKey: variantKey, payload: fsrsPayload, now: createdAt)
        model.id = id
        model.identityKey = identityKey
        model.noteID = noteID
        model.variantKey = variantKey
        model.fsrsPayload = fsrsPayload
        model.dueDate = dueDate
        model.isSuspended = isSuspended
        model.createdAt = createdAt
        model.updatedAt = updatedAt
        context.insert(model)
    }
}

extension BackupStudyReviewLog {
    @MainActor func insert(into context: ModelContext) throws {
        let card = StudyCard(noteID: UUID(), variantKey: "basic:front", payload: fsrsBefore, now: previousUpdatedAt)
        card.id = cardID
        let transition = ReviewTransition(before: try JSONDecoder().decode(SchedulerSnapshot.self, from: fsrsBefore),
                                          after: try JSONDecoder().decode(SchedulerSnapshot.self, from: fsrsAfter),
                                          reviewedAt: reviewedAt, grade: ReviewGrade(rawValue: grade) ?? .again, logData: libraryLog)
        let model = StudyReviewLog(card: card, transition: transition, before: fsrsBefore, after: fsrsAfter,
                                   mode: ResponseMode(rawValue: responseMode) ?? .mental, durationMs: durationMs, wasNew: wasNew, sequence: sequence)
        model.id = id
        model.cardID = cardID
        model.reviewedAt = reviewedAt
        model.grade = grade
        model.responseMode = responseMode
        model.durationMs = durationMs
        model.fsrsBefore = fsrsBefore
        model.fsrsAfter = fsrsAfter
        model.libraryLog = libraryLog
        model.algorithmVersion = algorithmVersion
        model.wasNew = wasNew
        model.sequence = sequence
        model.previousUpdatedAt = previousUpdatedAt
        context.insert(model)
    }
}

extension BackupOrderingDraft {
    @MainActor func insert(into context: ModelContext) {
        let record = OrderingDraftRecord(payload: payload); record.key = key; context.insert(record)
    }
}

extension BackupSessionDraft {
    @MainActor func insert(into context: ModelContext) throws {
        let model = SessionDraft(mode: StudyMode(rawValue: mode) ?? .review, now: updatedAt)
        model.key = key
        model.mode = mode
        model.cardID = cardID
        model.answerMode = answerMode
        model.typedDraft = typedDraft
        model.answerRevealed = answerRevealed
        model.touchedCardIDs = touchedCardIDs
        model.reviewStreak = reviewStreak
        model.undoLogID = undoLogID
        model.elapsedMs = elapsedMs
        model.activeSince = activeSince
        model.updatedAt = updatedAt
        context.insert(model)
    }
}

extension BackupStudyPreferences {
    @MainActor func insert(into context: ModelContext) throws {
        let model = StudyPreferences()
        model.key = key
        model.desiredRetention = desiredRetention
        model.dailyNewLimit = dailyNewLimit
        model.dailyGoal = dailyGoal
        model.dayStartHour = dayStartHour
        context.insert(model)
    }
}

extension BackupTag {
    @MainActor func insert(into context: ModelContext) throws {
        let model = Tag(name: name, normalizedName: normalizedName)
        model.id = id
        model.name = name
        model.normalizedName = normalizedName
        context.insert(model)
    }
}

extension BackupImportBatch {
    @MainActor func insert(into context: ModelContext) throws {
        let model = ImportBatch(source: sourceType, now: createdAt, success: successCount, skipped: skippedCount, errors: [])
        model.id = id
        model.sourceType = sourceType
        model.createdAt = createdAt
        model.status = status
        model.successCount = successCount
        model.skippedCount = skippedCount
        model.errorCount = errorCount
        model.errorSummary = errorSummary
        context.insert(model)
    }
}

extension BackupSessionScope {
    @MainActor func insert(into context: ModelContext) throws {
        let model = try SessionScope(scope: JSONDecoder().decode(LearningScope.self, from: payload))
        model.key = key
        model.payload = payload
        context.insert(model)
    }
}

extension BackupExtraPreferences {
    @MainActor func insert(into context: ModelContext) throws {
        let model = try ExtraPreferences(options: JSONDecoder().decode(StudyOptions.self, from: payload))
        model.key = key
        model.payload = payload
        context.insert(model)
    }
}

extension BackupMediaAsset {
    @MainActor func insert(into context: ModelContext) throws {
        let model = MediaAsset(image: StoredImage(id: id, relativePath: relativePath, width: width, height: height, sha256: sha256), now: createdAt)
        model.id = id
        model.relativePath = relativePath
        model.mediaType = mediaType
        model.width = width
        model.height = height
        model.sha256 = sha256
        model.createdAt = createdAt
        context.insert(model)
    }
}

extension BackupEditorDraft {
    @MainActor func insert(into context: ModelContext) throws {
        let model = EditorDraft(key: key, payload: payload, now: updatedAt)
        model.key = key
        model.payload = payload
        model.updatedAt = updatedAt
        context.insert(model)
    }
}

