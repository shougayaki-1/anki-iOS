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

    func testGuidanceShowsActualHistoryShortages() {
        let empty = FSRSOptimizationGuidance.unmetRequirements(for: [])
        XCTAssertTrue(empty.contains { $0.contains("0件") && $0.contains("400件") })
        XCTAssertTrue(empty.contains { $0.contains("0日") && $0.contains("30日") })

        let cards = (0..<10).map { _ in UUID() }
        let shortHistory = (0..<10).flatMap { day in
            cards.enumerated().map { index, card in
                OptimizationReview(id: UUID(), cardID: card,
                                   date: base.addingTimeInterval(Double(day) * 86400),
                                   grade: 3, sequence: day * 10 + index, startsNew: day == 0)
            }
        }
        let messages = FSRSOptimizationGuidance.unmetRequirements(for: shortHistory)
        XCTAssertTrue(messages.contains { $0.contains("90件") && $0.contains("400件") })
        XCTAssertTrue(messages.contains { $0.contains("10日") && $0.contains("30日") })
        XCTAssertTrue(messages.contains { $0.contains("10枚") && $0.contains("20枚") })
    }

    func testGuidanceDistinguishesGradeImbalanceFromCountShortage() {
        let alwaysRecalled = reviews().map {
            OptimizationReview(id: $0.id, cardID: $0.cardID, date: $0.date,
                               grade: 3, sequence: $0.sequence, startsNew: $0.startsNew)
        }
        let messages = FSRSOptimizationGuidance.unmetRequirements(for: alwaysRecalled)
        XCTAssertTrue(messages.contains { $0.contains("学習用") && $0.contains("Again 0件") })
        XCTAssertTrue(messages.contains { $0.contains("検証用") && $0.contains("Again 0件") })
        XCTAssertFalse(messages.contains { $0.contains("必要400件") })
    }

    func testGuidanceConfirmsOnlyVerifiedStateTransitions() {
        let values = FSRSOptimization.defaults
        XCTAssertNil(FSRSOptimizationGuidance.appliedConfirmation(expected: values, active: nil))
        XCTAssertEqual(FSRSOptimizationGuidance.appliedConfirmation(expected: values, active: values),
                       "個人最適化を適用しました。次回の回答から有効です")
        XCTAssertNil(FSRSOptimizationGuidance.resetConfirmation(wasPersonalized: false, active: nil))
        XCTAssertNil(FSRSOptimizationGuidance.resetConfirmation(wasPersonalized: true, active: values))
        XCTAssertNotNil(FSRSOptimizationGuidance.resetConfirmation(wasPersonalized: true, active: nil))
    }

    func testGuidanceSeparatesHistoryShortageAndOtherErrors() {
        let shortage = FSRSOptimizationGuidance.failureDescription(OptimizationError.insufficient)
        let stale = FSRSOptimizationGuidance.failureDescription(OptimizationError.stale)
        let invalid = FSRSOptimizationGuidance.failureDescription(OptimizationError.invalid)
        XCTAssertTrue(shortage.contains("学習履歴"))
        XCTAssertTrue(stale.contains("もう一度"))
        XCTAssertTrue(invalid.contains("開き直して"))
        XCTAssertNotEqual(shortage, stale)
        XCTAssertNotEqual(shortage, invalid)
    }

    func testPresentationReadRecoveryAndActionAvailability() {
        let report = OptimizationReport(
            generatedAt: base, digest: String(repeating: "a", count: 64),
            reviews: 400, days: 30, splitDate: base, parameters: FSRSOptimization.defaults,
            previousParameters: nil,
            standard: OptimizationMetrics(count: 80, logLoss: 1, rmse: 0.8),
            candidate: OptimizationMetrics(count: 80, logLoss: 0.9, rmse: 0.7),
            previous: nil, duration: 1
        )
        var standard = FSRSOptimizationState()
        standard.report = report
        var personalized = standard
        personalized.activeParameters = report.parameters
        var presentation = FSRSOptimizationPresentation()

        // 9: Unverified state never enables actions, even when a cached report existed.
        XCTAssertEqual(presentation.statusText, "未確認（再確認してください）")
        XCTAssertFalse(presentation.canReset(computing: false))
        XCTAssertFalse(presentation.canApply(report, computing: false))
        XCTAssertNil(presentation.matchesActiveParameters(nil))

        presentation.didRead(standard)
        XCTAssertEqual(presentation.statusText, "標準パラメータ")
        XCTAssertTrue(presentation.canApply(report, computing: false))
        XCTAssertFalse(presentation.canReset(computing: false))
        XCTAssertEqual(presentation.matchesActiveParameters(nil), true)

        presentation.successNotice = "直前の成功"
        // 8: A read failure removes stale success and forbids stale buttons.
        presentation.readFailed("設定状態を確認できません")
        XCTAssertNil(presentation.successNotice)
        XCTAssertNotNil(presentation.readFailure)
        XCTAssertEqual(presentation.statusText, "未確認（再確認してください）")
        XCTAssertFalse(presentation.canApply(report, computing: false))
        XCTAssertFalse(presentation.canReset(computing: false))

        // 7: Retry succeeds, clears the read error and restores verified controls.
        presentation.didRead(personalized)
        XCTAssertNil(presentation.readFailure)
        XCTAssertEqual(presentation.statusText, "個人パラメータ")
        XCTAssertTrue(presentation.canReset(computing: false))
        XCTAssertFalse(presentation.canApply(report, computing: false))
        XCTAssertEqual(presentation.matchesActiveParameters(report.parameters), true)
    }

    func testPersistenceOutcomeCoversApplyResetAndReportPaths() {
        typealias Outcome = FSRSOptimizationPersistenceOutcome
        // The six independent combinations required by the follow-up review.
        let complete = Outcome.classify(repositorySucceeded: true, homeReloadSucceeded: true,
                                        confirmedMatch: true)
        XCTAssertEqual(complete.save, .succeeded)
        XCTAssertEqual(complete.home, .succeeded)
        XCTAssertEqual(complete.read, .matched)
        XCTAssertTrue(complete.isComplete)

        let homeFailed = Outcome.classify(repositorySucceeded: true, homeReloadSucceeded: false,
                                          confirmedMatch: true)
        XCTAssertEqual(homeFailed.home, .failed)
        XCTAssertEqual(homeFailed.read, .matched)
        XCTAssertFalse(homeFailed.isComplete)

        let homeAndReadFailed = Outcome.classify(repositorySucceeded: true, homeReloadSucceeded: false,
                                                 confirmedMatch: nil)
        XCTAssertEqual(homeAndReadFailed.save, .succeeded)
        XCTAssertEqual(homeAndReadFailed.home, .failed)
        XCTAssertEqual(homeAndReadFailed.read, .unavailable)
        XCTAssertFalse(homeAndReadFailed.isComplete)

        let writeFailed = Outcome.classify(repositorySucceeded: false, homeReloadSucceeded: false,
                                           confirmedMatch: true)
        XCTAssertEqual(writeFailed.save, .failed)
        XCTAssertEqual(writeFailed.home, .notAttempted)
        XCTAssertEqual(writeFailed.read, .matched)

        let writeAndReadFailed = Outcome.classify(repositorySucceeded: false, homeReloadSucceeded: false,
                                                  confirmedMatch: nil)
        XCTAssertEqual(writeAndReadFailed.save, .failed)
        XCTAssertEqual(writeAndReadFailed.home, .notAttempted)
        XCTAssertEqual(writeAndReadFailed.read, .unavailable)
        XCTAssertFalse(writeAndReadFailed.isComplete)

        let mismatch = Outcome.classify(repositorySucceeded: true, homeReloadSucceeded: true,
                                        confirmedMatch: false)
        XCTAssertEqual(mismatch.save, .succeeded)
        XCTAssertEqual(mismatch.home, .succeeded)
        XCTAssertEqual(mismatch.read, .mismatched)
        XCTAssertFalse(mismatch.isComplete)
    }

    func testCompoundFailureWarningsSurviveReadRetryForAllThreeOperations() {
        typealias Outcome = FSRSOptimizationPersistenceOutcome
        let report = OptimizationReport(
            generatedAt: base, digest: String(repeating: "a", count: 64),
            reviews: 400, days: 30, splitDate: base, parameters: FSRSOptimization.defaults,
            previousParameters: nil,
            standard: OptimizationMetrics(count: 80, logLoss: 1, rmse: 0.8),
            candidate: OptimizationMetrics(count: 80, logLoss: 0.9, rmse: 0.7),
            previous: nil, duration: 1
        )
        for kind in FSRSOptimizationOperation.Kind.allCases {
            var verified = FSRSOptimizationState()
            let target: FSRSOptimizationOperation.Target
            switch kind {
            case .apply:
                verified.activeParameters = report.parameters
                target = .parameters(report.parameters)
            case .reset:
                target = .parameters(nil)
            case .report:
                verified.report = report
                target = .report(report)
            }
            // A: The write failed and settings were temporarily unreadable.
            var writeFailed = FSRSOptimizationOperation(
                kind: kind, target: target,
                outcome: Outcome.classify(repositorySucceeded: false, homeReloadSucceeded: false,
                                          confirmedMatch: nil), errorDetail: "WRITE_FAILED"
            )
            XCTAssertTrue(writeFailed.warning?.contains("保存できませんでした") == true)
            XCTAssertFalse(writeFailed.warning?.contains("保存後") == true)
            XCTAssertEqual(writeFailed.outcome.home, .notAttempted)
            writeFailed.recheck(verified)
            XCTAssertEqual(writeFailed.outcome.read, .matched)
            XCTAssertEqual(writeFailed.outcome.save, .failed)
            XCTAssertTrue(writeFailed.warning?.contains("WRITE_FAILED") == true)
            XCTAssertFalse(writeFailed.outcome.isComplete)

            // B: Write completed but home refresh failed; retry only repairs the read.
            var homeFailed = FSRSOptimizationOperation(
                kind: kind, target: target,
                outcome: Outcome.classify(repositorySucceeded: true, homeReloadSucceeded: false,
                                          confirmedMatch: nil), errorDetail: "HOME_FAILED"
            )
            XCTAssertTrue(homeFailed.warning?.contains("ホーム画面の更新に失敗") == true)
            homeFailed.recheck(verified)
            XCTAssertEqual(homeFailed.outcome.read, .matched)
            XCTAssertEqual(homeFailed.outcome.home, .failed)
            XCTAssertTrue(homeFailed.warning?.contains("HOME_FAILED") == true)
            XCTAssertFalse(homeFailed.outcome.isComplete)
            XCTAssertFalse(homeFailed.warning?.contains("設定状態を確認できません") == true)
        }
    }

    func testFailedReportSaveCannotMasqueradeAsPreviouslyStoredReport() {
        typealias Outcome = FSRSOptimizationPersistenceOutcome
        let report = OptimizationReport(
            generatedAt: base, digest: String(repeating: "a", count: 64),
            reviews: 400, days: 30, splitDate: base, parameters: FSRSOptimization.defaults,
            previousParameters: nil,
            standard: OptimizationMetrics(count: 80, logLoss: 1, rmse: 0.8),
            candidate: OptimizationMetrics(count: 80, logLoss: 0.9, rmse: 0.7),
            previous: nil, duration: 1
        )
        var verified = FSRSOptimizationState()
        verified.report = report
        var presentation = FSRSOptimizationPresentation()
        presentation.didRead(verified)
        presentation.readFailed("READ_FAILED")
        XCTAssertNil(presentation.state?.report)
        var operation = FSRSOptimizationOperation(
            kind: .report, target: .report(report),
            outcome: Outcome.classify(repositorySucceeded: false, homeReloadSucceeded: false,
                                      confirmedMatch: nil), errorDetail: "WRITE_FAILED"
        )
        XCTAssertTrue(operation.warning?.contains("計算結果を保存できませんでした") == true)
        XCTAssertFalse(operation.warning?.contains("保存後") == true)
        presentation.didRead(verified)
        operation.recheck(presentation.state)
        XCTAssertEqual(operation.outcome.save, .failed)
        XCTAssertFalse(operation.outcome.isComplete)
        XCTAssertTrue(operation.warning?.contains("保存できませんでした") == true)
        XCTAssertNil(operation.kind.successMessage)
    }
}
