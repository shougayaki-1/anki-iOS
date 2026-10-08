import Foundation
import SwiftData
import Observation

@MainActor @Observable
final class StudyStore {
    let repository: StudyRepository
    var clock: () -> Date
    var scope = LearningScope()
    var tags: [TagItem] = []
    var decks: [DeckItem] = []
    var notes: [NoteItem] = []
    var counts = HomeCounts()
    var settings = StudySettings()
    var review: ReviewPresentation?
    var failure: String?
    var showingReview = false

    init(container: ModelContainer, clock: @escaping () -> Date = Date.init) throws {
        repository = StudyRepository(container: container)
        self.clock = clock
        try repository.initialize(now: clock())
        scope = try repository.scope()
        try reload()
    }

    func reload() throws {
        repository.calendar = .current
        decks = try repository.decks().map { DeckItem(id: $0.id, name: try repository.deckPath($0.id)) }
        if let id = scope.deckID, !decks.contains(where: { $0.id == id }) { scope.deckID = nil }
        notes = try repository.noteItems()
        tags = try repository.tags().map { TagItem(id: $0.id, name: $0.name) }
        counts = try repository.scopedCounts(scope: scope, now: clock())
        settings = try repository.settings()
        review = try repository.presentation(now: clock())
    }

    @discardableResult
    func perform(_ work: () throws -> Void) -> Bool {
        do { try work(); try reload(); return true }
        catch { failure = error.localizedDescription; return false }
    }
    func start(_ mode: StudyMode) {
        if perform({ try repository.start(mode: mode, scope: scope, now: clock()) }) { showingReview = true }
    }
    func resume() {
        if perform({ try repository.resume(now: clock()) }) { showingReview = true }
    }
    func grade(_ grade: ReviewGrade) { perform { try repository.grade(grade, now: clock()) } }
    func undo() { perform { try repository.undo(now: clock()) } }
    func draft(mode: ResponseMode? = nil, text: String? = nil, revealed: Bool? = nil) {
        perform { try repository.updateDraft(mode: mode, text: text, revealed: revealed, now: clock()) }
    }
    func pause() {
        if perform({ try repository.setSessionActive(false, now: clock()) }) { showingReview = false }
    }
    func refreshQueue() {
        perform {
            if let draft = try repository.session(), draft.cardID == nil {
                try repository.resume(now: clock())
            }
        }
    }
}
