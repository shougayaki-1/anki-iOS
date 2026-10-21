import XCTest
@testable import AnkiIOS

final class StatisticsTests: XCTestCase {
    func testAchievementHistoryGroupsStoredDaysAndPreservesEveryEvent() {
        let date = insightNow
        func record(_ id: String, _ kind: AchievementKind, _ value: Int, day: String = "2026-10-13", threshold: Int = 0) -> AchievementRecord {
            AchievementRecord(id: id, kind: kind, studyDay: day, threshold: threshold, value: value,
                occurredAt: date, sourceLogID: UUID(), timeZoneID: "Asia/Tokyo", startHour: 4)
        }
        // Equal timestamps on different stored days must never be regrouped by occurredAt.
        let records = [record("first", .firstStudyToday, 1), record("normal", .streakAdvanced, 10),
            record("goal", .dailyGoalReached, 20, threshold: 20), record("seven", .streakAdvanced, 7),
            record("mature", .matureMilestone, 50, threshold: 50),
            record("older", .streakAdvanced, 7, day: "2026-10-12"),
            record("unknown", .matureMilestone, 25, day: "2026-10-11", threshold: 25)]
        let result = AchievementHistoryProjection(records: records)
        XCTAssertEqual(result.days.map(\.id), ["2026-10-13", "2026-10-12", "2026-10-11"])
        XCTAssertEqual(result.days[0].records.map(\.id), ["seven", "mature", "goal", "normal", "first"])
        XCTAssertEqual(Set(result.days.flatMap(\.records).map(\.id)), Set(records.map(\.id)))
        XCTAssertEqual(result.badges.map(\.id), ["seven", "mature"])
        XCTAssertFalse(AchievementHistoryProjection.isMilestone(records[1]))
        XCTAssertFalse(AchievementHistoryProjection.isMilestone(records[6]))
        XCTAssertEqual(AchievementHistoryProjection(records: [records[0]]).days[0].primary.id, "first")
        XCTAssertTrue(AchievementHistoryProjection(records: []).days.isEmpty)
        XCTAssertTrue(AchievementHistoryProjection(records: []).badges.isEmpty)
        XCTAssertEqual(AchievementHistoryProjection(records: records.reversed()).days[0].records, result.days[0].records)
    }

