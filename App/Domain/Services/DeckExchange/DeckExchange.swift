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
enum DeckImportPlanError: LocalizedError {
    case changed, consent
    var errorDescription: String? {
        switch self {
        case .changed: return "取込先または更新対象の状態が変わりました。更新されたプレビューを確認して、もう一度確定してください。"
        case .consent: return "更新対象と履歴方針への同意が必要です。差分を確認してください。"
        }
    }
}

enum DeckImportDestination: Equatable {
    case newRoot, childOf(UUID), mergeInto(UUID)
}

struct DeckImportMapping: Equatable, Identifiable {
    let id: UUID
    let targetID: UUID
    let parentID: UUID?
    let name: String
    let sourcePath: String
    let destinationPath: String
    let reused: Bool
}

enum DeckNoteUpdateConsent: String, Equatable {
    case preserveHistory, resetSchedule
}

struct DeckNoteUpdate: Equatable, Identifiable {
    let id: UUID // Source and target UUID must match; content similarity is never identity.
    let before: BackupNote
    let cards: [BackupStudyCard]
    let beforeContent: TextContent
    let beforeTags: [String]
    let incoming: SharedNote
    let mediaHashesBefore: [String?]
    let mediaHashesAfter: [String?]
    let changes: [DeckNoteDifference]
    let requiresReset: Bool
    let revision: Int
}

struct DeckNoteDifference: Equatable, Identifiable {
    let id: String
    let before: String
    let after: String
}

struct DeckImportPreview: Equatable {
    var duplicates: Set<UUID>
    let destinationName: String
    let mappings: [DeckImportMapping]
    var updates: [DeckNoteUpdate] = []
    var updateBlocked: [UUID: String] = [:]
}

