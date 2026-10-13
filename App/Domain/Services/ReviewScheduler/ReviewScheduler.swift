import Foundation
import FSRS

enum ReviewGrade: Int, CaseIterable, Codable {
    case again = 1, hard, good, easy
}

struct SchedulerSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let algorithmVersion: String
    // The entire upstream Codable Card, including learningSteps, is retained.
    let cardData: Data
}

struct ReviewTransition: Codable, Equatable {
    let before: SchedulerSnapshot
    let after: SchedulerSnapshot
    let reviewedAt: Date
    let grade: ReviewGrade
    let logData: Data
}

struct ScheduleSummary: Equatable {
    let state: String
    let dueDate: Date
    let lastReview: Date?
    let stability: Double
    let difficulty: Double
    let repetitions: Int
    let lapses: Int
    let learningStep: Int
}

enum SchedulerError: Error {
    case unsupportedSnapshot
    case invalidRetention
}

// FSRS types remain inside this adapter, rather than reaching SwiftUI or SwiftData.
struct ReviewScheduler {
    static let algorithmVersion = "FSRS-6"
    static let revision = "4fbaf20184d62f82a9f44f343337c61a2c5483e9"
    private let engine: FSRS

    init(desiredRetention: Double = 0.9, parameters: [Double]? = nil) throws {
        if let parameters, !FSRSOptimization.validParameters(parameters) { throw OptimizationError.invalid }
        guard (0.8...0.97).contains(desiredRetention) else {
            throw SchedulerError.invalidRetention
        }
        engine = FSRS(parameters: FSRSParameters(
            requestRetention: desiredRetention,
            w: parameters ?? FSRSDefaults.defaultWv6,
            enableFuzz: false,
            enableShortTerm: true
        ))
    }

    var parameterCount: Int { engine.params.w.count }
    var usesFSRS6: Bool { engine.version == .v6 }

    func newCard(now: Date) throws -> SchedulerSnapshot {
        try snapshot(Card(due: now))
    }

    func review(_ input: SchedulerSnapshot, grade: ReviewGrade, now: Date) throws -> ReviewTransition {
        let result = try engine.next(card: decode(input), now: now, grade: Rating(rawValue: grade.rawValue)!)
        var log = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.log)) as! [String: Any]
        log["parameterProfile"] = engine.params.w
        log["schedulerRevision"] = Self.revision
        return ReviewTransition(
            before: input, after: try snapshot(result.card), reviewedAt: now,
            grade: grade, logData: try JSONSerialization.data(withJSONObject: log, options: .sortedKeys)
        )
    }

    func summary(_ input: SchedulerSnapshot) throws -> ScheduleSummary {
        let card = try decode(input)
        return ScheduleSummary(
            state: card.state.stringValue, dueDate: card.due, lastReview: card.lastReview,
            stability: card.stability, difficulty: card.difficulty,
            repetitions: card.reps, lapses: card.lapses, learningStep: card.learningSteps
        )
    }

    func retrievability(_ input: SchedulerSnapshot, now: Date) throws -> Double {
        engine.getRetrievability(card: try decode(input), now: now).number
    }

    // A value-only, read-only input for repeated statistical predictions. The
    // upstream Card stays encapsulated here and is never a persistence model.
    struct PredictionState {
        fileprivate let card: Card
        var isNew: Bool { card.state.stringValue == "new" }
        var state: String { card.state.stringValue }
        var canRankReview: Bool {
            state == "review" && card.stability.isFinite && card.stability > 0 &&
                card.difficulty.isFinite && (1...10).contains(card.difficulty) && card.lastReview != nil
        }
    }
    func predictionState(_ input: SchedulerSnapshot) throws -> PredictionState {
        PredictionState(card: try decode(input))
    }
    func retrievability(_ input: PredictionState, now: Date) -> Double {
        engine.getRetrievability(card: input.card, now: now).number
    }

    private func snapshot(_ card: Card) throws -> SchedulerSnapshot {
        SchedulerSnapshot(schemaVersion: 1, algorithmVersion: Self.algorithmVersion,
                          cardData: try JSONEncoder().encode(card))
    }

    private func decode(_ input: SchedulerSnapshot) throws -> Card {
        guard input.schemaVersion == 1, input.algorithmVersion == Self.algorithmVersion else {
            throw SchedulerError.unsupportedSnapshot
        }
        return try JSONDecoder().decode(Card.self, from: input.cardData)
    }
}

struct SchedulerVerification {
    let transitions: [ReviewTransition]
    let finalSnapshot: SchedulerSnapshot

    // Simulated review dates: this is a development probe, not a learning session.
    static func run(now: Date, scheduler: ReviewScheduler) throws -> Self {
        let fresh = try scheduler.newCard(now: now)
        let first = try scheduler.review(fresh, grade: .good, now: now)
        let secondDate = try scheduler.summary(first.after).dueDate
        let second = try scheduler.review(first.after, grade: .good, now: secondDate)
        let forgottenDate = try scheduler.summary(second.after).dueDate
        let forgotten = try scheduler.review(second.after, grade: .again, now: forgottenDate)
        let recoveredDate = try scheduler.summary(forgotten.after).dueDate
        let recovered = try scheduler.review(forgotten.after, grade: .good, now: recoveredDate)
        return Self(transitions: [first, second, forgotten, recovered], finalSnapshot: recovered.after)
    }
}
