import XCTest
@testable import AnkiIOS

final class ReviewQueueTests: XCTestCase {
    func testHomeRecommendationUnitsPolicyAndEstimate() {
        for count in [1, 20, 200] {
            for limit in [0, 10, 20] {
                let value = HomeRecommendation(mode: .review, cardCount: count, answerLimit: limit, medianAnswerSeconds: 24)
                XCTAssertEqual(value.poolText, "復習待ち：\(count)枚")
                XCTAssertEqual(value.estimatedAnswers, limit == 0 ? count : min(count, limit))
                XCTAssertEqual(value.policy, limit > 0 && count > limit ? .forgettingRisk : .traditional)
                XCTAssertEqual(value.reason.contains("忘れそう"), value.policy == .forgettingRisk)
                XCTAssertFalse(value.limitText.contains("枚"))
            }
        }
        XCTAssertEqual(HomeRecommendation(mode: .review, cardCount: 200, answerLimit: 0, medianAnswerSeconds: 24).timeText, "約80分")
        XCTAssertEqual(HomeRecommendation(mode: .review, cardCount: 200, answerLimit: 20, medianAnswerSeconds: 24).timeText, "約8分")
        for value in [nil, Double.nan, .infinity, 0, 301] as [Double?] {
            XCTAssertEqual(HomeRecommendation(mode: .review, cardCount: 20, answerLimit: 20, medianAnswerSeconds: value).timeText, "推定不可")
        }
        XCTAssertEqual(HomeRecommendation(mode: .new, cardCount: 200, answerLimit: 20, medianAnswerSeconds: nil).policy, .traditional)
        let base = HomeRecommendation(mode: .review, cardCount: 20, answerLimit: 20, medianAnswerSeconds: nil)
        XCTAssertNotEqual(base, HomeRecommendation(mode: .review, cardCount: 20, answerLimit: 20, medianAnswerSeconds: nil, scope: LearningScope(deckID: UUID())))
        XCTAssertNotEqual(base, HomeRecommendation(mode: .review, cardCount: 20, answerLimit: 20, medianAnswerSeconds: nil, responseMode: .typing))
        XCTAssertNil(AnswerTimeEstimate.median(milliseconds: [0, 1, 999, 300001, Int.max]))
        XCTAssertNil(AnswerTimeEstimate.median(milliseconds: [1000, 1000, 1000, 1000]))
        XCTAssertEqual(AnswerTimeEstimate.median(milliseconds: [1000, 2000, 24000, 30000, 300000, Int.max, 0]), 24)
    }

    func testCompactHomeProgressAndSharedConditions() {
        XCTAssertEqual(HomeStudyPresentation.dailyProgress(count: 25, goal: 20), "25枚・目標20枚 達成")
        XCTAssertEqual(HomeStudyPresentation.dailyProgress(count: 12, goal: 20), "12 / 20枚")
        XCTAssertEqual(HomeStudyPresentation.dailyProgress(count: 0, goal: nil), "0枚")
        XCTAssertEqual(HomeStudyPresentation.dailyProgress(count: 25, goal: 0), "25枚")
        for limit in [10, 20, 30, 0] {
            let summary = HomeStudyPresentation.sessionSummary(answerLimit: limit, responseMode: SessionResponseMode.allCases[0])
            XCTAssertTrue(summary.contains(limit == 0 ? "回答上限なし" : "最大\(limit)回答"))
            XCTAssertFalse(summary.contains("枚"))
        }
    }

