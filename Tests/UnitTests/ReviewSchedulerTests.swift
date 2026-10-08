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
