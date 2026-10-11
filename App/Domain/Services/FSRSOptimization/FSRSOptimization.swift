import Foundation
import CryptoKit
import FSRS

struct OptimizationReview: Codable, Equatable, Sendable {
    let id: UUID
    let cardID: UUID
    let date: Date
    let grade: Int
    let sequence: Int
    let startsNew: Bool
}

struct OptimizationMetrics: Codable, Equatable, Sendable {
    let count: Int
    let logLoss: Double
    let rmse: Double
    var valid: Bool { count > 0 && logLoss.isFinite && logLoss >= 0 && rmse.isFinite && (0...1).contains(rmse) }
}

struct OptimizationReport: Codable, Equatable, Sendable {
    static let method = "FSRS-6-coordinate-v1"
    var method = Self.method
    var schedulerRevision = ReviewScheduler.revision
    let generatedAt: Date
    let digest: String
    let reviews: Int
    let days: Int
    let splitDate: Date
    let parameters: [Double]
    let previousParameters: [Double]?
    let standard: OptimizationMetrics
    let candidate: OptimizationMetrics
    let previous: OptimizationMetrics?
    let duration: Double
    var accepted: Bool {
        candidate.logLoss <= standard.logLoss * 0.99 && candidate.rmse <= standard.rmse &&
        (previous.map { candidate.logLoss <= $0.logLoss && candidate.rmse <= $0.rmse } ?? true)
    }
    var valid: Bool {
        method == Self.method && schedulerRevision == ReviewScheduler.revision && digest.count == 64 &&
        digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
        (400...10000).contains(reviews) && days >= 30 && days <= reviews &&
        standard.valid && candidate.valid && candidate.count == standard.count && candidate.count >= 80 &&
        (previous.map { $0.valid && $0.count == candidate.count } ?? true) &&
        FSRSOptimization.validParameters(parameters) &&
        (previousParameters.map(FSRSOptimization.validParameters) ?? true) &&
        (previousParameters == nil) == (previous == nil) &&
        duration.isFinite && duration >= 0 && duration <= 65 &&
        generatedAt.timeIntervalSince1970.isFinite && splitDate.timeIntervalSince1970.isFinite
    }
}

struct FSRSParameterChange: Codable, Equatable, Sendable {
    let date: Date
    let method: String
    let before: [Double]?
    let after: [Double]?
}

struct FSRSOptimizationState: Codable, Equatable, Sendable {
    var report: OptimizationReport?
    var activeParameters: [Double]?
    var changes: [FSRSParameterChange] = []
    var valid: Bool {
        (report.map(\.valid) ?? true) && (activeParameters.map(FSRSOptimization.validParameters) ?? true) &&
        changes.count <= 20 && changes.allSatisfy {
            $0.method == OptimizationReport.method && $0.date.timeIntervalSince1970.isFinite &&
            ($0.before.map(FSRSOptimization.validParameters) ?? true) && ($0.after.map(FSRSOptimization.validParameters) ?? true)
        }
    }
}

enum OptimizationError: LocalizedError {
    case insufficient, tooLarge, stale, invalid, timedOut
    var errorDescription: String? {
        switch self {
        case .insufficient: return "初回から連続した履歴で、日をまたぐ復習400件・学習30日・20カードが必要です。学習用320件と検証用80件にそれぞれ成功・Againが5件以上必要です。"
        case .tooLarge: return "履歴が1万件を超えています。今回の端末内最適化の上限です。標準設定を継続できます。"
        case .stale: return "履歴または適用中の設定が変わりました。もう一度計算してください。"
        case .invalid: return "最適化結果を検証できません。設定は変更されていません。"
        case .timedOut: return "計算時間の上限60秒に達しました。設定は変更されていません。"
        }
    }
}