    func testHomeLabelsSeparateAnswerLimitFromCardPoolForEveryMode() {
        for mode in StudyMode.allCases {
            for limit in [10, 20, 30, 0] {
                let expected = mode.title + (limit == 0 ? "・上限なし" : "・最大\(limit)回答")
                for count in [0, 3, 80] {
                    let action = HomePrimaryAction.start(mode, count)
                    XCTAssertEqual(action.buttonTitle(answerLimit: limit), expected)
                    XCTAssertFalse(action.buttonTitle(answerLimit: limit).contains("枚"))
                    XCTAssertTrue(action.accessibilityLabel(answerLimit: limit).contains(expected))
                    XCTAssertTrue(action.accessibilityLabel(answerLimit: limit).contains("\(count)枚"))
                }
                XCTAssertFalse(HomeStudyPresentation.explanation(answerLimit: limit).contains("すべて"))
            }
        }
        for action in [HomePrimaryAction.resume(.new), .waiting(Date()), .complete, .addCards, .unavailable] {
            for limit in [10, 20, 30, 0] {
                XCTAssertEqual(action.buttonTitle(answerLimit: limit), action.title)
                XCTAssertEqual(action.accessibilityLabel(answerLimit: limit), action.title)
            }
        }
    }
    func testHiddenImagesNeverHideImageOcclusionAndDefaultsStayCompatible() {
        let defaults = ReviewAppearance()
        XCTAssertFalse(defaults.gesturesEnabled); XCTAssertTrue(defaults.animationsEnabled)
        XCTAssertEqual(defaults.textSize, .standard); XCTAssertFalse(defaults.answerFirst)
        XCTAssertTrue(defaults.showsImage(for: .basic))
        var hidden = defaults; hidden.imageDisplay = .hidden
        XCTAssertFalse(hidden.showsImage(for: .basic))
        XCTAssertTrue(hidden.showsImage(for: .imageOcclusion))
    }
    func testSwipeDirectionsThresholdDiagonalAndRetreat() {
        XCTAssertEqual(ReviewSwipeAction.decide(x: 96, y: 0, revealed: false), .reveal)
        XCTAssertNil(ReviewSwipeAction.decide(x: 95, y: 0, revealed: false))
        XCTAssertNil(ReviewSwipeAction.decide(x: -120, y: 0, revealed: false))
        XCTAssertNil(ReviewSwipeAction.decide(x: 0, y: -120, revealed: false))
        XCTAssertNil(ReviewSwipeAction.decide(x: 120, y: 100, revealed: true))
        XCTAssertEqual(ReviewSwipeAction.decide(x: 120, y: 80, revealed: true), .grade(.good))
        XCTAssertEqual(ReviewSwipeAction.decide(x: -120, y: 0, revealed: true), .grade(.again))
        XCTAssertEqual(ReviewSwipeAction.decide(x: 0, y: 120, revealed: true), .grade(.hard))
        XCTAssertEqual(ReviewSwipeAction.decide(x: 0, y: -120, revealed: true), .grade(.easy))
        XCTAssertNil(ReviewSwipeAction.decide(x: 20, y: 0, revealed: true)) // Returned near the start.
        XCTAssertNil(ReviewSwipeAction.decide(x: .infinity, y: 0, revealed: true))
    }
    func testSwipeGateRejectsChangedCardChangedRevealAndQuickRepeat() {
        var gate = ReviewSwipeGate()
        let id = UUID(), now = Date(timeIntervalSince1970: 100)
        gate.begin(id: id, revealed: false)
        XCTAssertNil(gate.finish(id: UUID(), revealed: false, x: 120, y: 0, now: now))
        gate.begin(id: id, revealed: false)
        XCTAssertNil(gate.finish(id: id, revealed: true, x: 120, y: 0, now: now))
        gate.begin(id: id, revealed: false); gate.invalidate()
        gate.begin(id: id, revealed: true)
        XCTAssertNil(gate.finish(id: id, revealed: true, x: 120, y: 0, now: now))
        gate.begin(id: id, revealed: false); gate.cancel()
        XCTAssertNil(gate.finish(id: id, revealed: false, x: 120, y: 0, now: now))
        gate.begin(id: id, revealed: false)
        XCTAssertEqual(gate.finish(id: id, revealed: false, x: 120, y: 0, now: now), .reveal)
        gate.begin(id: id, revealed: true)
        XCTAssertNil(gate.finish(id: id, revealed: true, x: 120, y: 0, now: now.addingTimeInterval(0.1)))
        gate.begin(id: id, revealed: true)
        XCTAssertEqual(gate.finish(id: id, revealed: true, x: 120, y: 0, now: now.addingTimeInterval(1)), .grade(.good))
        XCTAssertNil(gate.finish(id: id, revealed: true, x: 120, y: 0, now: now.addingTimeInterval(2)))
    }
    func testSwipeProgressTracksCandidatesReadinessAndHysteresis() {
        var gate = ReviewSwipeGate()
        let id = UUID(), now = Date(timeIntervalSince1970: 100)
        gate.begin(id: id, revealed: true)
        func update(_ x: Double, _ y: Double, _ seconds: Double = 0) -> ReviewSwipeProgress {
            gate.update(id: id, revealed: true, x: x, y: y, now: now.addingTimeInterval(seconds))
        }
        let moving = update(48, 0)
        XCTAssertEqual(moving.candidate, .grade(.good)); XCTAssertEqual(moving.fraction, 0.5)
        XCTAssertFalse(moving.ready); XCTAssertFalse(moving.feedback)
        XCTAssertTrue(update(96, 64).feedback)
        XCTAssertFalse(update(95, 0, 0.1).ready)
        XCTAssertFalse(update(97, 0, 0.2).feedback)
        XCTAssertNil(update(100, 100, 0.3).candidate)
        XCTAssertEqual(update(0, -120, 0.4).candidate, .grade(.easy))
        XCTAssertFalse(update(0, -120, 0.4).feedback) // Direction changes do not repeatedly vibrate.
        XCTAssertFalse(update(70, 0, 0.5).ready)
        XCTAssertTrue(update(-100, 0, 0.6).feedback)
        XCTAssertNil(gate.finish(id: id, revealed: true, x: 20, y: 0, now: now.addingTimeInterval(1)))
        XCTAssertFalse(gate.gavePreparationFeedback)
    }

