import Foundation
import WidgetKit

struct WidgetProjectionSettings: Sendable {
    let dayStartHour: Int
    let dailyNewLimit: Int
    let siblingBuryEnabled: Bool
    let dailyGoal: Int?
    init(_ settings: StudySettings) {
        dayStartHour = settings.dayStartHour; dailyNewLimit = settings.dailyNewLimit
        siblingBuryEnabled = settings.siblingBuryEnabled; dailyGoal = settings.dailyGoal
    }
}
enum WidgetProjection {
    static func make(cards: [QueueCard], logs: [QueueLog], settings: WidgetProjectionSettings, now: Date, calendar: Calendar) throws -> WidgetSnapshot {
        let day = StudyDay(calendar: calendar, startHour: settings.dayStartHour)
        var dates: Set<Date> = [now], boundary = day.interval(containing: now).end
        for _ in 0..<7 { dates.insert(boundary); boundary = day.interval(containing: boundary).end }
        // At most 120 aggregate entries, including all seven day boundaries.
        let dueDates = Set(cards.filter { !$0.suspended && $0.state != "new" && $0.due > now && $0.due < boundary }.map(\.due)).sorted()
        dates.formUnion(dueDates.prefix(112))
        let expires = dueDates.count > 112 ? min(boundary, dueDates[112]) : boundary
        // Cache eligibility by study day. The widget must not repeat a cards × logs
        // sibling scan for every timeline entry or block the review/save actor.
        var cache: [Date: (cards: [QueueCard], new: Int, learned: Int, answers: Int)] = [:]
        let points = try dates.filter { $0 < expires }.sorted().map { date -> WidgetPoint in
            try Task.checkCancellation()
            let interval = day.interval(containing: date)
            if cache[interval.start] == nil {
                let today = logs.filter { $0.reviewedAt >= interval.start && $0.reviewedAt < interval.end }
                let byNote = Dictionary(grouping: today.compactMap { log in log.noteID.map { ($0, log.cardID) } }, by: { $0.0 })
                    .mapValues { Set($0.map { $0.1 }) }
                let eligible = cards.filter { card in
                    guard !card.suspended else { return false }
                    if !settings.siblingBuryEnabled || card.state == "learning" || card.state == "relearning" { return true }
                    guard let note = card.noteID, let answered = byNote[note] else { return true }
                    return answered.count == 1 && answered.contains(card.id)
                }
                let used = Set(today.filter(\.wasNew).map(\.cardID)).count
                cache[interval.start] = (eligible, min(eligible.filter { $0.state == "new" }.count, max(0, settings.dailyNewLimit - used)),
                    Set(today.map(\.cardID)).count, today.count)
            }
            let values = cache[interval.start]!
            return WidgetPoint(date: date, due: values.cards.filter { $0.state != "new" && $0.due <= date }.count,
                newAvailable: values.new, learnedToday: values.learned, answersToday: values.answers)
        }
        return WidgetSnapshot(generatedAt: now, expiresAt: expires, timeZone: calendar.timeZone.identifier,
            dayStartHour: settings.dayStartHour, dailyGoal: settings.dailyGoal, points: points)
    }
}

@MainActor final class WidgetSnapshotPublisher {
    private struct Key: Equatable {
        let counts: HomeCounts
        let next: Date
        let start: Date
        let zone: String
        let goal: Int?
    }
    let file: WidgetSnapshotFile
    private let reload: () -> Void
    private var previous: Key?
    private var job: Task<Void, Never>?
    private var generation = 0
    init(file: WidgetSnapshotFile, reload: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.kind) }) {
        self.file = file; self.reload = reload
    }
    func publish(repository: StudyRepository, snapshot: HomeSnapshot, settings: StudySettings, now: Date,
                 force: Bool, cards suppliedCards: [QueueCard]? = nil, logs suppliedLogs: [QueueLog]? = nil, completion: @escaping (String?) -> Void) {
        let key = Key(counts: snapshot.globalCounts, next: snapshot.nextRefresh, start: snapshot.dayStart,
                      zone: repository.calendar.timeZone.identifier, goal: settings.dailyGoal)
        guard force || previous != key else { return }
        job?.cancel(); generation += 1
        let generation = generation
        do {
            guard file.url != nil else { throw WidgetSnapshotFailure.unavailable }
            let cards = try suppliedCards ?? repository.queueCards()
            let logs = try suppliedLogs ?? repository.todayQueueLogs(cards: cards, settings: settings, now: now)
            let calendar = repository.calendar, projected = WidgetProjectionSettings(settings)
            job = Task { [weak self] in
                let task = Task.detached(priority: .utility) {
                    try WidgetProjection.make(cards: cards, logs: logs, settings: projected, now: now, calendar: calendar)
                }
                do {
                    let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                    guard let self, !Task.isCancelled, self.generation == generation else { return }
                    try self.file.write(value)
                    self.previous = key; self.reload(); completion(nil)
                } catch is CancellationError {} catch {
                    guard let self, self.generation == generation else { return }
                    completion(WidgetSnapshotFailure.unavailable.localizedDescription)
                }
            }
        } catch { completion(WidgetSnapshotFailure.unavailable.localizedDescription) }
    }
}
