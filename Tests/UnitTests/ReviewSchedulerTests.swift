import XCTest
import Darwin
@testable import AnkiIOS

final class ReviewSchedulerTests: XCTestCase {
    func testPreparedStatisticalPredictionMatchesSnapshotAtEveryTime() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let scheduler = try ReviewScheduler()
        let fresh = try scheduler.newCard(now: now)
        let reviewed = try scheduler.review(fresh, grade: .easy, now: now).after
        for snapshot in [fresh, reviewed] {
            let state = try scheduler.predictionState(snapshot)
            XCTAssertEqual(state.isNew, try scheduler.summary(snapshot).state == "new")
            let offsets: [Double] = [0, 60, 86400, 86400 * 30]
            for delta in offsets {
                let date = now.addingTimeInterval(delta)
                XCTAssertEqual(scheduler.retrievability(state, now: date), try scheduler.retrievability(snapshot, now: date), accuracy: 0.000000001)
            }
        }
    }
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

// Synthetic data only. This audit deliberately makes no assertion that fitting wins.
final class FSRSOptimizationAuditTests: XCTestCase {
    struct Random {
        var state: UInt64
        mutating func unit() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / 9007199254740992
        }
    }
    struct Prediction {
        let event: OptimizationReview
        let probability: Double
        var outcome: Double { event.grade == 1 ? 0 : 1 }
        var loss: Double { -outcome * log(probability) - (1 - outcome) * log(1 - probability) }
    }
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
    }
    func personalized() -> [Double] {
        var w = FSRSOptimization.defaults
        for index in 0...3 { w[index] *= 0.6 }
        w[8] *= 0.7
        return w
    }
    func fixture(seed: UInt64, scenario: String) throws -> [OptimizationReview] {
        var random = Random(state: seed), result: [OptimizationReview] = []
        var states: [Int: SchedulerSnapshot] = [:]
        for day in 0..<40 {
            let w = scenario == "standard" || (scenario == "drift" && day >= 32)
                ? FSRSOptimization.defaults : personalized()
            let scheduler = try ReviewScheduler(parameters: w)
            for card in 0..<30 {
                let date = base.addingTimeInterval(Double(day * day * 172800 + card * 90 + (day % 3) * 7200))
                let before = try states[card] ?? scheduler.newCard(now: date)
                let p = day == 0 ? 1 : try scheduler.retrievability(before, now: date)
                let recalled = random.unit() < p, rating = random.unit()
                let grade: ReviewGrade = recalled ? (rating < 0.6 ? .hard : rating > 0.95 ? .easy : .good) : .again
                result.append(OptimizationReview(id: uuid(result.count + 1000), cardID: uuid(card + 1),
                                                date: date, grade: grade.rawValue, sequence: result.count,
                                                startsNew: day == 0))
                states[card] = try scheduler.review(before, grade: grade, now: date).after
                if day == 0 {
                    let shortDate = date.addingTimeInterval(600)
                    result.append(OptimizationReview(id: uuid(result.count + 1000), cardID: uuid(card + 1),
                                                    date: shortDate, grade: 3, sequence: result.count, startsNew: false))
                    states[card] = try scheduler.review(states[card]!, grade: .good, now: shortDate).after
                }
            }
        }
        return result
    }
    func predictions(_ input: FSRSOptimization.Prepared, _ w: [Double], validation: Bool) throws -> (OptimizationMetrics, [Prediction]) {
        var values: [Prediction] = []
        let metrics = try FSRSOptimization.evaluate(input, parameters: w, validation: validation) {
            values.append(Prediction(event: $0, probability: $1))
        }
        return (metrics, values)
    }
    func interval(_ values: [Double]) -> (Double, Double) {
        let ordered = values.sorted()
        return (ordered[Int(Double(ordered.count) * 0.025)], ordered[Int(Double(ordered.count) * 0.975)])
    }
    func pairedCI(_ a: [Prediction], _ b: [Prediction]) -> (Double, Double) {
        let differences = Dictionary(grouping: Array(zip(a, b)), by: { $0.0.event.cardID })
            .sorted { $0.key.uuidString < $1.key.uuidString }.map { $0.value.map { $0.0.loss - $0.1.loss } }
        var random = Random(state: 189), samples: [Double] = []
        for _ in 0..<1000 {
            var sum = 0.0, count = 0
            for _ in differences.indices {
                let group = differences[Int(random.unit() * Double(differences.count))]
                sum += group.reduce(0, +); count += group.count
            }
            samples.append(sum / Double(count))
        }
        return interval(samples)
    }
    func testSyntheticAccuracyCalibrationAndUncertainty() throws {
        for scenario in ["standard", "personal", "drift"] {
            for seed: UInt64 in [189, 190, 191] {
                let data = try fixture(seed: seed, scenario: scenario), input = try FSRSOptimization.prepare(data)
                var previous = FSRSOptimization.defaults
                previous[2] *= 0.8; previous[8] *= 0.9
                let report = try FSRSOptimization.run(data, previous: previous, now: base.addingTimeInterval(90 * 86400))
                XCTAssertTrue(report.valid)
                var all: [[Prediction]] = []
                for (name, w, reported) in [("standard", FSRSOptimization.defaults, report.standard),
                                          ("previous", previous, report.previous!), ("candidate", report.parameters, report.candidate)] {
                    let (train, _) = try predictions(input, w, validation: false)
                    let (test, values) = try predictions(input, w, validation: true)
                    XCTAssertEqual(test, reported)
                    if let first = all.first { XCTAssertEqual(values.map(\.event.id), first.map(\.event.id)) }
                    all.append(values)
                    let recall = values.map(\.outcome).reduce(0, +) / Double(values.count)
                    let mean = values.map(\.probability).reduce(0, +) / Double(values.count)
                    var ece = 0.0
                    for bin in 0..<5 {
                        let subset = values.filter { min(4, Int($0.probability * 5)) == bin }
                        guard !subset.isEmpty else { continue }
                        let predicted = subset.map(\.probability).reduce(0, +) / Double(subset.count)
                        let actual = subset.map(\.outcome).reduce(0, +) / Double(subset.count)
                        ece += Double(subset.count) / Double(values.count) * abs(predicted - actual)
                        print("FSRS_CAL|\(scenario)|\(seed)|\(name)|\(bin)|\(subset.count)|\(predicted)|\(actual)")
                    }
                    print("FSRS_AUDIT|\(scenario)|\(seed)|\(name)|\(train.count)|\(test.count)|\(train.logLoss)|\(test.logLoss)|\(train.rmse)|\(test.rmse)|\(recall)|\(mean)|\(ece)")
                }
                let ci = pairedCI(all[2], all[0])
                let previousCI = pairedCI(all[2], all[1])
                print("FSRS_DELTA|\(scenario)|\(seed)|\(report.accepted)|\(ci.0)|\(ci.1)|\(previousCI.0)|\(previousCI.1)")
            }
        }
    }
    func testPredictionsAreBeforeAnswersAndFutureAnswersDoNotFit() throws {
        let data = try fixture(seed: 189, scenario: "standard"), input = try FSRSOptimization.prepare(data)
        var changed = data
        let firstValidation = try XCTUnwrap(input.events.first { input.eligible.contains($0.id) && $0.date > input.split })
        for i in changed.indices where changed[i].date > input.split {
            let old = changed[i]
            changed[i] = OptimizationReview(id: old.id, cardID: old.cardID, date: old.date,
                                           grade: old.grade == 1 ? 3 : 1, sequence: old.sequence, startsNew: old.startsNew)
        }
        let changedInput = try FSRSOptimization.prepare(changed)
        let (_, a) = try predictions(input, FSRSOptimization.defaults, validation: true)
        let (_, b) = try predictions(changedInput, FSRSOptimization.defaults, validation: true)
        XCTAssertEqual(a.first?.event.id, firstValidation.id)
        XCTAssertEqual(a.first?.probability, b.first?.probability)
        XCTAssertNotEqual(a.first?.outcome, b.first?.outcome)
        let original = try FSRSOptimization.run(data, now: base)
        let modified = try FSRSOptimization.run(changed, now: base)
        XCTAssertEqual(original.parameters, modified.parameters)
        XCTAssertEqual(try FSRSOptimization.evaluate(input, parameters: original.parameters, validation: false),
                       try FSRSOptimization.evaluate(changedInput, parameters: modified.parameters, validation: false))
    }
    func testExactThresholdsTiesShortTermAndDuplicateSequences() throws {
        // Exactly 400 eligible reviews, 30 UTC days and 20 cards; 320/80 split.
        var data: [OptimizationReview] = []
        for day in 0..<30 {
            let cards = day == 0 ? 20 : day <= 13 ? 20 : day == 14 ? 4 : day == 28 ? 12 : day <= 28 ? 8 : 20
            for card in 0..<cards {
                data.append(OptimizationReview(id: uuid(data.count + 1000), cardID: uuid(card + 1),
                    date: base.addingTimeInterval(Double(day * 86400)), grade: (day + card) % 5 == 0 ? 1 : 3,
                    sequence: data.count, startsNew: day == 0))
            }
        }
        let input = try FSRSOptimization.prepare(data)
        XCTAssertEqual(input.eligible.count, 400); XCTAssertEqual(input.days, 30)
        XCTAssertEqual(try FSRSOptimization.evaluate(input, parameters: FSRSOptimization.defaults, validation: false).count, 320)
        XCTAssertEqual(try FSRSOptimization.evaluate(input, parameters: FSRSOptimization.defaults, validation: true).count, 80)
        XCTAssertThrowsError(try FSRSOptimization.prepare(Array(data.dropLast())))
        var shortGap = data
        let index = shortGap.count - 20, shortEvent = shortGap[index]
        shortGap[index] = OptimizationReview(id: shortEvent.id, cardID: shortEvent.cardID,
            date: shortEvent.date.addingTimeInterval(-1), grade: shortEvent.grade, sequence: shortEvent.sequence, startsNew: false)
        XCTAssertThrowsError(try FSRSOptimization.prepare(shortGap)) // 399 eligible: 23:59:59 is short-term.

        // The full timestamp boundary is on one side. Input permutation cannot change replay.
        XCTAssertEqual(try FSRSOptimization.prepare(Array(data.reversed())).split, input.split)
        var duplicate = data
        let old = duplicate[1]
        duplicate[1] = OptimizationReview(id: old.id, cardID: old.cardID, date: old.date,
                                         grade: old.grade, sequence: duplicate[0].sequence, startsNew: old.startsNew)
        XCTAssertThrowsError(try FSRSOptimization.prepare(duplicate))
        for grade in [1, 3] {
            XCTAssertThrowsError(try FSRSOptimization.prepare(data.map {
                OptimizationReview(id: $0.id, cardID: $0.cardID, date: $0.date,
                                   grade: grade, sequence: $0.sequence, startsNew: $0.startsNew)
            }))
        }
        let mixed = try fixture(seed: 189, scenario: "standard")
        XCTAssertEqual(try FSRSOptimization.prepare(mixed).eligible.count, 1170)
        // Midnight crossing alone is not >=24h. UTC learning days ignore device zone/DST.
        let utc = try FSRSOptimization.prepare(mixed)
        let shifted = mixed.map {
            OptimizationReview(id: $0.id, cardID: $0.cardID, date: $0.date.addingTimeInterval(60),
                               grade: $0.grade, sequence: $0.sequence, startsNew: $0.startsNew)
        }
        let shiftedInput = try FSRSOptimization.prepare(shifted)
        XCTAssertEqual(utc.eligible, shiftedInput.eligible)
        XCTAssertEqual(utc.days, shiftedInput.days)
        XCTAssertEqual(try FSRSOptimization.evaluate(utc, parameters: FSRSOptimization.defaults, validation: true),
                       try FSRSOptimization.evaluate(shiftedInput, parameters: FSRSOptimization.defaults, validation: true))
    }
    func testRemainingMinimumsLimitsAndRejectingEqualOrWorseCandidates() throws {
        func regular(cards: Int, days: Int) -> [OptimizationReview] {
            (0..<days).flatMap { day in
                (0..<cards).map { card in
                    OptimizationReview(id: uuid(day * cards + card + 10000), cardID: uuid(card + 1),
                        date: base.addingTimeInterval(Double(day * 86400)), grade: (day + card) % 5 == 0 ? 1 : 3,
                        sequence: day * cards + card, startsNew: day == 0)
                }
            }
        }
        XCTAssertThrowsError(try FSRSOptimization.prepare(regular(cards: 19, days: 40)))
        XCTAssertThrowsError(try FSRSOptimization.prepare(regular(cards: 20, days: 29)))
        let limit = regular(cards: 100, days: 100)
        XCTAssertEqual(try FSRSOptimization.prepare(limit).events.count, 10000)
        let extra = OptimizationReview(id: uuid(30000), cardID: uuid(1), date: base.addingTimeInterval(101 * 86400),
                                       grade: 3, sequence: 10000, startsNew: false)
        XCTAssertThrowsError(try FSRSOptimization.prepare(limit + [extra]))
        let metrics = OptimizationMetrics(count: 80, logLoss: 0.5, rmse: 0.4)
        let report = OptimizationReport(generatedAt: base, digest: String(repeating: "a", count: 64),
            reviews: 400, days: 30, splitDate: base, parameters: FSRSOptimization.defaults, previousParameters: nil,
            standard: metrics, candidate: metrics, previous: nil, duration: 1)
        XCTAssertFalse(report.accepted)
        let worse = OptimizationReport(generatedAt: base, digest: report.digest,
            reviews: 400, days: 30, splitDate: base, parameters: report.parameters, previousParameters: nil,
            standard: metrics, candidate: OptimizationMetrics(count: 80, logLoss: 0.6, rmse: 0.4), previous: nil, duration: 1)
        XCTAssertFalse(worse.accepted)
        let previousWins = OptimizationReport(generatedAt: base, digest: report.digest,
            reviews: 400, days: 30, splitDate: base, parameters: report.parameters, previousParameters: report.parameters,
            standard: metrics, candidate: OptimizationMetrics(count: 80, logLoss: 0.49, rmse: 0.39),
            previous: OptimizationMetrics(count: 80, logLoss: 0.48, rmse: 0.38), duration: 1)
        XCTAssertFalse(previousWins.accepted)
    }
    func testThreeThousandCardLoad() throws {
        var data: [OptimizationReview] = []
        for round in 0..<3 {
            for card in 0..<3000 {
                data.append(OptimizationReview(id: uuid(data.count + 10000), cardID: uuid(card + 1),
                    date: base.addingTimeInterval(Double(round * 130 * 86400 + card * 3600)),
                    grade: (card + round) % 5 == 0 ? 1 : 3, sequence: data.count, startsNew: round == 0))
            }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let beforePeak = usage.ru_maxrss, start = Date()
        let report = try FSRSOptimization.run(data, now: base)
        getrusage(RUSAGE_SELF, &usage)
        XCTAssertTrue(report.valid)
        print("FSRS_LOAD|3000|\(data.count)|\(Date().timeIntervalSince(start))|\(report.standard.count)|\(report.accepted)|\(beforePeak)|\(usage.ru_maxrss)")
    }
}