    func testSwipeProgressUsesGateAcceptanceAndNeverCommitsDuringDrag() {
        var gate = ReviewSwipeGate()
        let id = UUID(), now = Date(timeIntervalSince1970: 100)
        gate.begin(id: id, revealed: false)
        XCTAssertEqual(gate.update(id: id, revealed: false, x: -120, y: 0, now: now), .idle)
        XCTAssertEqual(gate.update(id: id, revealed: false, x: 0, y: -120, now: now), .idle)
        XCTAssertTrue(gate.update(id: id, revealed: false, x: 120, y: 0, now: now).ready)
        XCTAssertEqual(gate.update(id: UUID(), revealed: false, x: 120, y: 0, now: now), .idle)
        XCTAssertEqual(gate.update(id: id, revealed: true, x: 120, y: 0, now: now), .idle)
        XCTAssertEqual(gate.update(id: id, revealed: false, x: 120, y: 0, now: now, enabled: false), .idle)
        XCTAssertEqual(gate.update(id: id, revealed: false, x: .infinity, y: 0, now: now), .idle)
        XCTAssertEqual(gate.finish(id: id, revealed: false, x: 120, y: 0, now: now), .reveal)
        gate.begin(id: id, revealed: true)
        XCTAssertEqual(gate.update(id: id, revealed: true, x: 120, y: 0, now: now.addingTimeInterval(0.1)), .idle)
        XCTAssertTrue(gate.update(id: id, revealed: true, x: 120, y: 0, now: now.addingTimeInterval(0.61)).ready)
        gate.invalidate()
        XCTAssertEqual(gate.update(id: id, revealed: true, x: 120, y: 0, now: now.addingTimeInterval(1)), .idle)
        XCTAssertNil(gate.finish(id: id, revealed: true, x: 120, y: 0, now: now.addingTimeInterval(1)))
        gate.begin(id: id, revealed: true); gate.cancel()
        XCTAssertEqual(gate.update(id: id, revealed: true, x: 120, y: 0, now: now.addingTimeInterval(2)), .idle)
    }

    func calendar(_ zone: String = "Asia/Tokyo") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func card(_ state: String, due: Date, suspended: Bool = false) -> QueueCard {
        QueueCard(id: UUID(), state: state, due: due, createdAt: due, suspended: suspended)
    }

