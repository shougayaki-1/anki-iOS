import XCTest
import SwiftData
@testable import AnkiIOS

@MainActor
final class SpeechRepositoryTests: XCTestCase {
    func testDeckAndVariantSpeechSurviveEditingAndBackupWithoutResettingFSRS() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true))
        try repo.initialize(now: now)
        let deckID = try XCTUnwrap(repo.decks().first?.id)

        var settings = try repo.settings()
        settings.speech.accent = .british
        settings.speech.pace = .slow
        settings.speech.deckAutoplay[deckID.uuidString] = .both
        try repo.updateSettings(settings)
        XCTAssertEqual(try repo.settings().speech, settings.speech)

        var input = NoteInput(deckID: deckID, kind: .basic,
                              question: "What is it?", answer: "An English sentence.",
                              reverseEnabled: true,
                              speechOverrides: ["basic:front": .question, "basic:reverse": .answer],
                              speechQuestion: "What is this?", speechAnswer: "It is an English sentence.")
        let noteID = try repo.createNote(input, now: now)
        let items = try repo.noteItems().filter { $0.noteID == noteID }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.compactMap { $0.sourceContent.speechOverrides?[$0.variantKey] }), [.question, .answer])
        let beforeIDs = Set(items.map(\.cardID))

        try repo.start(mode: .new, now: now)
        try repo.updateDraft(revealed: true, now: now)
        try repo.grade(.good, now: now)
        let savedLogs = try repo.logs().map(\.id)
        let savedSnapshots = try Dictionary(uniqueKeysWithValues:
            repo.cards().map { ($0.id, $0.fsrsPayload) })

        input.speechOverrides = ["basic:front": .off, "basic:reverse": .answer]
        input.speechQuestion = "Read the question differently."
        try repo.updateNote(id: noteID, input: input, now: now.addingTimeInterval(10))
        XCTAssertEqual(Set(try repo.noteItems().filter { $0.noteID == noteID }.map(\.cardID)), beforeIDs)
        XCTAssertEqual(try repo.logs().map(\.id), savedLogs)
        XCTAssertEqual(try Dictionary(uniqueKeysWithValues: repo.cards().map { ($0.id, $0.fsrsPayload) }), savedSnapshots)
        XCTAssertEqual(try repo.noteItems().first(where: { $0.variantKey == "basic:front" })?.sourceContent.speechOverrides?["basic:front"], .off)

        let backup = try BackupData.capture(repo)
        let storedNote = try XCTUnwrap(backup.notes.first(where: { $0.id == noteID }))
        let storedContent = try JSONDecoder().decode(TextContent.self, from: storedNote.contentPayload)
        XCTAssertEqual(storedContent.speechQuestion, "Read the question differently.")
        XCTAssertEqual(storedContent.speechOverrides?["basic:front"], .off)
        let storedOptions = try XCTUnwrap(backup.options.first)
        XCTAssertEqual(try JSONDecoder().decode(StudyOptions.self, from: storedOptions.payload).speech, settings.speech)
    }

    func testImportedEnglishCanBeReadWithoutAttachedMediaAndKeepsDeckOffDefault() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let repo = StudyRepository(container: try PersistenceController.makeStudyContainer(inMemory: true))
        try repo.initialize(now: now)
        let deck = try XCTUnwrap(repo.decks().first?.id)
        let rows = [ImportRow(line: 2, question: "How are you?", answer: "I am fine.")]
        let result = try repo.importRows(rows, deckID: deck, kind: .basic, tagNames: [],
                                         action: .add, source: "csv", now: now)
        XCTAssertEqual(result.imported, 1)
        let item = try XCTUnwrap(repo.noteItems().first)
        XCTAssertEqual(SpeechReadout.text(kind: item.kind, displayed: item.content, side: .question), "How are you?")
        XCTAssertEqual(SpeechReadout.text(kind: item.kind, displayed: item.content, side: .answer), "I am fine.")
        XCTAssertEqual(try repo.settings().speech.autoplay(deckID: deck,
                                                            noteOverride: item.sourceContent.speechOverrides?[item.variantKey]), .off)
    }
}