    func testAchievementHistoryManyDaysAndFourAMBoundary() {
        let calendar = insightCalendar
        let boundary = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 4))!
        let dates = [boundary.addingTimeInterval(-1), boundary]
        let records = (0..<500).map { index in
            let date = index < 2 ? dates[index] : calendar.date(byAdding: .day, value: -index, to: boundary)!
            return AchievementRecord(id: "event-\(index)", kind: .firstStudyToday,
                studyDay: AchievementProgress.dayKey(date, calendar: calendar, startHour: 4), threshold: 1,
                value: 1, occurredAt: date, sourceLogID: UUID(), timeZoneID: "Asia/Tokyo", startHour: 4)
        }
        let result = AchievementHistoryProjection(records: records)
        XCTAssertEqual(result.days.count, 500)
        XCTAssertEqual(result.days[0].id, "2026-10-14")
        XCTAssertEqual(result.days[1].id, "2026-10-13")
        XCTAssertEqual(result.days.flatMap(\.records).count, records.count)
        XCTAssertTrue(result.badges.isEmpty)
    }

    func testGardenClassificationBoundaryAndBoundedDensity() {
        let states: [(String, Double, GardenStage)] = [("new", 99, .seed), ("learning", 99, .sprout), ("relearning", 99, .sprout), ("review", 20.999, .plant), ("review", 21, .flower), ("review", 100, .flower)]
        let cards = states.map { MemoryCard(state: $0.0, id: UUID(), title: "Q", stability: $0.1, difficulty: 5, retrievability: 0.9) }
        XCTAssertEqual(cards.map { GardenStage.classify(state: $0.state, stability: $0.stability) }, states.map { $0.2 })
        let groups = MemoryGrowthGroup.garden(cards: cards)
        XCTAssertEqual(groups.map { $0.cards.count }, [1, 2, 1, 2])
        XCTAssertEqual(Set(groups.flatMap { $0.cards.map(\.id) }), Set(cards.map(\.id)))
        XCTAssertEqual(MemoryGrowthGroup.garden(cards: []).map { $0.cards.count }, [0, 0, 0, 0])
        XCTAssertTrue(MemoryGardenScene.specimens(counts: [0, 0, 0, 0]).isEmpty)
        XCTAssertEqual(MemoryGardenScene.specimens(counts: [1, 0, 0, 0]), [.seed])
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 {
            let plants = MemoryGardenScene.specimens(counts: [600, 600, 900, 900])
            XCTAssertEqual(plants.count, 40)
            XCTAssertEqual(GardenStage.allCases.map { stage in plants.filter { $0 == stage }.count }, [8, 8, 12, 12])
        }
        print("GARDEN_LAYOUT 3000 cards, 1000 layouts ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000), specimens=40")
    }

    private var insightCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }
    private var insightNow: Date {
        insightCalendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
    }
    private func insightStats(_ logs: [StatisticLog] = []) -> StudyStatistics {
        StudyStatistics.calculate(logs: logs, retrievabilities: [], now: insightNow, calendar: insightCalendar, startHour: 4)
    }
    private func insights(_ stats: StudyStatistics, days: Int = 7) -> [StudyInsight] {
        StudyInsight.generate(stats: stats, days: days, now: insightNow, calendar: insightCalendar, startHour: 4)
    }
    func testInsightsRequireEvidenceAndReserveUsefulAndGrowthSlots() {
        XCTAssertTrue(insights(insightStats()).isEmpty)
        var stats = insightStats()
        let today = StudyDay(calendar: insightCalendar, startHour: 4).interval(containing: insightNow).start
        stats.scheduledDays = (0..<7).map { offset in
            let start = insightCalendar.date(byAdding: .day, value: offset, to: today)!
            return ForecastDay(start: start, end: insightCalendar.date(byAdding: .day, value: 1, to: start)!, scheduled: offset == 2 || offset == 4 ? 42 : 0)
        }
        XCTAssertEqual(insights(stats).map(\.rule), [.forecastPeak])
        if case .forecast(_, let peak) = insights(stats)[0].evidence { XCTAssertEqual(peak, stats.scheduledDays[2].start) } else { XCTFail() }
        stats.comparisons[7] = StudyVolumeComparison(days: 7, previousStart: today.addingTimeInterval(-14 * 86400), recentStart: today.addingTimeInterval(-7 * 86400), end: today, previous: 0, recent: 5)
        let memory = MemoryAnalysis.calculate(cards: [], logs: [], targets: [0.9], now: insightNow, calendar: insightCalendar, startHour: 4)
        stats.memory = MemoryAnalysis(generatedAt: insightNow, distributions: memory.distributions,
            retention: [ObservedRetention(days: 7, start: today, end: insightNow, successes: 18, trials: 20, cardIDs: [])], targets: [0.9])
        stats.achievements = AchievementStatistics(progress: AchievementProgress(currentStreak: 7, longestStreak: 7, studiedToday: true, uniqueCardsToday: 5), history: [])
        XCTAssertEqual(insights(stats).map(\.rule), [.forecastPeak, .streak])
        XCTAssertEqual(StudyInsight.select(insights(stats) + insights(stats)).count, 2)
        stats.achievements = nil
        XCTAssertEqual(insights(stats).map(\.rule), [.forecastPeak, .volume])
        XCTAssertFalse(insights(stats)[1].title.contains("%"))
        XCTAssertEqual(insights(stats, days: 30).map(\.rule), [.forecastPeak])
        stats.scheduledDays = []
        XCTAssertEqual(insights(stats).map(\.rule), [.volume, .retention])
        stats.comparisons = [:]
        XCTAssertEqual(insights(stats).map(\.rule), [.retention])
        stats.memory = MemoryAnalysis(generatedAt: insightNow, distributions: memory.distributions,
            retention: [ObservedRetention(days: 7, start: today, end: insightNow, successes: 18, trials: 19, cardIDs: [])], targets: [0.9])
        XCTAssertTrue(insights(stats).isEmpty)
        stats.memory = MemoryAnalysis(generatedAt: insightNow, distributions: memory.distributions,
            retention: [ObservedRetention(days: 7, start: today, end: insightNow, successes: 18, trials: 20, cardIDs: [])], targets: [0.85, 0.9])
        XCTAssertTrue(insights(stats).isEmpty)
    }
    func testInsightVolumeDeduplicatesAndReevaluatesScopeDeletionAndBoundary() {
        let calendar = insightCalendar, now = insightNow, deck = UUID(), tag = UUID(), card = UUID()
        let today = StudyDay(calendar: calendar, startHour: 4).interval(containing: now).start
        func log(_ offset: Int, id: UUID = UUID()) -> StatisticLog {
            StatisticLog(cardID: id, date: calendar.date(byAdding: .day, value: offset, to: today)!, grade: .good, durationMs: 0, deckID: deck, tagIDs: [tag])
        }
        let logs = [log(-14), log(-1, id: card), log(-2, id: card), log(-7), log(0), log(1)]
        let stats = insightStats(logs)
        XCTAssertEqual(stats.comparisons[7]?.previous, 1)
        XCTAssertEqual(stats.comparisons[7]?.recent, 2)
        XCTAssertEqual(insights(stats).map(\.rule), [.volume])
        XCTAssertTrue(insights(insightStats(Array(logs.dropFirst()))).isEmpty)
        XCTAssertTrue(insights(insightStats([logs[0], logs[1]])).isEmpty)
        for (decks, tags) in [(Set([UUID()]), Set<UUID>()), (Set([deck]), Set([UUID()]))] {
            let scoped = StudyStatistics.calculate(logs: logs, retrievabilities: [], now: now, calendar: calendar, startHour: 4, selectedDeckIDs: decks, selectedTagIDs: tags)
            XCTAssertTrue(insights(scoped).isEmpty)
        }
        let before = StudyStatistics.calculate(logs: logs, retrievabilities: [], now: today.addingTimeInterval(-1), calendar: calendar, startHour: 4)
        XCTAssertNil(before.comparisons[7]) // The earlier prior window is not covered.
        var other = calendar; other.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let changed = StudyStatistics.calculate(logs: logs, retrievabilities: [], now: now, calendar: other, startHour: 4)
        XCTAssertNotEqual(changed.dashboardPeriods[7]?.date, stats.dashboardPeriods[7]?.date)
        XCTAssertEqual(stats.updatingCurrentCards([], now: now, selectedDeckIDs: nil, selectedTagIDs: []).comparisons[7]?.recent, 2)
    }
    func testStreakInsightAppearsOnlyOnStudiedMilestoneDay() throws {
        let calendar = insightCalendar, now = insightNow
        let logs = (0..<7).map { StatisticLog(cardID: UUID(), date: calendar.date(byAdding: .day, value: -$0, to: now)!, grade: .good, durationMs: 0) }
        var stats = insightStats()
        stats.achievements = try AchievementStatistics.calculate(logs: logs, records: [], matureCount: 0, now: now, calendar: calendar, startHour: 4)
        XCTAssertEqual(insights(stats).map(\.rule), [.streak])
        stats.achievements = try AchievementStatistics.calculate(logs: Array(logs.dropFirst()), records: [], matureCount: 0, now: now, calendar: calendar, startHour: 4)
        XCTAssertTrue(insights(stats).isEmpty)
        stats.achievements = try AchievementStatistics.calculate(logs: Array(logs.dropLast()), records: [], matureCount: 0, now: now, calendar: calendar, startHour: 4)
        XCTAssertTrue(insights(stats).isEmpty)
    }

    func testDashboardPeriodsDeduplicateAcrossDaysAndUseStudyBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 4))!
        let card = UUID(), deck = UUID(), tag = UUID()
        let logs = [
            StatisticLog(cardID: card, date: now, grade: .good, durationMs: 1000, deckID: deck, tagIDs: [tag]),
            StatisticLog(cardID: card, date: now.addingTimeInterval(-1), grade: .again, durationMs: 2000, deckID: deck, tagIDs: [tag]),
            StatisticLog(cardID: UUID(), date: now.addingTimeInterval(-8 * 86400), grade: .hard, durationMs: 3000, deckID: deck, tagIDs: [tag]),
            StatisticLog(cardID: UUID(), date: now.addingTimeInterval(1), grade: .easy, durationMs: 4000)
        ]
        let stats = StudyStatistics.calculate(logs: logs, retrievabilities: [], now: now, calendar: calendar, startHour: 4)
        XCTAssertEqual(stats.dashboardPeriods[7]?.cards, 1)
        XCTAssertEqual(stats.dashboardPeriods[7]?.answers, 2)
        XCTAssertEqual(stats.dashboardPeriods[30]?.cards, 2)
        XCTAssertEqual(stats.dashboardPeriods[0]?.durationMs, 6000)
        XCTAssertEqual(stats.calendarDays[now]?.answers, 1)
        XCTAssertEqual(stats.calendarDays.count, 3)
        let empty = StudyStatistics.calculate(logs: logs, retrievabilities: [], now: now, calendar: calendar, startHour: 4, selectedTagIDs: [UUID()])
        XCTAssertEqual(empty.dashboardPeriods[0]?.cards, 0)
        XCTAssertTrue(empty.calendarDays.isEmpty)
        let periods = (0..<7).map { offset -> ForecastDay in
            let start = calendar.date(byAdding: .day, value: offset, to: now)!
            return ForecastDay(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        }
        XCTAssertEqual(ReviewForecast.scheduledIndex(due: now.addingTimeInterval(-1), days: periods), 0)
        XCTAssertEqual(ReviewForecast.scheduledIndex(due: periods[0].end, days: periods), 1)
        XCTAssertNil(ReviewForecast.scheduledIndex(due: periods.last!.end, days: periods))
    }

    func testAchievementStatisticsUsesEventTimeAndKeepsShownReceipts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 4))!
        let firstID = UUID(), secondID = UUID(), card = UUID()
        let logs = [StatisticLog(reviewLogID: firstID, cardID: card, date: now, grade: .again, durationMs: 0),
            StatisticLog(reviewLogID: secondID, cardID: UUID(), date: now.addingTimeInterval(60), grade: .good, durationMs: 0)]
        func record(_ id: String, _ kind: AchievementKind, _ time: Date, threshold: Int = 1,
                    source: UUID = firstID, displayedAt: Date? = nil) -> AchievementRecord {
            AchievementRecord(id: id, kind: kind, studyDay: "2026-10-07", threshold: threshold, value: threshold,
                occurredAt: time, sourceLogID: source, timeZoneID: calendar.timeZone.identifier,
                startHour: 4, displayedAt: displayedAt)
        }
        let records = [record("first", .firstStudyToday, now),
            record("earlyGoal", .dailyGoalReached, now, threshold: 2),
            record("goal", .dailyGoalReached, now.addingTimeInterval(60), threshold: 2, source: secondID),
            record("wrongStreak", .streakAdvanced, now, threshold: 3),
            record("mature", .matureMilestone, now, threshold: 10),
            record("missing", .firstStudyToday, now, source: UUID()),
            record("shown", .streakAdvanced, now, threshold: 7, source: UUID(), displayedAt: now)]
        let report = try AchievementStatistics.calculate(logs: logs, records: records, matureCount: 9,
            now: now, calendar: calendar, startHour: 4)
        XCTAssertEqual(report.progress.uniqueCardsToday, 1)
        XCTAssertEqual(Set(report.history.map(\.id)), ["first", "goal", "shown"])
        let mature = try AchievementStatistics.calculate(logs: logs, records: records, matureCount: 10,
            now: now.addingTimeInterval(60), calendar: calendar, startHour: 4)
        XCTAssertEqual(mature.progress.uniqueCardsToday, 2)
        XCTAssertTrue(mature.history.contains { $0.id == "mature" })
        for offset in [-86400.0, 0.0, 60.0, 86400.0, 172800.0] {
            let date = now.addingTimeInterval(offset)
            let indexed = try AchievementStatistics.calculate(logs: logs, records: [], matureCount: 0,
                now: date, calendar: calendar, startHour: 4).progress
            let original = AchievementProgress.calculate(logs: logs.map { ($0.cardID, $0.date) },
                now: date, calendar: calendar, startHour: 4)
            XCTAssertEqual(indexed.currentStreak, original.currentStreak)
            XCTAssertEqual(indexed.longestStreak, original.longestStreak)
            XCTAssertEqual(indexed.studiedToday, original.studiedToday)
            XCTAssertEqual(indexed.uniqueCardsToday, original.uniqueCardsToday)
        }
    }

    func testAchievementStudyDaysBoundariesGapsMilestonesAndTimeZones() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func date(_ day: Int, _ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
        let id = UUID()
        let logs = (1...7).map { (cardID: id, date: date($0, 4)) }
        let before = AchievementProgress.calculate(logs: logs, now: date(7, 3), calendar: calendar, startHour: 4)
        XCTAssertEqual(before.currentStreak, 6)
        let seven = AchievementProgress.calculate(logs: logs, now: date(7, 4), calendar: calendar, startHour: 4)
        XCTAssertEqual(seven.currentStreak, 7); XCTAssertEqual(seven.longestStreak, 7)
        XCTAssertEqual(seven.uniqueCardsToday, 1); XCTAssertTrue(seven.studiedToday)
        let tomorrow = AchievementProgress.calculate(logs: logs, now: date(8, 4), calendar: calendar, startHour: 4)
        XCTAssertEqual(tomorrow.currentStreak, 7); XCTAssertFalse(tomorrow.studiedToday)
        let gap = AchievementProgress.calculate(logs: logs + [(id, date(9, 4))], now: date(9, 4), calendar: calendar, startHour: 4)
        XCTAssertEqual(gap.currentStreak, 1); XCTAssertEqual(gap.longestStreak, 7)
        for count in AchievementProgress.streakMilestones {
            let origin = date(1, 4)
            let history = (0..<count).map { (id, calendar.date(byAdding: .day, value: $0, to: origin)!) }
            XCTAssertEqual(AchievementProgress.calculate(logs: history, now: history.last!.1, calendar: calendar, startHour: 4).currentStreak, count)
        }
        let instant = date(7, 4)
        XCTAssertEqual(AchievementProgress.dayKey(instant, calendar: calendar, startHour: 4), "2026-10-07")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(AchievementProgress.dayKey(instant, calendar: calendar, startHour: 4), "2026-10-06")
    }

    func testAchievementUniqueCardsAndMatureDefinition() {
        let id = UUID(), now = Date()
        let repeated = Array(repeating: (id, now), count: 20)
        XCTAssertEqual(AchievementProgress.calculate(logs: repeated, now: now, calendar: .current, startHour: 4).uniqueCardsToday, 1)
        let distinct = (0..<20).map { _ in (UUID(), now) }
        XCTAssertEqual(AchievementProgress.calculate(logs: distinct, now: now, calendar: .current, startHour: 4).uniqueCardsToday, 20)
        XCTAssertTrue(MatureCards.contains(state: "review", stability: 21, suspended: false))
        XCTAssertFalse(MatureCards.contains(state: "relearning", stability: 100, suspended: false))
        XCTAssertFalse(MatureCards.contains(state: "review", stability: 21, suspended: true))
        XCTAssertFalse(MatureCards.contains(state: "review", stability: .infinity, suspended: false))
        XCTAssertFalse(MatureCards.contains(state: "review", stability: 20.9, suspended: false))
    }

    func testMemoryDistributionsExcludeInvalidValuesAndIncludeUpperBound() {
        let cards = [MemoryCard(id: UUID(), title: "A", stability: 1, difficulty: 3, retrievability: 0.2),
                     MemoryCard(id: UUID(), title: "B", stability: 90, difficulty: 10, retrievability: 1),
                     MemoryCard(id: UUID(), title: "Invalid", stability: .nan, difficulty: 0, retrievability: 2)]
        let report = MemoryAnalysis.calculate(cards: cards, logs: [], targets: [0.9, 0.9, 0.95],
                                              now: Date(), calendar: .current, startHour: 4)
        XCTAssertEqual(report.distributions.map(\.count), [2, 2, 2])
        XCTAssertEqual(report.distributions[0].median, 45.5)
        XCTAssertEqual(report.distributions[0].buckets[1].cards.count, 1)
        XCTAssertEqual(report.distributions[1].buckets.last?.cards.count, 1)
        XCTAssertEqual(report.estimatedRemembered, 1.2, accuracy: 0.0001)
        XCTAssertEqual(report.targets, [0.9, 0.95])
        let empty = MemoryAnalysis.calculate(cards: [], logs: [], targets: [], now: Date(), calendar: .current, startHour: 4)
        XCTAssertNil(empty.distributions[0].median)
        XCTAssertNil(empty.retention[0].rate)
    }

    func testObservedRetentionDeduplicatesReviewTrialsAtStudyDayBoundaryAndReevaluatesUndo() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func date(_ day: Int, _ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
        let id = UUID(), other = UUID()
        let logs = [
            StatisticLog(cardID: id, date: date(8, 3), grade: .again, durationMs: 0, beforeState: "review", sequence: 1),
            StatisticLog(cardID: id, date: date(8, 3), grade: .good, durationMs: 0, beforeState: "review", sequence: 2),
            StatisticLog(cardID: id, date: date(8, 4), grade: .hard, durationMs: 0, beforeState: "review"),
            StatisticLog(cardID: other, date: date(8, 5), grade: .easy, durationMs: 0, beforeState: "learning"),
            StatisticLog(cardID: other, date: date(8, 6), grade: .good, durationMs: 0, beforeState: "relearning"),
            StatisticLog(cardID: other, date: date(9, 5), grade: .good, durationMs: 0, beforeState: "review")]
        let now = date(8, 10)
        let report = ObservedRetention.calculate(logs: logs.reversed(), days: 7, now: now, calendar: calendar, startHour: 4)
        XCTAssertEqual(report.trials, 2); XCTAssertEqual(report.successes, 1)
        XCTAssertEqual(report.cardIDs, [id]); XCTAssertEqual(report.rate, 0.5)
        let today = ObservedRetention.calculate(logs: logs, days: 1, now: now, calendar: calendar, startHour: 4)
        XCTAssertEqual(today.trials, 1); XCTAssertEqual(today.rate, 1)
        let undone = ObservedRetention.calculate(logs: Array(logs.dropFirst()), days: 7, now: now, calendar: calendar, startHour: 4)
        XCTAssertEqual(undone.rate, 1)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let shifted = ObservedRetention.calculate(logs: logs, days: 7, now: now, calendar: calendar, startHour: 4)
        XCTAssertEqual(shifted.trials, 1); XCTAssertEqual(shifted.rate, 0)
    }

    func testEmptyWeakPracticeNeverReportsCompletion() {
        var session = WeakPracticeSession(cards: [])
        XCTAssertEqual(session.phase, .empty)
        XCTAssertEqual(session.completedCount, 0)
        session.reveal(); session.next(); session.previous(); session.restart()
        XCTAssertEqual(session.phase, .empty)
        XCTAssertNil(session.current)
        XCTAssertFalse(session.revealed)
    }

    func testWeakEvidenceThresholdsAndNoFutureOrInsufficientHistory() {
        let now = Date(timeIntervalSince1970: 1000), id = UUID()
        func log(_ grade: ReviewGrade, _ offset: Double = 0) -> StatisticLog {
            StatisticLog(cardID: id, date: now.addingTimeInterval(offset), grade: grade, durationMs: 0)
        }
        XCTAssertNil(WeakCardEvidence.evaluate(logs: [], difficulty: 10, retrievability: 0.1, now: now))
        XCTAssertNil(WeakCardEvidence.evaluate(logs: [log(.good)], difficulty: 10, retrievability: 0.1, now: now))
        XCTAssertNil(WeakCardEvidence.evaluate(logs: [log(.again, 1)], difficulty: 10, retrievability: 0.1, now: now))
        XCTAssertEqual(WeakCardEvidence.evaluate(logs: [log(.again)], difficulty: 1, retrievability: 1, now: now)?.reasons, ["直近の評価がAgain"])
        let evidence = WeakCardEvidence.evaluate(logs: [log(.again, -2), log(.again, -1), log(.good)], difficulty: 8, retrievability: 0.74, now: now)
        XCTAssertEqual(evidence?.reasons.count, 4)
        XCTAssertNil(WeakCardEvidence.evaluate(logs: [log(.good, -2), log(.good, -1), log(.good)], difficulty: 7.9, retrievability: 0.75, now: now))
    }

    func testFourAMUniqueCountsStreakRatingsAndRetention() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func date(_ day: Int, _ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
        let id = UUID()
        let logs = [StatisticLog(cardID: id, date: date(7, 12), grade: .good, durationMs: 1000),
                    StatisticLog(cardID: id, date: date(8, 3), grade: .again, durationMs: 2000),
                    StatisticLog(cardID: id, date: date(8, 5), grade: .easy, durationMs: 3000),
                    StatisticLog(cardID: UUID(), date: date(8, 6), grade: .hard, durationMs: 4000)]
        let result = StudyStatistics.calculate(logs: logs, retrievabilities: [0.8, 1, .nan], now: date(8, 10), calendar: calendar, startHour: 4)
        XCTAssertEqual(result.days[0].cards, 2); XCTAssertEqual(result.days[0].answers, 2)
        XCTAssertEqual(result.days[1].cards, 1); XCTAssertEqual(result.days[1].answers, 2)
        XCTAssertEqual(result.streak, 2)
        XCTAssertEqual(result.durationMs, 10000)
        XCTAssertEqual(result.meanRetrievability!, 0.9, accuracy: 0.0001)
        for grade in ReviewGrade.allCases { XCTAssertEqual(result.ratings[grade], 1) }
        let pendingToday = StudyStatistics.calculate(logs: Array(logs.prefix(2)), retrievabilities: [], now: date(8, 10), calendar: calendar, startHour: 4)
        XCTAssertEqual(pendingToday.streak, 1); XCTAssertNil(pendingToday.meanRetrievability)
        let broken = StudyStatistics.calculate(logs: logs, retrievabilities: [], now: date(10, 10), calendar: calendar, startHour: 4)
        XCTAssertEqual(broken.streak, 0)
    }
    func testStreakAcrossDSTAtNonexistentTwoAMBoundary() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func date(_ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: 12))! }
        let logs = (7...9).map { StatisticLog(cardID: UUID(), date: date($0), grade: .good, durationMs: 0) }
        let result = StudyStatistics.calculate(logs: logs, retrievabilities: [], now: date(9), calendar: calendar, startHour: 2)
        XCTAssertEqual(result.streak, 3)
        XCTAssertEqual(result.days.prefix(3).map(\.answers), [1, 1, 1])
    }
    func testSessionCountMatchesPersistedReviewLogsAndUndoRemoval() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func date(_ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: hour))!
        }
        let id = UUID()
        // Re-learning the same card is multiple answers but only one unique card.
        let logs = [
            StatisticLog(cardID: id, date: date(5), grade: .again, durationMs: 500, wasNew: true),
            StatisticLog(cardID: id, date: date(6), grade: .hard, durationMs: 600),
            StatisticLog(cardID: id, date: date(7), grade: .good, durationMs: 700)
        ]
        let before = StudyStatistics.calculate(logs: logs, retrievabilities: [], now: date(10),
                                                calendar: calendar, startHour: 4)
        XCTAssertEqual(before.days[0].answers, 3)
        XCTAssertEqual(before.days[0].cards, 1)
        XCTAssertEqual(before.days[0].newAnswers, 1)
        XCTAssertEqual(before.days[0].reviewAnswers, 2)
        XCTAssertEqual(before.days[0].ratings[.again], 1)
        XCTAssertEqual(before.days[0].ratings[.hard], 1)
        // Undo removes exactly the last persisted review log.
        let after = StudyStatistics.calculate(logs: Array(logs.dropLast()), retrievabilities: [],
                                               now: date(10), calendar: calendar, startHour: 4)
        XCTAssertEqual(after.days[0].answers, 2)
        XCTAssertEqual(after.days[0].cards, 1)
        XCTAssertEqual(after.days[0].reviewAnswers, 1)
        XCTAssertEqual(after.durationMs, 1100)
    }

    func testFilteringOrphanHistoryAndCurrentCardPredictions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func date(_ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: hour))!
        }
        let english = UUID(), japanese = UUID(), tag = UUID()
        let cardA = UUID(), cardB = UUID()
        let logs = [
            StatisticLog(cardID: cardA, date: date(3), grade: .good, durationMs: 100, deckID: english, tagIDs: [tag]),
            StatisticLog(cardID: cardA, date: date(5), grade: .again, durationMs: 100, wasNew: true, deckID: english, tagIDs: [tag]),
            StatisticLog(cardID: cardA, date: date(6), grade: .hard, durationMs: 100, deckID: english, tagIDs: [tag]),
            StatisticLog(cardID: cardB, date: date(7), grade: .easy, durationMs: 100, deckID: japanese),
            StatisticLog(cardID: UUID(), date: date(8), grade: .good, durationMs: 100),
            StatisticLog(cardID: cardB, date: date(12), grade: .good, durationMs: 100, deckID: japanese)
        ]
        let cards = [
            StatisticCardState(deckID: english, tagIDs: [tag], isSuspended: false,
                               isNew: false, dueDate: date(5), retrievability: 0.8),
            StatisticCardState(deckID: japanese, tagIDs: [], isSuspended: true,
                               isNew: false, dueDate: date(5), retrievability: 0.1),
            StatisticCardState(deckID: english, tagIDs: [tag], isSuspended: false,
                               isNew: true, dueDate: date(5), retrievability: nil)
        ]
        let all = StudyStatistics.calculate(logs: logs, retrievabilities: [], now: date(10),
                                             calendar: calendar, startHour: 4, cards: cards)
        XCTAssertEqual(all.days[0].answers, 4)
        XCTAssertEqual(all.days[1].answers, 1)
        XCTAssertEqual(all.days[0].cards, 3)
        XCTAssertEqual(all.unattributedAnswers, 1)
        XCTAssertEqual(all.overdueCount, 1)
        XCTAssertEqual(all.meanRetrievability!, 0.8, accuracy: 0.001)
        let scoped = StudyStatistics.calculate(logs: logs, retrievabilities: [], now: date(10),
                                                calendar: calendar, startHour: 4, cards: cards,
                                                selectedDeckIDs: [english], selectedTagIDs: [tag])
        XCTAssertEqual(scoped.days[0].answers, 2)
        XCTAssertEqual(scoped.days[0].cards, 1)
        XCTAssertEqual(scoped.unattributedAnswers, 0)
        XCTAssertEqual(scoped.ratings[.good], 1) // previous study day
    }

    func testCalendarWeeksMonthsAndTimeZonesUseStudyDayBoundaries() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        tokyo.firstWeekday = 2
        func date(_ day: Int, _ hour: Int) -> Date {
            tokyo.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
        }
        let card = UUID()
        let logs = [
            StatisticLog(cardID: card, date: date(1, 12), grade: .good, durationMs: 100),
            StatisticLog(cardID: card, date: date(5, 12), grade: .good, durationMs: 100),
            StatisticLog(cardID: card, date: date(10, 3), grade: .good, durationMs: 100)
        ]
        let result = StudyStatistics.calculate(logs: logs, retrievabilities: [], now: date(10, 12),
                                                calendar: tokyo, startHour: 4)
        XCTAssertEqual(result.days[0].answers, 0)
        XCTAssertEqual(result.days[1].answers, 1)
        XCTAssertEqual(result.weeks.suffix(2).map(\.answers), [1, 2])
        XCTAssertEqual(result.weeks.last?.cards, 1)
        XCTAssertEqual(result.months.last?.answers, 3)
        XCTAssertEqual(result.months.last?.cards, 1)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let utcResult = StudyStatistics.calculate(logs: [logs[2]], retrievabilities: [],
                                                   now: date(10, 12), calendar: utc, startHour: 4)
        XCTAssertEqual(utcResult.days[0].answers, 1)
    }

    func testTwelveThousandReviewAggregationCompletesWithinBudget() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let ids = (0..<200).map { _ in UUID() }
        let logs = (0..<12_000).map { index in
            StatisticLog(cardID: ids[index % ids.count],
                         date: now.addingTimeInterval(-Double(index % 600) * 3600),
                         grade: .good, durationMs: 300, wasNew: index < 200)
        }
        let start = Date()
        let result = StudyStatistics.calculate(logs: logs, retrievabilities: [], now: now,
                                                calendar: .current, startHour: 4)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result.ratings[.good], 12_000)
        XCTAssertEqual(result.durationMs, 3_600_000)
        XCTAssertEqual(result.weeks.count, 12)
        XCTAssertEqual(result.months.count, 12)
        print("Issue #9: 12000 answer aggregation: \(elapsed)s")
        XCTAssertLessThan(elapsed, 8, "Unexpectedly slow historical statistics aggregation")
    }

}
