import Foundation

struct NotificationOptions: Codable, Equatable {
    var enabled = false
    var hour = 20
    var minute = 0
}

struct PlannedNotification: Equatable {
    let id: String
    let date: Date
    let timeZoneID: String
}

struct NotificationDifference {
    let remove: [String]
    let add: [PlannedNotification]
}

struct NotificationPlanner {
    var calendar: Calendar = .current
    var identifierPrefix = "review-"

    func owns(_ identifier: String) -> Bool {
        identifier.hasPrefix(identifierPrefix) && identifier.count == identifierPrefix.count + 10
    }

    func plan(cards: [QueueCard], options: NotificationOptions, authorized: Bool,
              delivered: Set<String>, now: Date) -> [PlannedNotification] {
        guard options.enabled, authorized, (0...23).contains(options.hour), (0...59).contains(options.minute) else { return [] }
        let learned = cards.filter { !$0.suspended && $0.state != "new" }
        guard !learned.isEmpty else { return [] }
        let start = calendar.startOfDay(for: now)
        let candidates = (0...30).compactMap { offset -> Date? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                  let time = calendar.date(bySettingHour: options.hour, minute: options.minute, second: 0, of: day), time > now else { return nil }
            return time
        }.prefix(30)
        return candidates.compactMap { time in
            guard learned.contains(where: { $0.due <= time }) else { return nil }
            var identifierCalendar = Calendar(identifier: .gregorian)
            identifierCalendar.timeZone = calendar.timeZone
            let parts = identifierCalendar.dateComponents([.year, .month, .day], from: time)
            let id = identifierPrefix + String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
            guard !delivered.contains(id) else { return nil }
            return PlannedNotification(id: id, date: time, timeZoneID: calendar.timeZone.identifier)
        }
    }

    func difference(pending: [PlannedNotification], desired: [PlannedNotification]) -> NotificationDifference {
        let requested = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0) })
        let existing = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0) })
        return NotificationDifference(
            remove: pending.filter { owns($0.id) && requested[$0.id] != $0 }.map(\.id),
            add: desired.filter { existing[$0.id] != $0 })
    }
}