    func testTiedNewOrderBoundedPrefixAndSharedAncestorCaps() {
        let now = date("2026-10-08T12:00:00+09:00")
        let parent = UUID(), child = UUID()
        let ids = (1...6).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
        let cards = ids.enumerated().reversed().map { index, id in
            QueueCard(id: id, state: "new", due: now, createdAt: now, suspended: false,
                      deckLimits: index < 3 ? [parent: 4, child: 2] : [parent: 4])
        }
        let logs = [QueueLog(cardID: UUID(), reviewedAt: now, wasNew: true, quotaDeckIDs: [parent, child])]
        var settings = StudySettings()
        settings.dailyNewLimit = 3 // Two global slots; one remaining child slot.
        let builder = ReviewQueueBuilder(calendar: calendar(), shuffled: { $0 })
        XCTAssertEqual(builder.counts(cards: cards, logs: logs, settings: settings, now: now).newRemaining, 2)
        for mode in [StudyMode.new, .mixed] {
            XCTAssertEqual(builder.queue(cards: cards, logs: logs, settings: settings, mode: mode,
                                         touched: [], reviewStreak: 0, now: now), [ids[0], ids[3]])
        }
        XCTAssertEqual(builder.queue(cards: cards, logs: logs, settings: settings, mode: .review,
                                     touched: [], reviewStreak: 0, now: now), [])
        settings.dailyNewLimit = 1
        XCTAssertEqual(builder.queue(cards: cards, logs: logs, settings: settings, mode: .new,
                                     touched: [], reviewStreak: 0, now: now), [])
    }

    func testDeckSharedCapsFourAMAndAllStudyModes() {
        let before = date("2026-10-08T03:59:59+09:00"), after = date("2026-10-08T04:00:00+09:00")
        let parent = UUID(), child = UUID()
        var first = card("new", due: before), second = card("new", due: before)
        first.deckLimits = [parent: 2, child: 1]; second.deckLimits = [parent: 2, child: 1]
        let review = card("review", due: before)
        let short = card("learning", due: before)
        let cards = [first, second, review, short]
        let logs = [QueueLog(cardID: UUID(), reviewedAt: before, wasNew: true, quotaDeckIDs: [parent, child])]
        let builder = ReviewQueueBuilder(calendar: calendar())
        let settings = StudySettings()
        XCTAssertEqual(builder.counts(cards: cards, logs: logs, settings: settings, now: before).newRemaining, 0)
        XCTAssertEqual(builder.counts(cards: cards, logs: logs, settings: settings, now: before).eligibleNew, 2)
        XCTAssertEqual(builder.counts(cards: cards, logs: logs, settings: settings, now: after).newRemaining, 1)
        for mode in StudyMode.allCases {
            let ids = builder.queue(cards: cards, logs: logs, settings: settings, mode: mode, touched: [short.id], reviewStreak: 0, now: before)
            XCTAssertFalse(ids.contains(first.id)); XCTAssertFalse(ids.contains(second.id))
            XCTAssertTrue(ids.contains(short.id))
            XCTAssertEqual(ids.contains(review.id), mode != .new)
        }
    }

    func testFourAMBoundaryAndUniqueGoalCount() {
        let before = date("2026-10-08T03:59:59+09:00"), after = date("2026-10-08T04:00:00+09:00")
        let fresh = card("new", due: before)
        let logs = [QueueLog(cardID: fresh.id, reviewedAt: before, wasNew: true),
                    QueueLog(cardID: fresh.id, reviewedAt: before, wasNew: false)]
        let builder = ReviewQueueBuilder(calendar: calendar(), shuffled: { $0 })
        var settings = StudySettings(); settings.dailyNewLimit = 1
        let previous = builder.counts(cards: [fresh], logs: logs, settings: settings, now: before)
        XCTAssertEqual(previous.newRemaining, 0)
        XCTAssertEqual(previous.learnedToday, 1)
        XCTAssertEqual(previous.answerCount, 2)
        let next = builder.counts(cards: [fresh], logs: logs, settings: settings, now: after)
        XCTAssertEqual(next.newRemaining, 1)
        XCTAssertEqual(next.learnedToday, 0)
    }

