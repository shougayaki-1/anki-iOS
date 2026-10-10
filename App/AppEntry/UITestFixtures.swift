#if DEBUG
import Foundation
import UIKit
import SwiftData

// Only explicit UI-test launch arguments create fixtures, in the app's sandbox.
enum UITestFixtures {
    @MainActor static func configureAccessibilityScene() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            scene.traitOverrides.userInterfaceStyle = .dark
        }
    }
    @MainActor static func populateScale(_ repository: StudyRepository, now: Date) throws {
        guard try repository.notes().isEmpty else { return }
        let base = now.addingTimeInterval(-300 * 86400), scheduler = try ReviewScheduler()
        let fresh = try JSONEncoder().encode(scheduler.newCard(now: base)), deck = try repository.decks()[0].id
        try repository.transaction {
            var cards: [StudyCard] = []
            for index in 0..<1000 {
                let input = NoteInput(deckID: deck, kind: .cloze, question: "Scale \(index) {{c1::one}} {{c2::two}} {{c3::three}}")
                let note = Note(input: input, content: try JSONEncoder().encode(TextContent(question: input.question, answer: "", explanation: "")), now: base)
                repository.context.insert(note)
                for variant in 1...3 {
                    let card = StudyCard(noteID: note.id, variantKey: "cloze:\(variant)", payload: fresh, now: base)
                    repository.context.insert(card); cards.append(card)
                }
            }
            for index in 0..<10000 {
                let card = cards[index % cards.count], date = base.addingTimeInterval(Double(index) * 60)
                let before = try repository.snapshot(card), wasNew = try scheduler.summary(before).state == "new"
                let transition = try scheduler.review(before, grade: .easy, now: date)
                let after = try JSONEncoder().encode(transition.after)
                repository.context.insert(StudyReviewLog(card: card, transition: transition, before: card.fsrsPayload, after: after,
                                                         mode: .mental, durationMs: 1000, wasNew: wasNew, sequence: index + 1))
                card.fsrsPayload = after; card.dueDate = try scheduler.summary(transition.after).dueDate; card.updatedAt = date
            }
        }
    }
    @MainActor static func populateDueNotification(_ repository: StudyRepository, now: Date) throws {
        guard try repository.notes().isEmpty else { return }
        let base = now.addingTimeInterval(-7200)
        try repository.createNote(NoteInput(deckID: repository.decks()[0].id, question: "通知の実機確認", answer: "通知からホームへ戻る"), now: base)
        try repository.start(mode: .new, now: base)
        try repository.updateDraft(revealed: true, now: base)
        try repository.grade(.again, now: base)
        try repository.setSessionActive(false, now: base)
        try repository.completeSession(now: base)
        var settings = try repository.settings()
        let parts = Calendar.current.dateComponents([.hour, .minute], from: now.addingTimeInterval(180))
        settings.notification.hour = parts.hour ?? 20
        settings.notification.minute = parts.minute ?? 0
        settings.notification.enabled = false
        try repository.updateSettings(settings)
    }
    @MainActor static func populateHints(_ repository: StudyRepository, now: Date) throws {
        guard try repository.notes().isEmpty else { return }
        let deck = try repository.decks()[0].id
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }.pngData()!
        let image = try repository.addImage(bytes, now: now)
        for kind in NoteKind.allCases {
            var input = NoteInput(deckID: deck, kind: kind,
                                  question: kind == .cloze ? "{{c1::Tokyo::city}} and {{c2::Japan}}" : "Hint \(kind.rawValue)",
                                  answer: "Reverse question", hint: "Shared \(kind.rawValue) hint", reverseEnabled: kind == .basic)
            if kind == .imageOcclusion {
                input.imageID = image
                input.masks = [ImageMask(rect: MaskRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), answer: "one"),
                               ImageMask(rect: MaskRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), answer: "two")]
            }
            try repository.createNote(input, now: now)
        }
        var settings = try repository.settings(); settings.siblingBuryEnabled = false
        try repository.updateSettings(settings)
    }
    @MainActor static func populateHomeFilters(_ repository: StudyRepository, now: Date) throws {
        guard try repository.notes().isEmpty else { return }
        let root = try repository.decks()[0].id
        let child = try repository.createDeck(name: "Child", parentID: root, now: now)
        let other = try repository.createDeck(name: "Other", now: now)
        try repository.createNote(NoteInput(deckID: child, question: "Both tags", answer: "A", tagNames: ["A", "B"]), now: now)
        try repository.createNote(NoteInput(deckID: child, question: "Only A", answer: "A", tagNames: ["A"]), now: now)
        try repository.createNote(NoteInput(deckID: other, question: "Other card", answer: "A", tagNames: ["A", "B"]), now: now)
    }
    static func prepare(name: String) throws {
        guard UUID(uuidString: name) != nil else { throw StudyError.invalidContent }
        let documents = URL.documentsDirectory
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data("question,answer\nCSV file question,CSV file answer\n".utf8)
            .write(to: documents.appendingPathComponent("UITest-\(name).csv"), options: .atomic)
        try Data("invalid ZIP fixture".utf8)
            .write(to: documents.appendingPathComponent("Invalid-\(name).studybackup"), options: .atomic)
    }
}
#endif