struct DeckImportReceipt {
    let rootDeckID: UUID?
    let destinationName: String?
    let createdNotes: Int
    let createdCards: Int
    let duplicateNotes: Int
    var updatedNotes = 0
    var resetNotes = 0
    var skipped: [AnkiSkippedNote] = []
    var warnings: [AnkiSkippedNote] = []
    var outcome: ImportResult.Outcome {
        guard createdNotes + updatedNotes > 0 else { return .empty }
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
        "追加 \(createdNotes)ノート / 新規カード \(createdCards)枚\n更新 \(updatedNotes)ノート（未学習リセット \(resetNotes)）\n重複スキップ \(duplicateNotes)ノート / 未対応 \(skipped.count)ノート / 変更の警告 \(warnings.count)件"
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
    func previewDeckImport(_ validated: ValidatedDeckPackage, destination: DeckImportDestination = .newRoot) throws -> DeckImportPreview {
        let package = validated.package, hashes = Dictionary(uniqueKeysWithValues: package.media.map { ($0.id, $0.sha256) })
        let existingHashes = Dictionary(uniqueKeysWithValues: try assets().map { ($0.id, $0.sha256) })
        let existing = try Set(notes().map { try DeckExchange.fingerprint(kind: NoteKind(rawValue: $0.type) ?? .basic,
            content: JSONDecoder().decode(TextContent.self, from: $0.contentPayload), hashes: existingHashes) })
        var seen = existing, duplicates = Set<UUID>()
        for note in package.notes {
            let key = try DeckExchange.fingerprint(kind: note.kind, content: note.content, hashes: hashes)
            if !seen.insert(key).inserted { duplicates.insert(note.id) }
        }
        let existingDecks = try decks()
        let paths = LibraryIndex.deckPaths(existingDecks)
        let target: UUID?
        switch destination {
        case .newRoot: target = nil
        case .childOf(let id), .mergeInto(let id):
            guard existingDecks.contains(where: { $0.id == id }) else { throw StudyError.missingRecord }
            target = id
        }
        var mappings: [DeckImportMapping] = []
        var remaining = package.decks
        while !remaining.isEmpty {
            let ready = remaining.filter { source in source.parentID == nil || mappings.contains(where: { $0.id == source.parentID }) }
            guard !ready.isEmpty else { throw StudyError.invalidContent }
            for source in ready {
                let parent = mappings.first { $0.id == source.parentID }
                let parentID = parent?.targetID ?? target
                let sourcePath = [parent?.sourcePath, source.name].compactMap { $0 }.joined(separator: " / ")
                let parentPath = parent?.destinationPath ?? target.flatMap { paths[$0] }
                let matches = existingDecks.filter { $0.parentID == parentID && $0.name == source.name }
                let reuse: Deck?
                if source.id == package.rootID, case .mergeInto(let id) = destination {
                    reuse = existingDecks.first { $0.id == id }
                } else if case .mergeInto = destination, matches.count == 1,
                          package.decks.filter({ $0.parentID == source.parentID && $0.name == source.name }).count == 1 {
                    reuse = matches[0]
                } else { reuse = nil }
                var name = reuse?.name ?? source.name
                if reuse == nil {
                    var names = Set(existingDecks.filter { $0.parentID == parentID }.map(\.name))
                    names.formUnion(mappings.filter { $0.parentID == parentID }.map(\.name))
                    var suffix = 2
                    while names.contains(name) { name = "\(source.name)（取込 \(suffix)）"; suffix += 1 }
                }
                let path = reuse.flatMap { paths[$0.id] } ?? [parentPath, name].compactMap { $0 }.joined(separator: " / ")
                // Stable proposed IDs let confirmation compare the complete mapping.
                mappings.append(DeckImportMapping(id: source.id, targetID: reuse?.id ?? source.id,
                    parentID: parentID, name: name, sourcePath: sourcePath, destinationPath: path, reused: reuse != nil))
            }
            let processed = Set(ready.map(\.id))
            remaining.removeAll { processed.contains($0.id) }
        }
        var preview = DeckImportPreview(duplicates: duplicates,
            destinationName: mappings.first { $0.id == package.rootID }!.destinationPath, mappings: mappings)
        // Only reused destinations can be updated. Never relocate an existing note.
        if case .mergeInto = destination {
            let localNotes = Dictionary(grouping: try notes(), by: \.id)
            let localCards = Dictionary(grouping: try cards(), by: \.noteID)
            let tagNames = Dictionary(uniqueKeysWithValues: try tags().map { ($0.id, $0.name) })
            let draft = try session()
            let undoCardID: UUID?
            if let undoID = draft?.undoLogID { undoCardID = try logs().first { $0.id == undoID }?.cardID }
            else { undoCardID = nil }
            for source in package.notes {
                guard let matches = localNotes[source.id], matches.count == 1 else { continue }
                preview.duplicates.insert(source.id)
                let note = matches[0], existingCards = localCards[note.id] ?? []
                let before = try JSONDecoder().decode(TextContent.self, from: note.contentPayload)
                let variants = try CardGeneration.variants(kind: source.kind, content: source.content)
                let mapping = mappings.first { $0.id == source.deckID }
                let keys = existingCards.map(\.variantKey)
                let blocked: String?
                if mapping?.reused != true || mapping?.targetID != note.deckID {
                    blocked = "UUIDは一致しますが統合先が異なります。既存ノートは移動しません。"
                } else if note.type != source.kind.rawValue || Set(keys) != Set(variants) || keys.count != variants.count ||
                            !existingCards.allSatisfy({ $0.identityKey == "\(note.id.uuidString):\($0.variantKey)" }) {
                    blocked = "形式またはカード構成が変わるため、カードUUID・履歴を安全に対応付けできません。別ノートとして追加してください。"
                } else if existingCards.contains(where: { $0.id == draft?.cardID || $0.id == undoCardID }) {
                    blocked = "学習中またはUndo対象のノートです。進行中の回答・Undoを保護するため更新できません。スキップ／別ノート追加を選んでください。"
                } else { blocked = nil }
                if let blocked { preview.updateBlocked[source.id] = blocked; continue }
                var changes: [DeckNoteDifference] = []
                func difference(_ name: String, _ old: String, _ new: String) {
                    if old != new { changes.append(DeckNoteDifference(id: name, before: old.isEmpty ? "なし" : old, after: new.isEmpty ? "なし" : new)) }
                }
                difference("問題", before.question, source.content.question)
                difference("解答", before.answer, source.content.answer)
                difference("ヒント", before.hint ?? "", source.content.hint ?? "")
                difference("解説", before.explanation, source.content.explanation)
                let previousTags = note.tagIDs.compactMap { tagNames[$0] }.sorted()
                difference("タグ", previousTags.joined(separator: "、"), source.tags.sorted().joined(separator: "、"))
                func mediaDifference(_ name: String, _ old: UUID?, _ new: UUID?) {
                    let oldHash = old.flatMap { existingHashes[$0] }, newHash = new.flatMap { hashes[$0] }
                    guard oldHash != newHash else { return }
                    changes.append(DeckNoteDifference(id: name,
                        before: oldHash.map { "添付あり（内容ハッシュ：" + $0.prefix(12) + "）" } ?? "添付なし",
                        after: newHash.map { "添付あり（内容ハッシュ：" + $0.prefix(12) + "）" } ?? "添付なし"))
                }
                mediaDifference("画像", before.imageID, source.content.imageID)
                mediaDifference("問題音声", before.questionAudioID, source.content.questionAudioID)
                mediaDifference("解答音声", before.answerAudioID, source.content.answerAudioID)
                let previousMode = ResponseMode(rawValue: note.defaultResponseMode) ?? .mental
                difference("回答方法", previousMode.title, source.responseMode.title)
                difference("問題読み上げ", before.speechQuestion ?? "", source.content.speechQuestion ?? "")
                difference("解答読み上げ", before.speechAnswer ?? "", source.content.speechAnswer ?? "")
                difference("問題レイアウト", before.questionLayout?.rawValue ?? "標準", source.content.questionLayout?.rawValue ?? "標準")
                difference("解答レイアウト", before.answerLayout?.rawValue ?? "標準", source.content.answerLayout?.rawValue ?? "標準")
                // Strict comparison: anything affecting the prompt or answer requires reset.
                var oldCore = before, newCore = source.content
                oldCore.hint = nil; newCore.hint = nil
                oldCore.explanation = ""; newCore.explanation = ""
                oldCore.questionLayout = nil; newCore.questionLayout = nil
                oldCore.answerLayout = nil; newCore.answerLayout = nil
                let reset = try DeckExchange.fingerprint(kind: source.kind, content: oldCore, hashes: existingHashes) !=
                    DeckExchange.fingerprint(kind: source.kind, content: newCore, hashes: hashes) || previousMode != source.responseMode
                if reset && (source.kind == .cloze || source.kind == .imageOcclusion) {
                    preview.updateBlocked[source.id] = "穴埋め・マスクの出題変更は対応が曖昧になるため更新できません。別ノートとして追加してください。"
                    continue
                }
                guard !changes.isEmpty else { continue }
                preview.updates.append(DeckNoteUpdate(id: source.id, before: BackupNote(note),
                    cards: existingCards.map(BackupStudyCard.init).sorted { $0.id.uuidString < $1.id.uuidString },
                    beforeContent: before, beforeTags: previousTags, incoming: source,
                    mediaHashesBefore: [before.imageID, before.questionAudioID, before.answerAudioID].map { $0.flatMap { existingHashes[$0] } },
                    mediaHashesAfter: [source.content.imageID, source.content.questionAudioID, source.content.answerAudioID].map { $0.flatMap { hashes[$0] } },
                    changes: changes, requiresReset: reset, revision: mutationRevision))
            }
        }
        return preview
    }

    func importDeckPackage(_ validated: ValidatedDeckPackage, skipDuplicates: Bool, now: Date) throws -> Int {
        try importDeckPackageReceipt(validated, skipDuplicates: skipDuplicates, now: now).createdNotes
    }
    func importDeckPackageReceipt(_ validated: ValidatedDeckPackage, skipDuplicates: Bool, now: Date, destination: DeckImportDestination = .newRoot, expectedPreview: DeckImportPreview? = nil, updates: [UUID: DeckNoteUpdateConsent] = [:]) throws -> DeckImportReceipt {
        let interval = PerformanceProbe.begin("Import.deckPackage")
        defer { PerformanceProbe.end(interval) }
        // Only decode can construct this immutable, fully validated value. Do not
        // decode audio again on the UI actor when publishing the transaction.
        try Task.checkCancellation()
        let preview = try previewDeckImport(validated, destination: destination)
        if let expectedPreview, expectedPreview != preview { throw DeckImportPlanError.changed }
        if !updates.isEmpty {
            guard expectedPreview != nil else { throw DeckImportPlanError.consent }
            for (id, consent) in updates {
                guard let candidate = preview.updates.first(where: { $0.id == id }),
                      consent == (candidate.requiresReset ? .resetSchedule : .preserveHistory) else { throw DeckImportPlanError.consent }
            }
        }
        let notes = validated.package.notes.filter { updates[$0.id] != nil || !skipDuplicates || !preview.duplicates.contains($0.id) }
        let duplicateCount = skipDuplicates ? preview.duplicates.filter { updates[$0] == nil }.count : 0
        guard !notes.isEmpty else {
            return DeckImportReceipt(rootDeckID: nil, destinationName: nil, createdNotes: 0, createdCards: 0, duplicateNotes: duplicateCount)
        }
        let updateCandidates = Dictionary(uniqueKeysWithValues: preview.updates.map { ($0.id, $0) })
        let updateModels = updates.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: try self.notes().filter { updates[$0.id] != nil }.map { ($0.id, $0) })
        let updateCards = updates.isEmpty ? [:] : Dictionary(grouping: try cards().filter { updates[$0.noteID] != nil }, by: \.noteID)
        let localHashes = Dictionary(uniqueKeysWithValues: try self.assets().map { ($0.id, $0.sha256) })
        let sourceHashes = Dictionary(uniqueKeysWithValues: validated.package.media.map { ($0.id, $0.sha256) })
        let required = Set(notes.flatMap { source -> [UUID] in
            let incoming = [source.content.imageID, source.content.questionAudioID, source.content.answerAudioID]
            guard updates[source.id] != nil, let candidate = updateCandidates[source.id] else { return incoming.compactMap { $0 } }
            let old = [candidate.beforeContent.imageID, candidate.beforeContent.questionAudioID, candidate.beforeContent.answerAudioID]
            return zip(old, incoming).compactMap { previous, next in
                guard let next, previous.flatMap({ localHashes[$0] }) != sourceHashes[next] else { return nil }
                return next
            }
        })
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
            let deckIDs = Dictionary(uniqueKeysWithValues: preview.mappings.map { ($0.id, $0.reused ? $0.targetID : UUID()) })
            return try transaction {
                for asset in assets { context.insert(MediaAsset(image: asset, now: now)) }
                for mapping in preview.mappings where !mapping.reused {
                    let model = Deck(name: mapping.name, now: now)
                    model.id = deckIDs[mapping.id]!
                    model.parentID = mapping.parentID.map { deckIDs[$0] ?? $0 }
                    context.insert(model)
                }
                var cardCount = 0
                var importedTags: [[String]: [UUID]] = [:]
                for source in notes {
                    try Task.checkCancellation()
                    var content = source.content
                    content.imageID = content.imageID.flatMap { remapped[$0] }
                    content.questionAudioID = content.questionAudioID.flatMap { remapped[$0] }
                    content.answerAudioID = content.answerAudioID.flatMap { remapped[$0] }
                    let input = NoteInput(deckID: deckIDs[source.deckID]!, kind: source.kind, responseMode: source.responseMode)
                    let isUpdate = updates[source.id] != nil
                    let note: Note
                    if isUpdate {
                        guard let existing = updateModels[source.id] else { throw DeckImportPlanError.changed }
                        note = existing
                        let previous = try JSONDecoder().decode(TextContent.self, from: note.contentPayload)
                        content.speechOverrides = previous.speechOverrides
                        // Keep existing attachment UUIDs when their bytes have not changed.
                        if previous.imageID.flatMap({ localHashes[$0] }) == source.content.imageID.flatMap({ sourceHashes[$0] }) { content.imageID = previous.imageID }
                        if previous.questionAudioID.flatMap({ localHashes[$0] }) == source.content.questionAudioID.flatMap({ sourceHashes[$0] }) { content.questionAudioID = previous.questionAudioID }
                        if previous.answerAudioID.flatMap({ localHashes[$0] }) == source.content.answerAudioID.flatMap({ sourceHashes[$0] }) { content.answerAudioID = previous.answerAudioID }
                        note.contentPayload = try JSONEncoder().encode(content)
                        note.defaultResponseMode = source.responseMode.rawValue
                        note.updatedAt = now
                        if updates[source.id] == .resetSchedule {
                            for card in updateCards[note.id] ?? [] {
                                card.fsrsPayload = fresh; card.dueDate = now; card.updatedAt = now
                            }
                        }
                    } else { note = Note(input: input, content: try JSONEncoder().encode(content), now: now) }
                    if source.tags.isEmpty { note.tagIDs = [] }
                    else if let cached = importedTags[source.tags] { note.tagIDs = cached }
                    else {
                        let ids = try tagIDs(for: source.tags); note.tagIDs = ids
                        // Retain only a bounded number of tag combinations in this transaction.
                        if importedTags.count < 128 { importedTags[source.tags] = ids }
                    }
                    if !isUpdate {
                        context.insert(note)
                        for variant in try CardGeneration.variants(kind: source.kind, content: content) {
                            context.insert(StudyCard(noteID: note.id, variantKey: variant, payload: fresh, now: now))
                            cardCount += 1
                        }
                    }
                }
                return DeckImportReceipt(rootDeckID: deckIDs[validated.package.rootID], destinationName: preview.destinationName,
                                         createdNotes: notes.count - updates.count, createdCards: cardCount, duplicateNotes: duplicateCount,
                                         updatedNotes: updates.count, resetNotes: updates.values.filter { $0 == .resetSchedule }.count)
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