    func testSharedNewLimitAcrossAllModesAndSuspension() {
        let now = date("2026-10-08T12:00:00+09:00")
        let reviewed = card("review", due: now), fresh = card("new", due: now)
        let suspended = card("new", due: now, suspended: true)
        let logs = [QueueLog(cardID: reviewed.id, reviewedAt: now, wasNew: true)]
        var settings = StudySettings(); settings.dailyNewLimit = 1
        let builder = ReviewQueueBuilder(calendar: calendar(), shuffled: { $0 })
        for mode in StudyMode.allCases {
            let queue = builder.queue(cards: [reviewed, fresh, suspended], logs: logs, settings: settings,
                                      mode: mode, touched: [], reviewStreak: 0, now: now)
            XCTAssertFalse(queue.contains(fresh.id))
            XCTAssertFalse(queue.contains(suspended.id))
        }
        XCTAssertEqual(builder.queue(cards: [reviewed], logs: logs, settings: settings,
                                     mode: .review, touched: [], reviewStreak: 0, now: now), [reviewed.id])
    }

    func testOverdueAndShortStepsAcrossDays() {
        let now = date("2026-10-08T12:00:00+09:00")
        let overdue = card("review", due: now.addingTimeInterval(-86400 * 3))
        let short = card("learning", due: now)
        let future = card("relearning", due: now.addingTimeInterval(600))
        let builder = ReviewQueueBuilder(shuffled: { $0 })
        let cards = [overdue, short, future]
        XCTAssertEqual(builder.queue(cards: cards, logs: [], settings: StudySettings(), mode: .review,
                                     touched: [], reviewStreak: 0, now: now), [short.id, overdue.id])
        XCTAssertEqual(builder.queue(cards: cards, logs: [], settings: StudySettings(), mode: .new,
                                     touched: [short.id], reviewStreak: 0, now: now), [short.id])
        XCTAssertTrue(builder.queue(cards: cards, logs: [], settings: StudySettings(), mode: .review,
                                    touched: [], reviewStreak: 0, now: now.addingTimeInterval(86400)).contains(overdue.id))
    }

    func testMixedRatioAndGoalDoesNotLimitReviews() {
        let now = date("2026-10-08T12:00:00+09:00")
        let reviews = (0..<6).map { i in card("review", due: now.addingTimeInterval(Double(i - 10))) }
        let fresh = (0..<2).map { i in card("new", due: now.addingTimeInterval(Double(i))) }
        var settings = StudySettings(); settings.dailyGoal = 1
        let logs = [QueueLog(cardID: UUID(), reviewedAt: now, wasNew: false)]
        let builder = ReviewQueueBuilder(shuffled: { $0 })
        let queue = builder.queue(cards: reviews + fresh, logs: logs, settings: settings,
                                  mode: .mixed, touched: [], reviewStreak: 0, now: now)
        XCTAssertEqual(queue, reviews.prefix(3).map(\.id) + [fresh[0].id] + reviews.suffix(3).map(\.id) + [fresh[1].id])
        XCTAssertEqual(builder.queue(cards: reviews + fresh, logs: logs, settings: settings,
                                     mode: .mixed, touched: [], reviewStreak: 3, now: now).first, fresh[0].id)
    }

    func testTimeZoneAndDSTCalendarDays() {
        let la = StudyDay(calendar: calendar("America/Los_Angeles"))
        let window = la.interval(containing: date("2026-03-07T12:00:00-08:00"))
        XCTAssertEqual(window.end.timeIntervalSince(window.start), 23 * 3600)
        let tokyo = StudyDay(calendar: calendar())
        XCTAssertNotEqual(tokyo.interval(containing: window.start).start, window.start)
    }
}

