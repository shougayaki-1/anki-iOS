import Foundation

struct WidgetPoint: Codable, Equatable, Sendable {
    let date: Date
    let due: Int
    let newAvailable: Int
    let learnedToday: Int
    let answersToday: Int
}
struct WidgetSnapshot: Codable, Equatable, Sendable {
    static let group = "group.dev.shoug.AnkiIOS.widgets"
    static let kind = "StudyProgressWidget"
    var schemaVersion = 1
    let generatedAt: Date
    let expiresAt: Date
    let timeZone: String
    let dayStartHour: Int
    let dailyGoal: Int?
    let points: [WidgetPoint]
    var streakDays: [WidgetStreakDay]? = nil
    var dailyCard: DailyWidgetCard? = nil
    var dailyCardExpiresAt: Date? = nil
    var reviewForecast: WidgetReviewForecast? = nil

    func valid() -> Bool {
        guard schemaVersion == 1, generatedAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > generatedAt, expiresAt.timeIntervalSince(generatedAt) <= 9 * 86400,
              TimeZone(identifier: timeZone) != nil, (0...23).contains(dayStartHour),
              dailyGoal == nil || (1...100_000).contains(dailyGoal!), !points.isEmpty, points.count <= 128,
              points.first?.date == generatedAt else { return false }
        if let forecast = reviewForecast {
            guard forecast.days.count == 7, forecast.overdue >= 0, forecast.days.allSatisfy({ $0.count >= 0 && $0.date.timeIntervalSince1970.isFinite }),
                  zip(forecast.days, forecast.days.dropFirst()).allSatisfy({ $0.date < $1.date }),
                  forecast.card.map({ $0.question.count <= 500 && $0.deck.count <= 120 }) ?? true else { return false }
        }
        if let dailyCard {
            guard dailyCard.question.count <= 500, dailyCard.deck.count <= 120 else { return false }
        }
        if let expiry = dailyCardExpiresAt {
            guard expiry > generatedAt, expiry <= expiresAt else { return false }
        }
        if let streakDays {
            guard (1...8).contains(streakDays.count), streakDays.allSatisfy({
                $0.date.timeIntervalSince1970.isFinite && $0.streak >= 0 && $0.cards >= 0 && $0.recent.count == 7
            }), zip(streakDays, streakDays.dropFirst()).allSatisfy({ $0.date < $1.date }) else { return false }
        }
        var previous: Date?
        for point in points {
            guard point.date.timeIntervalSince1970.isFinite, point.date >= generatedAt, point.date < expiresAt,
                  previous == nil || point.date > previous!, (0...300_000).contains(point.due),
                  (0...300_000).contains(point.newAvailable), (0...300_000).contains(point.learnedToday),
                  (0...1_000_000).contains(point.answersToday) else { return false }
            previous = point.date
        }
        return true
    }
    func point(at now: Date, timeZone: TimeZone = .current) -> WidgetPoint? {
        guard valid(), self.timeZone == timeZone.identifier, now >= generatedAt, now < expiresAt else { return nil }
        return points.last { $0.date <= now }
    }
}

// The extension only reads this file. It never links SwiftData, FSRS or repository code.
struct WidgetSnapshotFile: Sendable {
    static let maximumBytes = 64_000
    let url: URL?
    static func shared() -> Self {
        Self(url: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshot.group)?.appendingPathComponent("progress-v1.json"))
    }
    func read() -> WidgetSnapshot? {
        guard let url, let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= Self.maximumBytes,
              let bytes = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(WidgetSnapshot.self, from: bytes), value.valid() else { return nil }
        return value
    }
    func write(_ value: WidgetSnapshot) throws {
        guard let url, value.valid() else { throw WidgetSnapshotFailure.unavailable }
        let bytes = try JSONEncoder().encode(value)
        guard bytes.count <= Self.maximumBytes else { throw WidgetSnapshotFailure.unavailable }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
enum WidgetSnapshotFailure: LocalizedError {
    case unavailable
    var errorDescription: String? { "ウィジェット用の情報を共有できませんでした。アプリ本体の学習は続けられます。" }
}

enum WidgetDestination: Equatable {
    case home, review, progress
    case card(UUID, answer: Bool)
    static func parse(_ url: URL) -> Self? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "ankistudy", parts.host == "widget", parts.query == nil,
              parts.fragment == nil, parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        switch parts.path {
        case "/home": return .home
        case "/review": return .review
        case "/progress": return .progress
        default:
            let path = parts.path.split(separator: "/")
            guard (path.count == 2 || path.count == 3), path[0] == "card",
                  let id = UUID(uuidString: String(path[1])), path.count == 2 || path[2] == "answer" else { return nil }
            return .card(id, answer: path.count == 3)
        }
    }
}

// Question-only projection. Answers never leave the application database.
struct DailyWidgetCard: Codable, Equatable, Sendable {
    let id: UUID
    let deck: String
    let question: String
    let requiresApp: Bool
    func url(answer: Bool = false) -> URL {
        URL(string: "ankistudy://widget/card/\(id.uuidString)\(answer ? "/answer" : "")")!
    }
}

// Eight compact study-day projections; no card IDs or history are shared.
struct WidgetStreakDay: Codable, Equatable, Sendable {
    let date: Date
    let streak: Int
    let cards: Int
    let recent: [Bool] // oldest first, ending on this study day
    var studied: Bool { cards > 0 }
}
extension WidgetSnapshot {
    func streak(at date: Date, timeZone: TimeZone = .current) -> WidgetStreakDay? {
        guard point(at: date, timeZone: timeZone) != nil else { return nil }
        return streakDays?.last { $0.date <= date }
    }
}

struct WidgetForecastDay: Codable, Equatable, Sendable {
    let date: Date
    let count: Int
}
struct WidgetReviewForecast: Codable, Equatable, Sendable {
    let days: [WidgetForecastDay]
    let overdue: Int // saved deadline before the current study day's start
    var card: DailyWidgetCard? = nil
}
extension WidgetSnapshot {
    func forecast(at date: Date, timeZone: TimeZone = .current) -> WidgetReviewForecast? {
        guard point(at: date, timeZone: timeZone) != nil,
              let expiry = dailyCardExpiresAt, date < expiry else { return nil }
        return reviewForecast
    }
}
