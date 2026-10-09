import Foundation

struct StudyDay {
    var calendar: Calendar = .current
    var startHour = 4

    func interval(containing now: Date) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let boundary = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: today)!
        let start: Date
        if now < boundary {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
            start = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: yesterday)!
        } else {
            start = boundary
        }
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))!
        let end = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: nextDay)!
        return DateInterval(start: start, end: end)
    }
}

struct QueueCard {
    let id: UUID
    let state: String
    let due: Date
    let createdAt: Date
    let suspended: Bool
    var noteID: UUID? = nil
}

struct QueueLog {
    let cardID: UUID
    let reviewedAt: Date
    let wasNew: Bool
    var noteID: UUID? = nil
}

struct ReviewQueueBuilder {
    var calendar: Calendar = .current
    // Tie-breaking can be injected to keep tests deterministic.
    var shuffled: ([QueueCard]) -> [QueueCard] = { $0.shuffled() }

    func counts(cards: [QueueCard], logs: [QueueLog], settings: StudySettings, now: Date) -> HomeCounts {
        let interval = StudyDay(calendar: calendar, startHour: settings.dayStartHour).interval(containing: now)
        let today = logs.filter { $0.reviewedAt >= interval.start && $0.reviewedAt < interval.end }
        let used = Set(today.filter(\.wasNew).map(\.cardID)).count
        let available = cards.filter { card in
            guard !card.suspended else { return false }
            if !settings.siblingBuryEnabled || card.state == "learning" || card.state == "relearning" { return true }
            guard let noteID = card.noteID else { return true }
            return !today.contains { $0.noteID == noteID && $0.cardID != card.id }
        }
        let fresh = available.filter { $0.state == "new" }.count
        return HomeCounts(
            due: available.filter { $0.state != "new" && $0.due <= now }.count,
            totalNew: cards.filter { !$0.suspended && $0.state == "new" }.count, newRemaining: min(fresh, max(0, settings.dailyNewLimit - used)),
            learnedToday: Set(today.map(\.cardID)).count, answerCount: today.count
        )
    }

    func queue(cards: [QueueCard], logs: [QueueLog], settings: StudySettings, mode: StudyMode,
               touched: Set<UUID>, reviewStreak: Int, now: Date) -> [UUID] {
        let day = StudyDay(calendar: calendar, startHour: settings.dayStartHour).interval(containing: now)
        let today = logs.filter { $0.reviewedAt >= day.start && $0.reviewedAt < day.end }
        let eligible = cards.filter { card in
            if card.suspended { return false }
            if !settings.siblingBuryEnabled || card.state == "learning" || card.state == "relearning" { return true }
            guard let noteID = card.noteID else { return true }
            return !today.contains { $0.noteID == noteID && $0.cardID != card.id }
        }
        let randomized = shuffled(eligible)
        let rank = Dictionary(uniqueKeysWithValues: randomized.enumerated().map { ($0.element.id, $0.offset) })
        let due = eligible.filter { $0.state != "new" && $0.due <= now }.sorted {
            if $0.due != $1.due { return $0.due < $1.due }
            return rank[$0.id, default: 0] < rank[$1.id, default: 0]
        }
        let short = due.filter { $0.state == "learning" || $0.state == "relearning" }
        let reviews = due.filter { $0.state == "review" }
        let remaining = counts(cards: cards, logs: logs, settings: settings, now: now).newRemaining
        let fresh = eligible.filter { $0.state == "new" }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }.prefix(remaining)
        switch mode {
        case .review: return (short + reviews).map(\.id)
        case .new: return (short.filter { touched.contains($0.id) } + fresh).map(\.id)
        case .mixed:
            var result = short.map(\.id)
            var r = reviews.map(\.id), n = fresh.map(\.id)
            var streak = reviewStreak
            while !r.isEmpty || !n.isEmpty {
                if !n.isEmpty && (streak >= 3 || r.isEmpty) {
                    result.append(n.removeFirst()); streak = 0
                } else if !r.isEmpty {
                    result.append(r.removeFirst()); streak += 1
                }
            }
            return result
        }
    }
}
