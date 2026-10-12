import Foundation
import SwiftData

struct SharedDeck: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let parentID: UUID?
}
struct SharedNote: Codable, Equatable, Sendable {
    let id: UUID
    let deckID: UUID
    let kind: NoteKind
    var content: TextContent
    let responseMode: ResponseMode
    let tags: [String]
}
struct SharedMedia: Codable, Equatable, Sendable {
    let id: UUID
    let mediaType: String
    let width: Int
    let height: Int
    let sha256: String
}
struct DeckPackage: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let rootID: UUID
    let decks: [SharedDeck]
    let notes: [SharedNote]
    let media: [SharedMedia]
}
struct ValidatedDeckPackage: Sendable {
    let package: DeckPackage
    let bytes: [UUID: Data]
    fileprivate init(package: DeckPackage, bytes: [UUID: Data]) { self.package = package; self.bytes = bytes }
    var cardCount: Int { package.notes.reduce(0) { $0 + ((try? CardGeneration.variants(kind: $1.kind, content: $1.content).count) ?? 0) } }
}
struct DeckImportPreview {
    let duplicates: Set<UUID>
    let destinationName: String
}

struct DeckImportReceipt {
    let rootDeckID: UUID?
    let destinationName: String?
    let createdNotes: Int
    let createdCards: Int
    let duplicateNotes: Int
    var skipped: [AnkiSkippedNote] = []
    var warnings: [AnkiSkippedNote] = []
    var outcome: ImportResult.Outcome {
        guard createdNotes > 0 else { return .empty }
        return duplicateNotes > 0 || !skipped.isEmpty || !warnings.isEmpty ? .partial : .complete
    }
    var title: String {
        switch outcome {
        case .complete: return "取り込みが完了しました"
        case .partial: return "一部のノートを取り込みました"
        case .empty: return "ノートは追加されませんでした"
        }
    }
    var summary: String {
        "追加 \(createdNotes)ノート / 新規カード \(createdCards)枚\n重複スキップ \(duplicateNotes)ノート / 未対応 \(skipped.count)ノート / 変更の警告 \(warnings.count)件"
    }
}

