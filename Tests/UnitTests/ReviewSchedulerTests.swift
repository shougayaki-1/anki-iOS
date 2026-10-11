import XCTest
@testable import AnkiIOS

final class ReviewSchedulerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testFSRS6InitializationAndReviewLifecycle() throws {
        let scheduler = try ReviewScheduler()
        XCTAssertEqual(scheduler.parameterCount, 21)
        XCTAssertTrue(scheduler.usesFSRS6)
        let fresh = try scheduler.newCard(now: now)
        XCTAssertEqual(try scheduler.summary(fresh).state, "new")
        let run = try SchedulerVerification.run(now: now, scheduler: scheduler)
        let summaries = try run.transitions.map { try scheduler.summary($0.after) }
        XCTAssertEqual(summaries.map(\.state), ["learning", "review", "relearning", "review"])
        XCTAssertEqual(summaries.map(\.repetitions), [1, 2, 3, 4])
        XCTAssertEqual(summaries.map(\.lapses), [0, 0, 1, 1])
        XCTAssertEqual(summaries[0].learningStep, 1)
        XCTAssertEqual(summaries[0].stability, 2.3065, accuracy: 0.000001)
        XCTAssertEqual(summaries[0].dueDate, now.addingTimeInterval(600))
        XCTAssertEqual(summaries[2].dueDate, run.transitions[2].reviewedAt.addingTimeInterval(600))
        for (index, transition) in run.transitions.enumerated() {
            XCTAssertEqual(summaries[index].lastReview, transition.reviewedAt)
            XCTAssertGreaterThan(summaries[index].dueDate, transition.reviewedAt)
            XCTAssertTrue(summaries[index].stability.isFinite)
            XCTAssertGreaterThan(summaries[index].stability, 0)
            XCTAssertTrue((1...10).contains(summaries[index].difficulty))
            if index > 0 {
                XCTAssertEqual(transition.before, run.transitions[index - 1].after)
                XCTAssertEqual(transition.reviewedAt, summaries[index - 1].dueDate)
            }
        }
    }

    func testAllFourGradesAndShortTermAgain() throws {
        let scheduler = try ReviewScheduler()
        let fresh = try scheduler.newCard(now: now)
        for grade in ReviewGrade.allCases {
            let transition = try scheduler.review(fresh, grade: grade, now: now)
            let summary = try scheduler.summary(transition.after)
            XCTAssertEqual(summary.repetitions, 1)
            XCTAssertGreaterThan(summary.dueDate, now)
            if grade == .again {
                XCTAssertEqual(summary.state, "learning")
                XCTAssertEqual(summary.dueDate, now.addingTimeInterval(60))
            }
        }
    }

    func testCompleteSnapshotRoundTripAndContinuation() throws {
        let scheduler = try ReviewScheduler()
        let run = try SchedulerVerification.run(now: now, scheduler: scheduler)
        for transition in run.transitions {
            let data = try JSONEncoder().encode(transition)
            let restored = try JSONDecoder().decode(ReviewTransition.self, from: data)
            XCTAssertEqual(restored, transition)
            let date = try scheduler.summary(transition.after).dueDate
            XCTAssertEqual(try scheduler.review(restored.after, grade: .good, now: date),
                           try scheduler.review(transition.after, grade: .good, now: date))
        }
    }

    func testRetrievabilityUsesInjectedTimeAndRetentionBounds() throws {
        let scheduler = try ReviewScheduler()
        let run = try SchedulerVerification.run(now: now, scheduler: scheduler)
        let last = try XCTUnwrap(scheduler.summary(run.finalSnapshot).lastReview)
        XCTAssertGreaterThan(try scheduler.retrievability(run.finalSnapshot, now: last),
                             try scheduler.retrievability(run.finalSnapshot, now: last.addingTimeInterval(86400 * 30)))
        XCTAssertThrowsError(try ReviewScheduler(desiredRetention: 0.79))
        XCTAssertThrowsError(try ReviewScheduler(desiredRetention: 0.98))
        XCTAssertNoThrow(try ReviewScheduler(desiredRetention: 0.8))
        XCTAssertNoThrow(try ReviewScheduler(desiredRetention: 0.97))
        let invalid = SchedulerSnapshot(schemaVersion: 2, algorithmVersion: "FSRS-6", cardData: Data())
        XCTAssertThrowsError(try scheduler.summary(invalid))
    }
}

