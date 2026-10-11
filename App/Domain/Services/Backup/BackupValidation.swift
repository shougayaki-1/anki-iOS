import Foundation
import ImageIO

struct BackupValidation {
    static func unique<T: Hashable>(_ values: [T]) throws {
        guard Set(values).count == values.count else { throw BackupError.invalidData }
    }
    static func dates(_ dates: Date...) throws {
        guard dates.allSatisfy({ $0.timeIntervalSince1970.isFinite && $0 >= .distantPast && $0 <= .distantFuture }) else { throw BackupError.invalidData }
    }
    static func snapshot(_ data: Data, scheduler: ReviewScheduler) throws -> ScheduleSummary {
        guard data.count <= 64_000 else { throw BackupError.invalidData }
        let value = try JSONDecoder().decode(SchedulerSnapshot.self, from: data)
        let summary = try scheduler.summary(value)
        guard let raw = try JSONSerialization.jsonObject(with: value.cardData) as? [String: Any] else { throw BackupError.invalidData }
        for field in ["elapsedDays", "lastElapsedDays", "scheduledDays"] {
            if let number = raw[field] as? NSNumber {
                guard number.doubleValue.isFinite, abs(number.doubleValue) <= 1_000_000_000 else { throw BackupError.invalidData }
            }
        }
        guard summary.stability.isFinite, (0...1e12).contains(summary.stability), summary.difficulty.isFinite,
              (0...10).contains(summary.difficulty), (0...1_000_000_000).contains(summary.repetitions), (0...1_000_000_000).contains(summary.lapses),
              (0...10_000).contains(summary.learningStep) else { throw BackupError.invalidData }
        try dates(summary.dueDate)
        if let date = summary.lastReview { try dates(date) }
        return summary
    }
    static func validate(_ data: BackupData, media: [UUID: Data]) throws {
        guard data.schemaVersion == 1 else { throw BackupError.unsupportedVersion }
        guard !data.decks.isEmpty, data.decks.count <= 10_000, data.notes.count <= 100_000,
              data.cards.count <= 300_000, data.logs.count <= 1_000_000,
              data.preferences.count == 1, data.options.count <= 1, data.scopes.count <= 1,
              data.sessions.count <= 1, data.editorDrafts.count <= 100_000 else { throw BackupError.invalidData }
        try unique(data.decks.map(\.id)); try unique(data.notes.map(\.id)); try unique(data.cards.map(\.id))
        try unique(data.cards.map(\.identityKey)); try unique(data.logs.map(\.id)); try unique(data.logs.map(\.sequence))
        try unique(data.tags.map(\.id)); try unique(data.tags.map(\.normalizedName)); try unique(data.media.map(\.id))
        try unique(data.media.map(\.relativePath)); try unique(data.imports.map(\.id)); try unique(data.editorDrafts.map(\.key))
        let mediaTypes = Dictionary(uniqueKeysWithValues: data.media.map { ($0.id, $0.mediaType) })
        let decks = Dictionary(uniqueKeysWithValues: data.decks.map { ($0.id, $0) })
        let noteIDs = Set(data.notes.map(\.id)), cardIDs = Set(data.cards.map(\.id))
        let tagIDs = Set(data.tags.map(\.id)), mediaIDs = Set(data.media.map(\.id)), logIDs = Set(data.logs.map(\.id))
        guard mediaIDs == Set(media.keys) else { throw BackupError.invalidData }
        var visited = Set<UUID>()
        for deck in data.decks {
            try dates(deck.createdAt, deck.updatedAt)
            guard !deck.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BackupError.invalidData }
            var path = Set<UUID>(), cursor: UUID? = deck.id
            while let id = cursor, !visited.contains(id) {
                guard !path.contains(id), let current = decks[id] else { throw BackupError.invalidData }
                path.insert(id); cursor = current.parentID
            }
            visited.formUnion(path)
        }
        for tag in data.tags {
            let normalized = ImportParser.normalized(tag.name).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard !normalized.isEmpty, tag.normalizedName == normalized else { throw BackupError.invalidData }
        }
        let settings = data.preferences[0]
        guard settings.key == "settings", (0.8...0.97).contains(settings.desiredRetention),
              (0...100_000).contains(settings.dailyNewLimit), (0...23).contains(settings.dayStartHour),
              settings.dailyGoal == nil || (1...100_000).contains(settings.dailyGoal!) else { throw BackupError.invalidData }
        let scheduler = try ReviewScheduler(desiredRetention: settings.desiredRetention)
        var expectedVariants: [UUID: Set<String>] = [:]
        for note in data.notes {
            try dates(note.createdAt, note.updatedAt)
            guard decks[note.deckID] != nil, let kind = NoteKind(rawValue: note.type),
                  ResponseMode(rawValue: note.defaultResponseMode) != nil, Set(note.tagIDs).isSubset(of: tagIDs),
                  note.contentPayload.count <= StoredZIP.maximumEntryBytes else { throw BackupError.invalidData }
            let content = try JSONDecoder().decode(TextContent.self, from: note.contentPayload)
            guard (1...2).contains(content.schemaVersion), !ImportParser.normalized(content.question).isEmpty,
                  [.cloze, .imageOcclusion].contains(kind) || !ImportParser.normalized(content.answer).isEmpty else { throw BackupError.invalidData }
            if let id = content.imageID, mediaTypes[id]?.hasPrefix("image/") != true { throw BackupError.invalidData }
            for id in content.audioIDs { guard mediaTypes[id].flatMap { AudioEncodingPolicy.extensions[$0] } != nil else { throw BackupError.invalidData } }
            expectedVariants[note.id] = Set(try CardGeneration.variants(kind: kind, content: content))
        }
        var variants: [UUID: Set<String>] = [:]
        for card in data.cards {
            try dates(card.createdAt, card.updatedAt, card.dueDate)
            guard noteIDs.contains(card.noteID), card.identityKey == "\(card.noteID.uuidString):\(card.variantKey)" else { throw BackupError.invalidData }
            let summary = try snapshot(card.fsrsPayload, scheduler: scheduler)
            guard abs(summary.dueDate.timeIntervalSince(card.dueDate)) < 0.0001 else { throw BackupError.invalidData }
            variants[card.noteID, default: []].insert(card.variantKey)
        }
        guard variants == expectedVariants else { throw BackupError.invalidData }
        for log in data.logs {
            try dates(log.reviewedAt, log.previousUpdatedAt)
            guard ReviewGrade(rawValue: log.grade) != nil, ResponseMode(rawValue: log.responseMode) != nil,
                  log.algorithmVersion == ReviewScheduler.algorithmVersion, (0...2_678_400_000).contains(log.durationMs),
                  log.sequence > 0, log.libraryLog.count <= 64_000 else { throw BackupError.invalidData }
            _ = try snapshot(log.fsrsBefore, scheduler: scheduler); _ = try snapshot(log.fsrsAfter, scheduler: scheduler)
            _ = try JSONSerialization.jsonObject(with: log.libraryLog)
            // Histories intentionally survive deleting a card, so cardID may be historical.
        }
        for session in data.sessions {
            try dates(session.updatedAt)
            guard session.key == "active", StudyMode(rawValue: session.mode) != nil,
                  ResponseMode(rawValue: session.answerMode) != nil, (0...2_678_400_000).contains(session.elapsedMs), session.reviewStreak >= 0,
                  session.cardID == nil || cardIDs.contains(session.cardID!),
                  session.undoLogID == nil || logIDs.contains(session.undoLogID!) else { throw BackupError.invalidData }
            if let date = session.activeSince { try dates(date) }
        }
        let orderingRecords = data.orderingDrafts ?? []
        guard orderingRecords.count <= 1 else { throw BackupError.invalidData }
        for record in orderingRecords {
            guard record.key == "active", record.payload.count <= 32_000,
                  let state = try? JSONDecoder().decode(OrderingDraft.self, from: record.payload),
                  data.sessions.first?.cardID == state.cardID,
                  let card = data.cards.first(where: { $0.id == state.cardID }),
                  let note = data.notes.first(where: { $0.id == card.noteID }),
                  let kind = NoteKind(rawValue: note.type) else { throw BackupError.invalidData }
            let content = try JSONDecoder().decode(TextContent.self, from: note.contentPayload)
            let shown = try CardGeneration.displayed(kind: kind, content: content, variant: card.variantKey)
            let problem = try OrderingAnswer(kind: kind, answer: shown.answer)
            guard state.isValid(for: problem, cardID: state.cardID) else { throw BackupError.invalidData }
        }
        for row in data.scopes {
            let scope = try JSONDecoder().decode(LearningScope.self, from: row.payload)
            guard row.key == "active", scope.schemaVersion == 1, scope.deckID == nil || decks[scope.deckID!] != nil,
                  Set(scope.tagIDs).isSubset(of: tagIDs) else { throw BackupError.invalidData }
        }
        for row in data.options {
            let options = try JSONDecoder().decode(StudyOptions.self, from: row.payload)
            guard row.key == "options", (1...2).contains(options.schemaVersion) else { throw BackupError.invalidData }
            if let limit = options.sessionAnswerLimit, !(0...500).contains(limit) {
                throw BackupError.invalidData
            }
            if let progress = options.activeSessionProgress {
                guard progress.startSequence >= 0, (0...500).contains(progress.answerLimit),
                      progress.startSequence <= (data.logs.map(\.sequence).max() ?? 0)
                else { throw BackupError.invalidData }
            }
            if let home = options.homeScope {
                // Stale home references are repaired on load; active session scope remains strict.
                guard home.schemaVersion == 1 else { throw BackupError.invalidData }
            }
            if let notification = options.notification {
                guard (0...23).contains(notification.hour), (0...59).contains(notification.minute) else { throw BackupError.invalidData }
            }
        }
        for batch in data.imports {
            try dates(batch.createdAt)
            guard batch.successCount >= 0, batch.skippedCount >= 0, batch.errorCount >= 0 else { throw BackupError.invalidData }
        }
        for draft in data.editorDrafts {
            try dates(draft.updatedAt)
            let input = try JSONDecoder().decode(NoteInput.self, from: draft.payload)
            if let image = input.imageID, mediaTypes[image]?.hasPrefix("image/") != true { throw BackupError.invalidData }
            for id in input.audioIDs { guard mediaTypes[id].flatMap { AudioEncodingPolicy.extensions[$0] } != nil else { throw BackupError.invalidData } }
            guard draft.key == "new" || (draft.key.hasPrefix("edit:") && UUID(uuidString: String(draft.key.dropFirst(5))) != nil) else { throw BackupError.invalidData }
        }
        for asset in data.media {
            try dates(asset.createdAt)
            if AudioEncodingPolicy.extensions[asset.mediaType] != nil {
                guard StoredZIP.validPath(asset.relativePath), asset.width == 0, asset.height == 0,
                      let bytes = media[asset.id], BackupArchive.hash(bytes) == asset.sha256 else { throw BackupError.invalidData }
                do { guard try AudioEncodingPolicy.prepare(bytes).mediaType == asset.mediaType else { throw BackupError.invalidData } }
                catch { throw BackupError.invalidData }
                continue
            }
            if let bytes = media[asset.id], asset.mediaType == "image/png" {
                do { try ImageEncodingPolicy.validateContainer(bytes, type: "public.png") }
                catch { throw BackupError.invalidData }
            }
            guard StoredZIP.validPath(asset.relativePath),
                  let imageType = ["image/jpeg": "public.jpeg", "image/png": "public.png"][asset.mediaType],
                  let bytes = media[asset.id], bytes.count <= ImageEncodingPolicy.maximumBytes,
                  asset.width > 0, asset.height > 0,
                  asset.width <= ImageEncodingPolicy.maximumPixels / asset.height,
                  BackupArchive.hash(bytes) == asset.sha256,
                  let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  CGImageSourceGetCount(source) == 1,
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
                  CGImageSourceGetType(source) as String? == imageType,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
                  let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  info[kCGImagePropertyPixelWidth] as? Int == asset.width,
                  info[kCGImagePropertyPixelHeight] as? Int == asset.height else { throw BackupError.invalidData }
        }
    }
}
