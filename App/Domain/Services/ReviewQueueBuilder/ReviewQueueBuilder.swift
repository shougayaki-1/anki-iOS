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

struct QueueCard: Sendable, Equatable {
    var studyPaused = false
    let id: UUID
    let state: String
    let due: Date
    let createdAt: Date
    let suspended: Bool
    var hiddenUntil: Date? = nil
    func isHidden(at date: Date) -> Bool { hiddenUntil.map { date < $0 } ?? false }
    var noteID: UUID? = nil
    var deckLimits: [UUID: Int] = [:]
}

struct QueueLog: Sendable, Equatable {
    let cardID: UUID
    let reviewedAt: Date
    let wasNew: Bool
    var noteID: UUID? = nil
    var quotaDeckIDs: [UUID] = []
}

enum ReviewOrderPolicy: String, Codable {
    case traditional, forgettingRisk
}

struct ReviewQueueBuilder {
    var calendar: Calendar = .current
    // Tie-breaking can be injected to keep tests deterministic.
    var shuffled: ([QueueCard]) -> [QueueCard] = { $0.shuffled() }

    private func freshCards(_ cards: [QueueCard], today: [QueueLog], limit: Int = .max) -> [QueueCard] {
        let probe = PerformanceProbe.begin("Queue.freshCards")
        defer { PerformanceProbe.end(probe) }
        guard limit > 0 else { return [] }
        var selected: [QueueCard] = []
        var consumed: [UUID: Int] = [:]
        var used: [UUID: Set<UUID>] = [:]
        for log in today where log.wasNew {
            for key in log.quotaDeckIDs { used[key, default: []].insert(log.cardID) }
        }
        // UUID formatting in the comparator was repeated O(n log n) times for
        // imported cards sharing a creation date. Preserve the exact tie order.
        let fresh = cards.filter { $0.state == "new" }
        let keyed: [(card: QueueCard, key: String)] = fresh.map { (card: $0, key: $0.id.uuidString) }
        let ordered = keyed.sorted { lhs, rhs in
            if lhs.card.createdAt != rhs.card.createdAt { return lhs.card.createdAt < rhs.card.createdAt }
            return lhs.key < rhs.key
        }
        for entry in ordered {
            let card = entry.card
            guard card.deckLimits.allSatisfy({ key, limit in
                return used[key, default: []].count + consumed[key, default: 0] < limit
            }) else { continue }
            selected.append(card)
            for key in card.deckLimits.keys { consumed[key, default: 0] += 1 }
            if selected.count == limit { break }
        }
        return selected
    }

    // Index distinct reviewed cards once; repeated answers to the same card
    // must not bury that card, while any different card of the note does.
    private func reviewedCardsByNote(_ logs: [QueueLog]) -> [UUID: Set<UUID>] {
        var result: [UUID: Set<UUID>] = [:]
        for log in logs {
            if let noteID = log.noteID { result[noteID, default: []].insert(log.cardID) }
        }
        return result
    }

    func counts(cards: [QueueCard], logs: [QueueLog], settings: StudySettings, now: Date) -> HomeCounts {
        let probe = PerformanceProbe.begin("Queue.counts")
        defer { PerformanceProbe.end(probe) }
        let interval = StudyDay(calendar: calendar, startHour: settings.dayStartHour).interval(containing: now)
        let today = logs.filter { $0.reviewedAt >= interval.start && $0.reviewedAt < interval.end }
        let used = Set(today.filter(\.wasNew).map(\.cardID)).count
        let reviewed = settings.siblingBuryEnabled ? reviewedCardsByNote(today) : [:]
        let available = cards.filter { card in
            guard !card.suspended && !card.isHidden(at: now) else { return false }
            if !settings.siblingBuryEnabled || card.state == "learning" || card.state == "relearning" { return true }
            guard let noteID = card.noteID else { return true }
            guard let answered = reviewed[noteID] else { return true }
            return answered.count == 1 && answered.contains(card.id)
        }
        let fresh: Int
        if available.contains(where: { $0.state == "new" && !$0.deckLimits.isEmpty }) {
            fresh = freshCards(available, today: today).count
        } else {
            // Counting unconstrained new cards needs neither ordering nor allocation.
            fresh = available.reduce(0) { $0 + ($1.state == "new" ? 1 : 0) }
        }
        return HomeCounts(
            due: available.filter { $0.state != "new" && $0.due <= now }.count,
            totalNew: cards.filter { !$0.suspended && $0.state == "new" }.count, newRemaining: min(fresh, max(0, settings.dailyNewLimit - used)),
            learnedToday: Set(today.map(\.cardID)).count, answerCount: today.count, eligibleNew: available.filter { $0.state == "new" }.count,
            suspendedNew: cards.filter { $0.suspended && $0.state == "new" }.count
        )
    }

