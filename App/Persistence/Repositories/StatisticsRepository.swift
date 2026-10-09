import Foundation

extension StudyRepository {
    func statistics(now: Date) throws -> StudyStatistics {
        let logs = try logs().map {
            guard let grade = ReviewGrade(rawValue: $0.grade) else { throw StudyError.unsupportedContent }
            return StatisticLog(cardID: $0.cardID, date: $0.reviewedAt, grade: grade, durationMs: $0.durationMs)
        }
        let scheduler = try ReviewScheduler()
        let retention = try cards().filter { !$0.isSuspended }.compactMap { card -> Double? in
            let snapshot = try snapshot(card)
            guard try scheduler.summary(snapshot).state != "new" else { return nil }
            return try scheduler.retrievability(snapshot, now: now)
        }
        return StudyStatistics.calculate(logs: logs, retrievabilities: retention, now: now,
                                         calendar: calendar, startHour: try settings().dayStartHour)
    }
}