// Uses the pinned Swift scheduler for every transition. There is no separately approximated FSRS formula.
enum FSRSOptimization {
    static let defaults = FSRSDefaults.defaultWv6
    // Conservative bounds around the pinned defaults, intersected with upstream v6 clamps.
    static let bounds: [ClosedRange<Double>] = [0.001...100, 0.001...100, 0.001...100, 0.001...100,
        1...10, 0.001...4, 0.001...4, 0.001...0.75, 0...4.5, 0...0.8, 0.001...3.5,
        0.001...5, 0.001...0.25, 0.001...0.9, 0...4, 0...1, 1...6, 0...2, 0...2, 0.01...0.8, 0.1...0.8]
    static func validParameters(_ values: [Double]) -> Bool {
        values.count == 21 && zip(values, bounds).allSatisfy { $0.isFinite && $1.contains($0) }
    }
    static func digest(_ reviews: [OptimizationReview]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(reviews)).map { String(format: "%02x", $0) }.joined()
    }
    struct Prepared {
        let events: [OptimizationReview]
        let eligible: Set<UUID>
        let split: Date
        let days: Int
    }
    static func prepare(_ reviews: [OptimizationReview]) throws -> Prepared {
        guard reviews.count <= 10000 else { throw OptimizationError.tooLarge }
        guard Set(reviews.map(\.id)).count == reviews.count,
              reviews.allSatisfy({ (1...4).contains($0.grade) && $0.date.timeIntervalSince1970.isFinite && $0.sequence >= 0 })
        else { throw OptimizationError.invalid }
        let ordered = reviews.sorted { $0.date == $1.date ? $0.sequence < $1.sequence : $0.date < $1.date }
        let groups = Dictionary(grouping: ordered, by: \.cardID)
        let completeCards = Set(groups.compactMap { $0.value.first?.startsNew == true ? $0.key : nil })
        let events = ordered.filter { completeCards.contains($0.cardID) }
        var last: [UUID: Date] = [:], eligible: [OptimizationReview] = []
        for event in events {
            if !event.startsNew, let date = last[event.cardID], event.date.timeIntervalSince(date) >= 86400 { eligible.append(event) }
            last[event.cardID] = event.date
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let days = Set(events.map { calendar.startOfDay(for: $0.date) }).count
        guard eligible.count >= 400, days >= 30, Set(eligible.map(\.cardID)).count >= 20 else { throw OptimizationError.insufficient }
        // Equal timestamps remain on the same side of the chronological split.
        let split = eligible[Int(Double(eligible.count) * 0.8) - 1].date
        let train = eligible.filter { $0.date <= split }, validation = eligible.filter { $0.date > split }
        func diverse(_ events: [OptimizationReview]) -> Bool {
            events.filter { $0.grade == 1 }.count >= 5 && events.filter { $0.grade != 1 }.count >= 5
        }
        guard train.count >= 320, validation.count >= 80, diverse(train), diverse(validation) else { throw OptimizationError.insufficient }
        return Prepared(events: events, eligible: Set(eligible.map(\.id)), split: split, days: days)
    }
    static func evaluate(_ input: Prepared, parameters: [Double], validation: Bool,
                         deadline: Date? = nil) throws -> OptimizationMetrics {
        guard validParameters(parameters) else { throw OptimizationError.invalid }
        let engine = FSRS(parameters: FSRSParameters(w: parameters, enableFuzz: false, enableShortTerm: true))
        var cards: [UUID: Card] = [:], loss = 0.0, squared = 0.0, count = 0
        for (index, event) in input.events.enumerated() {
            if index % 64 == 0 {
                try Task.checkCancellation()
                if let deadline, Date() > deadline { throw OptimizationError.timedOut }
            }
            if !validation && event.date > input.split { break }
            let before = event.startsNew ? Card(due: event.date) : (cards[event.cardID] ?? Card(due: event.date))
            if input.eligible.contains(event.id), (event.date > input.split) == validation {
                let probability = min(1 - 1e-7, max(1e-7, engine.getRetrievability(card: before, now: event.date).number))
                let outcome = event.grade == 1 ? 0.0 : 1.0
                guard probability.isFinite else { throw OptimizationError.invalid }
                loss -= outcome * log(probability) + (1 - outcome) * log(1 - probability)
                squared += pow(probability - outcome, 2); count += 1
            }
            // Validation answers update state only after their prediction, as in actual sequential review.
            cards[event.cardID] = try engine.next(card: before, now: event.date, grade: Rating(rawValue: event.grade)!).card
        }
        guard count > 0 else { throw OptimizationError.insufficient }
        return OptimizationMetrics(count: count, logLoss: loss / Double(count), rmse: sqrt(squared / Double(count)))
    }
    static func run(_ reviews: [OptimizationReview], previous: [Double]? = nil, now: Date) throws -> OptimizationReport {
        let start = Date(), deadline = start.addingTimeInterval(60), input = try prepare(reviews)
        var parameters = defaults
        var best = try evaluate(input, parameters: parameters, validation: false, deadline: deadline).logLoss
        // Fit only training loss, with a small penalty against moving away from standard parameters.
        for step in [0.2, 0.1] {
            for index in parameters.indices {
                let center = parameters[index]
                for sign in [-1.0, 1.0] {
                    var proposal = parameters
                    let lower = max(bounds[index].lowerBound, defaults[index] * 0.5)
                    let upper = min(bounds[index].upperBound, defaults[index] * 1.5)
                    proposal[index] = min(upper, max(lower, center + sign * step * max(defaults[index], 0.02)))
                    if proposal == parameters { continue }
                    let penalty = zip(proposal, defaults).reduce(0.0) { $0 + pow(($1.0 - $1.1) / max($1.1, 0.02), 2) } * 0.0001
                    let value = try evaluate(input, parameters: proposal, validation: false, deadline: deadline).logLoss + penalty
                    if value < best { best = value; parameters = proposal }
                }
            }
        }
        let standard = try evaluate(input, parameters: defaults, validation: true, deadline: deadline)
        let candidate = try evaluate(input, parameters: parameters, validation: true, deadline: deadline)
        let baseline = try previous.map { try evaluate(input, parameters: $0, validation: true, deadline: deadline) }
        try Task.checkCancellation()
        return OptimizationReport(generatedAt: now, digest: try digest(reviews), reviews: reviews.count, days: input.days,
                                  splitDate: input.split, parameters: parameters, previousParameters: previous,
                                  standard: standard, candidate: candidate, previous: baseline,
                                  duration: Date().timeIntervalSince(start))
    }
}