// Content-only exchange: no scheduling state, timestamps, settings or editor drafts are serialized.
enum DeckExchange {
    static func validate(_ package: DeckPackage, bytes: [UUID: Data]) throws {
        guard package.schemaVersion == 1 else { throw BackupError.unsupportedVersion }
        guard package.decks.count <= 10_000, package.notes.count <= 100_000,
              package.media.count <= StoredZIP.maximumFiles - 2 else { throw BackupError.tooLarge }
        try BackupValidation.unique(package.decks.map(\.id))
        try BackupValidation.unique(package.notes.map(\.id))
        try BackupValidation.unique(package.media.map(\.id))
        guard let root = package.decks.first(where: { $0.id == package.rootID }), root.parentID == nil,
              package.decks.filter({ $0.parentID == nil }).count == 1 else { throw BackupError.invalidData }
        let known = Dictionary(uniqueKeysWithValues: package.decks.map { ($0.id, $0) })
        for deck in package.decks {
            guard !deck.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, deck.name.count <= 1000 else { throw BackupError.invalidData }
            var seen = Set<UUID>(), cursor: UUID? = deck.id
            while let id = cursor {
                guard seen.insert(id).inserted, let node = known[id] else { throw BackupError.invalidData }
                cursor = node.parentID
            }
            guard seen.contains(root.id) else { throw BackupError.invalidData }
        }
        let referenced = Set(package.notes.flatMap { [$0.content.imageID].compactMap { $0 } + $0.content.audioIDs })
        guard referenced == Set(package.media.map(\.id)), referenced == Set(bytes.keys) else { throw BackupError.invalidData }
        let now = Date(timeIntervalSince1970: 1_700_000_000), scheduler = try ReviewScheduler()
        let fresh = try JSONEncoder().encode(scheduler.newCard(now: now))
        var snapshot = BackupData()
        snapshot.decks = package.decks.map { BackupDeck(id: $0.id, name: $0.name, parentID: $0.parentID, sortOrder: 0, createdAt: now, updatedAt: now) }
        snapshot.preferences = [BackupStudyPreferences(key: "settings", desiredRetention: 0.9, dailyNewLimit: 20, dailyGoal: nil, dayStartHour: 4)]
        for note in package.notes {
            try Task.checkCancellation()
            guard note.tags.count <= 1000, note.tags.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 1000 }),
                  note.content.speechOverrides == nil else { throw BackupError.invalidData }
            snapshot.notes.append(BackupNote(id: note.id, deckID: note.deckID, type: note.kind.rawValue,
                contentPayload: try JSONEncoder().encode(note.content), tagIDs: [], defaultResponseMode: note.responseMode.rawValue, createdAt: now, updatedAt: now))
            if note.responseMode == .ordering, OrderingAnswer.reason(kind: note.kind, answer: note.content.answer) != nil { throw BackupError.invalidData }
            for variant in try CardGeneration.variants(kind: note.kind, content: note.content) {
                snapshot.cards.append(BackupStudyCard(id: UUID(), identityKey: "\(note.id.uuidString):\(variant)", noteID: note.id,
                    variantKey: variant, fsrsPayload: fresh, dueDate: now, isSuspended: false, createdAt: now, updatedAt: now))
                guard snapshot.cards.count <= 300_000 else { throw BackupError.tooLarge }
            }
        }
        snapshot.media = package.media.map { BackupMediaAsset(id: $0.id, relativePath: BackupArchive.mediaPath($0.id, mediaType: $0.mediaType), mediaType: $0.mediaType,
            width: $0.width, height: $0.height, sha256: $0.sha256, createdAt: now) }
        try BackupValidation.validate(snapshot, media: bytes)
    }
    static func validated(package: DeckPackage, bytes: [UUID: Data]) throws -> ValidatedDeckPackage {
        try validate(package, bytes: bytes)
        return ValidatedDeckPackage(package: package, bytes: bytes)
    }
    static func encode(_ package: DeckPackage, bytes: [UUID: Data]) throws -> Data {
        try validate(package, bytes: bytes)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var files = ["deck.json": try encoder.encode(package)]
        for asset in package.media { files[BackupArchive.mediaPath(asset.id, mediaType: asset.mediaType)] = bytes[asset.id] }
        files["manifest.json"] = try encoder.encode(DeckFileManifest(files: files.mapValues(BackupArchive.hash)))
        return try StoredZIP.write(files)
    }
    static func decode(_ data: Data) throws -> ValidatedDeckPackage {
        let files = try StoredZIP.read(data)
        guard let json = files["deck.json"], let manifestBytes = files["manifest.json"], manifestBytes.count <= 1_000_000 else { throw BackupError.invalidArchive }
        let manifest = try JSONDecoder().decode(DeckFileManifest.self, from: manifestBytes)
        guard manifest.format == "studydeck", manifest.schemaVersion == 1 else { throw BackupError.unsupportedVersion }
        guard Set(manifest.files.keys) == Set(files.keys).subtracting(["manifest.json"]) else { throw BackupError.invalidArchive }
        for (name, hash) in manifest.files { guard let value = files[name], BackupArchive.hash(value) == hash else { throw BackupError.checksum } }
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              Set(object.keys) == Set(["schemaVersion", "rootID", "decks", "notes", "media"]) else { throw BackupError.invalidData }
        let package = try JSONDecoder().decode(DeckPackage.self, from: json)
        var bytes: [UUID: Data] = [:]
        for asset in package.media {
            guard let value = files[BackupArchive.mediaPath(asset.id, mediaType: asset.mediaType)], bytes[asset.id] == nil else { throw BackupError.invalidData }
            bytes[asset.id] = value
        }
        guard files.count == bytes.count + 2 else { throw BackupError.invalidArchive }
        try validate(package, bytes: bytes)
        return ValidatedDeckPackage(package: package, bytes: bytes)
    }
    static func read(_ url: URL) async throws -> ValidatedDeckPackage {
        let task = Task.detached(priority: .utility) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= StoredZIP.maximumBytes else { throw BackupError.tooLarge }
            try Task.checkCancellation()
            return try decode(Data(contentsOf: url, options: .mappedIfSafe))
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    static func fingerprint(kind: NoteKind, content: TextContent, hashes: [UUID: String]) throws -> String {
        var canonical = content
        let attachments = [canonical.imageID, canonical.questionAudioID, canonical.answerAudioID].map { $0.flatMap { hashes[$0] } ?? "" }
        canonical.imageID = nil; canonical.questionAudioID = nil; canonical.answerAudioID = nil; canonical.speechOverrides = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return BackupArchive.hash(try encoder.encode(canonical)) + kind.rawValue + attachments.joined(separator: "|")
    }
}
struct DeckFileManifest: Codable {
    var format = "studydeck"
    var schemaVersion = 1
    let files: [String: String]
}