    func queue(cards: [QueueCard], logs: [QueueLog], settings: StudySettings, mode: StudyMode,
               touched: Set<UUID>, reviewStreak: Int, now: Date,
               policy: ReviewOrderPolicy = .traditional, reviewOrder: [UUID]? = nil,
               fixedReviewOrder: [UUID]? = nil,
               retrievability: (UUID) -> Double? = { _ in nil }) -> [UUID] {
        let probe = PerformanceProbe.begin("Queue.build")
        defer { PerformanceProbe.end(probe) }
        let day = StudyDay(calendar: calendar, startHour: settings.dayStartHour).interval(containing: now)
        let today = logs.filter { $0.reviewedAt >= day.start && $0.reviewedAt < day.end }
        let reviewed = settings.siblingBuryEnabled ? reviewedCardsByNote(today) : [:]
        let eligible = cards.filter { card in
            if card.studyPaused || card.suspended || card.isHidden(at: now) { return false }
            if !settings.siblingBuryEnabled || card.state == "learning" || card.state == "relearning" { return true }
            guard let noteID = card.noteID else { return true }
            guard let answered = reviewed[noteID] else { return true }
            return answered.count == 1 && answered.contains(card.id)
        }
        let dueCandidates = eligible.filter { $0.state != "new" && $0.due <= now }
        if mode == .review, let fixedReviewOrder {
            let available = Set(dueCandidates.lazy.filter { !touched.contains($0.id) }.map(\.id))
            return fixedReviewOrder.filter { available.contains($0) }
        }
        let due: [QueueCard]
        let short: [QueueCard]
        if policy == .traditional {
            let randomized = shuffled(eligible)
            let rank = Dictionary(uniqueKeysWithValues: randomized.enumerated().map { ($0.element.id, $0.offset) })
            due = dueCandidates.sorted {
                if $0.due != $1.due { return $0.due < $1.due }
                return rank[$0.id, default: 0] < rank[$1.id, default: 0]
            }
            short = due.filter { $0.state == "learning" || $0.state == "relearning" }
        } else {
            // Frozen reviews need only their saved rank; do not sort the whole
            // backlog by due first on every answer. Short steps remain dynamic.
            due = dueCandidates
            short = due.filter { $0.state == "learning" || $0.state == "relearning" }.sorted {
                if $0.due != $1.due { return $0.due < $1.due }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
        var reviews = due.filter { $0.state == "review" }
        if policy == .forgettingRisk {
            if let reviewOrder {
                let ranks = Dictionary(reviewOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
                reviews.sort {
                    let lhs = ranks[$0.id, default: .max], rhs = ranks[$1.id, default: .max]
                    if lhs != rhs { return lhs < rhs }
                    if $0.due != $1.due { return $0.due < $1.due }
                    return $0.id.uuidString < $1.id.uuidString
                }
            } else {
                // Calculate only eligible due reviews, once per candidate. Invalid
                // predictions retain their deterministic due-order slots, avoiding
                // a non-transitive comparator mixing probability and due dates.
                reviews.sort {
                    if $0.due != $1.due { return $0.due < $1.due }
                    return $0.id.uuidString < $1.id.uuidString
                }
                let predicted = reviews.enumerated().compactMap { index, card -> (Int, QueueCard, Double)? in
                    guard let value = retrievability(card.id), value.isFinite, (0...1).contains(value) else { return nil }
                    return (index, card, value)
                }
                let ordered = predicted.sorted {
                    if $0.2 != $1.2 { return $0.2 < $1.2 }
                    if $0.1.due != $1.1.due { return $0.1.due < $1.1.due }
                    return $0.1.id.uuidString < $1.1.id.uuidString
                }
                for (slot, entry) in zip(predicted, ordered) { reviews[slot.0] = entry.1 }
            }
        }
        // The global cap and deck caps are independent. Select the bounded prefix
        // once, rather than sorting once for counts and again for the same queue.
        let remaining = max(0, settings.dailyNewLimit - Set(today.filter(\.wasNew).map(\.cardID)).count)
        let fresh = mode == .review ? [] : freshCards(eligible, today: today, limit: remaining)
        switch mode {
        case .review: return (short + reviews).map(\.id)
        case .new: return (short.filter { touched.contains($0.id) } + fresh).map(\.id)
        case .mixed:
            var result = short.map(\.id)
            let r = reviews.map(\.id), n = fresh.map(\.id)
            var ri = 0, ni = 0, streak = reviewStreak
            while ri < r.count || ni < n.count {
                if ni < n.count && (streak >= 3 || ri == r.count) {
                    result.append(n[ni]); ni += 1; streak = 0
                } else if ri < r.count {
                    result.append(r[ri]); ri += 1; streak += 1
                }
            }
            return result
        }
    }
}