final class FSRSOptimizationTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    func reviews() -> [OptimizationReview] {
        let cards = (0..<30).map { _ in UUID() }
        return (0..<40).flatMap { day in
            cards.enumerated().map { index, card in
                OptimizationReview(id: UUID(), cardID: card, date: base.addingTimeInterval(Double(day) * 86400),
                                   grade: day > 0 && (day + index) % 5 == 0 ? 1 : 3,
                                   sequence: day * 30 + index, startsNew: day == 0)
            }
        }
    }
    func testInsufficientMissingBeginningDiversityLimitsAndInvalidParameters() throws {
        let data = reviews()
        XCTAssertThrowsError(try FSRSOptimization.prepare([]))
        XCTAssertThrowsError(try FSRSOptimization.prepare(Array(data.suffix(600))))
        XCTAssertThrowsError(try FSRSOptimization.prepare(data.map {
            OptimizationReview(id: $0.id, cardID: $0.cardID, date: $0.date, grade: 3, sequence: $0.sequence, startsNew: $0.startsNew)
        }))
        XCTAssertThrowsError(try FSRSOptimization.prepare(Array(repeating: data[0], count: 10001)))
        XCTAssertThrowsError(try FSRSOptimization.prepare(data + [data[0]]))
        XCTAssertTrue(FSRSOptimization.validParameters(FSRSOptimization.defaults))
        XCTAssertFalse(FSRSOptimization.validParameters(Array(repeating: .nan, count: 21)))
        XCTAssertThrowsError(try ReviewScheduler(parameters: [1]))
    }
    func testChronologicalSplitDeterministicReplayAndTimeout() throws {
        let data = reviews(), input = try FSRSOptimization.prepare(data)
        XCTAssertEqual(input.days, 40)
        let standard = try FSRSOptimization.evaluate(input, parameters: FSRSOptimization.defaults, validation: true)
        XCTAssertEqual(standard.count, 210)
        XCTAssertEqual(standard, try FSRSOptimization.evaluate(input, parameters: FSRSOptimization.defaults, validation: true))
        var changed = FSRSOptimization.defaults; changed[0] *= 1.3; changed[2] *= 1.3
        let candidate = try FSRSOptimization.evaluate(input, parameters: changed, validation: true)
        XCTAssertNotEqual(candidate.logLoss, standard.logLoss)
        XCTAssertThrowsError(try FSRSOptimization.evaluate(input, parameters: changed, validation: false, deadline: .distantPast))
        var validationChanged = data
        for index in validationChanged.indices where validationChanged[index].date > input.split {
            let old = validationChanged[index]
            validationChanged[index] = OptimizationReview(id: old.id, cardID: old.cardID, date: old.date,
                                                         grade: old.grade == 1 ? 3 : 1, sequence: old.sequence, startsNew: false)
        }
        let changedInput = try FSRSOptimization.prepare(validationChanged)
        XCTAssertEqual(try FSRSOptimization.evaluate(input, parameters: changed, validation: false),
                       try FSRSOptimization.evaluate(changedInput, parameters: changed, validation: false))
    }
    func testOptimizationReproducibilityAndCancellation() async throws {
        let data = reviews(), now = base.addingTimeInterval(86400 * 41)
        let first = try FSRSOptimization.run(data, now: now)
        let second = try FSRSOptimization.run(data, now: now)
        XCTAssertTrue(first.valid)
        XCTAssertEqual(first.parameters, second.parameters)
        XCTAssertEqual(first.standard, second.standard)
        XCTAssertEqual(first.candidate, second.candidate)
        XCTAssertEqual(first.accepted, second.accepted)
        let task = Task.detached { () throws -> OptimizationReport in
            while !Task.isCancelled { await Task.yield() }
            return try FSRSOptimization.run(data, now: now)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
    }
}