extension StudyRepository {
    func captureDeckPackage(rootID: UUID) throws -> (DeckPackage, [UUID: URL]) {
        let allDecks = try decks()
        guard allDecks.contains(where: { $0.id == rootID }) else { throw StudyError.missingRecord }
        var selected: Set<UUID> = [rootID]
        while true {
            let descendants = Set(allDecks.filter { $0.parentID.map { selected.contains($0) } == true }.map(\.id))
            let next = selected.union(descendants)
            if next == selected { break }; selected = next
        }
        let names = Dictionary(uniqueKeysWithValues: try tags().map { ($0.id, $0.name) })
        let shared = try notes().filter { selected.contains($0.deckID) }.map { note -> SharedNote in
            var content = try JSONDecoder().decode(TextContent.self, from: note.contentPayload); content.speechOverrides = nil
            return SharedNote(id: note.id, deckID: note.deckID, kind: NoteKind(rawValue: note.type) ?? .basic,
                content: content, responseMode: ResponseMode(rawValue: note.defaultResponseMode) ?? .mental,
                tags: note.tagIDs.compactMap { names[$0] }.sorted())
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let ids = Set(shared.flatMap { [$0.content.imageID].compactMap { $0 } + $0.content.audioIDs })
        let assets = try assets().filter { ids.contains($0.id) }
        let media = assets.map { SharedMedia(id: $0.id, mediaType: $0.mediaType, width: $0.width, height: $0.height, sha256: $0.sha256) }.sorted { $0.id.uuidString < $1.id.uuidString }
        let package = DeckPackage(rootID: rootID, decks: allDecks.filter { selected.contains($0.id) }.map { SharedDeck(id: $0.id, name: $0.name, parentID: $0.id == rootID ? nil : $0.parentID) }.sorted { $0.id.uuidString < $1.id.uuidString }, notes: shared, media: media)
        return (package, try Dictionary(uniqueKeysWithValues: assets.map { ($0.id, try assetURL(id: $0.id)) }))
    }
    func previewDeckImport(_ validated: ValidatedDeckPackage) throws -> DeckImportPreview {
        let package = validated.package, hashes = Dictionary(uniqueKeysWithValues: package.media.map { ($0.id, $0.sha256) })
        let existingHashes = Dictionary(uniqueKeysWithValues: try assets().map { ($0.id, $0.sha256) })
        let existing = try Set(notes().map { try DeckExchange.fingerprint(kind: NoteKind(rawValue: $0.type) ?? .basic,
            content: JSONDecoder().decode(TextContent.self, from: $0.contentPayload), hashes: existingHashes) })
        var seen = existing, duplicates = Set<UUID>()
        for note in package.notes {
            let key = try DeckExchange.fingerprint(kind: note.kind, content: note.content, hashes: hashes)
            if !seen.insert(key).inserted { duplicates.insert(note.id) }
        }
        let root = package.decks.first(where: { $0.id == package.rootID })!
        let names = Set(try decks().filter { $0.parentID == nil }.map(\.name))
        var name = root.name, suffix = 2
        while names.contains(name) { name = "\(root.name)（取込 \(suffix)）"; suffix += 1 }
        return DeckImportPreview(duplicates: duplicates, destinationName: name)
    }
    func importDeckPackage(_ validated: ValidatedDeckPackage, skipDuplicates: Bool, now: Date) throws -> Int {
        try importDeckPackageReceipt(validated, skipDuplicates: skipDuplicates, now: now).createdNotes
    }
    func importDeckPackageReceipt(_ validated: ValidatedDeckPackage, skipDuplicates: Bool, now: Date) throws -> DeckImportReceipt {
        // Only decode can construct this immutable, fully validated value. Do not
        // decode audio again on the UI actor when publishing the transaction.
        try Task.checkCancellation()
        let preview = try previewDeckImport(validated)
        let notes = validated.package.notes.filter { !skipDuplicates || !preview.duplicates.contains($0.id) }
        let duplicateCount = skipDuplicates ? preview.duplicates.count : 0
        guard !notes.isEmpty else {
            return DeckImportReceipt(rootDeckID: nil, destinationName: nil, createdNotes: 0, createdCards: 0, duplicateNotes: duplicateCount)
        }
        let required = Set(notes.flatMap { [$0.content.imageID].compactMap { $0 } + $0.content.audioIDs })
        var written: [String] = [], remapped: [UUID: UUID] = [:], assets: [StoredImage] = []
        do {
            for asset in validated.package.media where required.contains(asset.id) {
                try Task.checkCancellation()
                let id = UUID(), path = "restored/\(UUID().uuidString)/\(id.uuidString).\(AudioEncodingPolicy.extensions[asset.mediaType] ?? (asset.mediaType == "image/png" ? "png" : "jpg"))"
                let url = try mediaStore.url(for: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                written.append(path)
                try validated.bytes[asset.id]!.write(to: url, options: .atomic)
                remapped[asset.id] = id
                assets.append(StoredImage(id: id, relativePath: path, mediaType: asset.mediaType, width: asset.width, height: asset.height, sha256: asset.sha256))
            }
            let scheduler = try ReviewScheduler(desiredRetention: settings().desiredRetention)
            let fresh = try JSONEncoder().encode(scheduler.newCard(now: now))
            let deckIDs = Dictionary(uniqueKeysWithValues: validated.package.decks.map { ($0.id, UUID()) })
            return try transaction {
                for asset in assets { context.insert(MediaAsset(image: asset, now: now)) }
                for deck in validated.package.decks {
                    let model = Deck(name: deck.id == validated.package.rootID ? preview.destinationName : deck.name, now: now)
                    model.id = deckIDs[deck.id]!; model.parentID = deck.parentID.flatMap { deckIDs[$0] }; context.insert(model)
                }
                var cardCount = 0
                for source in notes {
                    try Task.checkCancellation()
                    var content = source.content
                    content.imageID = content.imageID.flatMap { remapped[$0] }
                    content.questionAudioID = content.questionAudioID.flatMap { remapped[$0] }
                    content.answerAudioID = content.answerAudioID.flatMap { remapped[$0] }
                    let input = NoteInput(deckID: deckIDs[source.deckID]!, kind: source.kind, responseMode: source.responseMode)
                    let note = Note(input: input, content: try JSONEncoder().encode(content), now: now)
                    note.tagIDs = try tagIDs(for: source.tags); context.insert(note)
                    for variant in try CardGeneration.variants(kind: source.kind, content: content) {
                        context.insert(StudyCard(noteID: note.id, variantKey: variant, payload: fresh, now: now))
                        cardCount += 1
                    }
                }
                return DeckImportReceipt(rootDeckID: deckIDs[validated.package.rootID], destinationName: preview.destinationName,
                                         createdNotes: notes.count, createdCards: cardCount, duplicateNotes: duplicateCount)
            }
        } catch { for path in written { try? mediaStore.remove(path) }; throw error }
    }
}

extension DeckExchange {
    @MainActor static func export(repository: StudyRepository, rootID: UUID) async throws -> Data {
        let (package, urls) = try repository.captureDeckPackage(rootID: rootID)
        let task = Task.detached(priority: .utility) {
            var bytes: [UUID: Data] = [:], total = 0
            for (id, url) in urls {
                try Task.checkCancellation()
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= 20_000_000, total <= StoredZIP.maximumBytes - size else { throw BackupError.tooLarge }
                total += size; bytes[id] = try Data(contentsOf: url, options: .mappedIfSafe)
            }
            return try encode(package, bytes: bytes)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