extension ReviewQueueTests {
    func testManualHoldBoundaryCountsNotificationsAndWidgetAgree() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let settings = StudySettings()
        let end = StudyDay(calendar: calendar, startHour: settings.dayStartHour).interval(containing: now).end
        let card = QueueCard(id: UUID(), state: "review", due: now, createdAt: now, suspended: false, hiddenUntil: end)
        let builder = ReviewQueueBuilder(calendar: calendar)
        XCTAssertTrue(builder.queue(cards: [card], logs: [], settings: settings, mode: .review, touched: [], reviewStreak: 0, now: now).isEmpty)
        XCTAssertEqual(builder.counts(cards: [card], logs: [], settings: settings, now: now).due, 0)
        XCTAssertEqual(builder.queue(cards: [card], logs: [], settings: settings, mode: .review, touched: [], reviewStreak: 0, now: end), [card.id])
        let widget = try WidgetProjection.make(cards: [card], logs: [], settings: WidgetProjectionSettings(settings), now: now, calendar: calendar)
        XCTAssertEqual(widget.points.first?.due, 0)
        XCTAssertEqual(widget.points.first { $0.date == end }?.due, 1)
        var notifications = NotificationOptions(); notifications.enabled = true
        let planned = NotificationPlanner(calendar: calendar).plan(cards: [card], options: notifications, authorized: true, delivered: [], now: now)
        XCTAssertFalse(planned.isEmpty)
        XCTAssertTrue(planned.allSatisfy { $0.date >= end })
    }
}

extension ReviewQueueTests {
    func testForgettingRiskEligibilityFallbackAndFrozenOrder() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let older = card("review", due: now.addingTimeInterval(-100))
        let risky = card("review", due: now.addingTimeInterval(-10))
        let invalid = card("review", due: now.addingTimeInterval(-50))
        let short = card("relearning", due: now)
        let future = card("review", due: now.addingTimeInterval(1))
        var held = card("review", due: now); held.hiddenUntil = now.addingTimeInterval(10)
        var paused = card("review", due: now); paused.studyPaused = true
        var sibling = card("review", due: now); sibling.noteID = UUID()
        let suspended = card("review", due: now, suspended: true)
        let cards = [older, risky, invalid, short, future, held, paused, sibling, suspended]
        let logs = [QueueLog(cardID: UUID(), reviewedAt: now, wasNew: false, noteID: sibling.noteID)]
        let builder = ReviewQueueBuilder(shuffled: { $0 })
        var calculated: [UUID] = []
        func queue(_ policy: ReviewOrderPolicy, order: [UUID]? = nil, failure: Double? = .nan) -> [UUID] {
            builder.queue(cards: cards, logs: logs, settings: StudySettings(), mode: .review,
                          touched: [], reviewStreak: 0, now: now, policy: policy, reviewOrder: order) { id in
                calculated.append(id)
                return id == older.id ? 0.9 : id == risky.id ? 0.1 : failure
            }
        }
        XCTAssertEqual(queue(.traditional), [short.id, older.id, invalid.id, risky.id])
        XCTAssertTrue(calculated.isEmpty)
        let ranked = queue(.forgettingRisk)
        XCTAssertEqual(ranked, [short.id, risky.id, invalid.id, older.id])
        XCTAssertEqual(Set(calculated), Set([older.id, invalid.id, risky.id]))
        for failure in [nil, .nan, .infinity, -0.1, 1.1] as [Double?] {
            XCTAssertEqual(queue(.forgettingRisk, failure: failure), ranked)
        }
        calculated = []
        XCTAssertEqual(queue(.forgettingRisk, order: ranked), ranked)
        XCTAssertTrue(calculated.isEmpty)
    }

    func testForgettingRiskTiesMixedNewAndEmpty() {
        let now = Date()
        let reviews = (1...6).map { index in
            QueueCard(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                      state: "review", due: now, createdAt: now, suspended: false)
        }
        let fresh = card("new", due: now)
        let builder = ReviewQueueBuilder(shuffled: { $0.reversed() })
        func queue(_ cards: [QueueCard], _ mode: StudyMode) -> [UUID] {
            builder.queue(cards: cards, logs: [], settings: StudySettings(), mode: mode,
                          touched: [], reviewStreak: 0, now: now, policy: .forgettingRisk, retrievability: { _ in 0.5 })
        }
        XCTAssertEqual(queue(reviews.reversed() + [fresh], .mixed), reviews.prefix(3).map(\.id) + [fresh.id] + reviews.suffix(3).map(\.id))
        XCTAssertEqual(queue(reviews + [fresh], .new), [fresh.id])
        XCTAssertEqual(queue([], .review), [])
        XCTAssertEqual(queue([reviews[0]], .review), [reviews[0].id])
        XCTAssertEqual(queue(reviews, .review), reviews.map(\.id))
    }
}
