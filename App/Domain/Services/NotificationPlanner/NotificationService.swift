import Foundation
import UserNotifications

enum NotificationPermission: Equatable { case unknown, denied, allowed }

@MainActor
protocol LocalNotificationCenter {
    func permission() async -> NotificationPermission
    func requestPermission() async throws -> Bool
    func pending() async -> [PlannedNotification]
    func delivered() async -> Set<String>
    func remove(_ ids: [String])
    func add(_ item: PlannedNotification) async throws
}

@MainActor
final class AppleNotificationCenter: LocalNotificationCenter {
    let center = UNUserNotificationCenter.current()
    let identifierPrefix: String
    init(identifierPrefix: String = "review-") { self.identifierPrefix = identifierPrefix }
    func permission() async -> NotificationPermission {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        default: return .unknown
        }
    }
    func requestPermission() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound]) }
    func pending() async -> [PlannedNotification] {
        let planner = NotificationPlanner(identifierPrefix: identifierPrefix)
        return await center.pendingNotificationRequests().filter { planner.owns($0.identifier) }.map {
            let trigger = $0.trigger as? UNCalendarNotificationTrigger
            return PlannedNotification(id: $0.identifier, date: trigger?.nextTriggerDate() ?? .distantPast,
                                       timeZoneID: trigger?.dateComponents.timeZone?.identifier ?? "")
        }
    }
    func delivered() async -> Set<String> { Set(await center.deliveredNotifications().map { $0.request.identifier }) }
    func remove(_ ids: [String]) { center.removePendingNotificationRequests(withIdentifiers: ids) }
    func add(_ item: PlannedNotification) async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: item.timeZoneID) ?? .current
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: item.date)
        parts.calendar = calendar; parts.timeZone = calendar.timeZone
        let content = UNMutableNotificationContent()
        content.title = "復習の時間です"; content.body = "今日の復習があります。ホームから学習を始めましょう。"
        #if DEBUG
        if identifierPrefix.hasPrefix("review-test-") {
            content.subtitle = identifierPrefix
            content.title = "復習テスト \(identifierPrefix.dropFirst("review-test-".count).prefix(8))"
        }
        #endif
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: item.id, content: content,
                                                  trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
    }
}

@MainActor
final class NotificationService {
    let center: any LocalNotificationCenter
    let identifierPrefix: String
    private(set) var scheduledCount = 0
    private var generation = 0
    private var reconciling = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private struct Input: Equatable {
        let due: Date
        let hiddenUntil: Date?
    }
    private struct PlanKey: Equatable {
        let cards: [Input]
        let options: NotificationOptions
        let calendar: Calendar
        let permission: NotificationPermission
        let delivered: Set<String>
    }
    private var cachedPlan: (key: PlanKey, evaluatedAt: Date, validUntil: Date, desired: [PlannedNotification])?
    #if DEBUG
    private(set) var planningCount = 0
    #endif
    init(center: (any LocalNotificationCenter)? = nil, identifierPrefix: String = "review-") {
        self.identifierPrefix = identifierPrefix
        self.center = center ?? AppleNotificationCenter(identifierPrefix: identifierPrefix)
    }
    // Only the settings enable action invokes this method.
    func enablePermission() async throws -> Bool {
        let permission = await center.permission()
        if permission == .unknown { return try await center.requestPermission() }
        return permission == .allowed
    }
    func reconcile(cards: [QueueCard], options: NotificationOptions, calendar: Calendar, now: Date) async throws -> NotificationPermission {
        generation += 1; let current = generation
        // UNUserNotificationCenter.add is asynchronous. Serialize diffs so a newer
        // cancellation cannot miss an older add that is still in flight.
        if reconciling { await withCheckedContinuation { waiters.append($0) } }
        else { reconciling = true }
        defer {
            if waiters.isEmpty { reconciling = false }
            else { waiters.removeFirst().resume() }
        }
        let permission = await center.permission()
        let pending = await center.pending()
        let delivered = await center.delivered()
        guard current == generation, !Task.isCancelled else { return permission }
        let planner = NotificationPlanner(calendar: calendar, identifierPrefix: identifierPrefix)
        let inputs = cards.filter { !$0.suspended && $0.state != "new" }.map {
            Input(due: $0.due, hiddenUntil: $0.hiddenUntil)
        }.sorted {
            if $0.due != $1.due { return $0.due < $1.due }
            return ($0.hiddenUntil ?? .distantPast) < ($1.hiddenUntil ?? .distantPast)
        }
        let key = PlanKey(cards: inputs, options: options, calendar: calendar, permission: permission,
                          delivered: delivered.filter { planner.owns($0) })
        let desired: [PlannedNotification]
        if let cached = cachedPlan, cached.key == key, now >= cached.evaluatedAt, now < cached.validUntil {
            desired = cached.desired
        } else {
            desired = planner.plan(cards: cards, options: options, authorized: permission == .allowed, delivered: delivered, now: now)
            #if DEBUG
            planningCount += 1
            #endif
            let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            let time = calendar.date(bySettingHour: options.hour, minute: options.minute, second: 0, of: now)
            let boundary = min(midnight, time.flatMap { $0 > now ? $0 : nil } ?? midnight)
            cachedPlan = inputs.count <= 10000 && key.delivered.count <= 1000 ? (key, now, boundary, desired) : nil
        }
        let difference = planner.difference(pending: pending, desired: desired)
        if !difference.remove.isEmpty { center.remove(difference.remove) }
        for item in difference.add {
            guard current == generation, !Task.isCancelled else { break }
            try await center.add(item)
        }
        if current == generation, !Task.isCancelled { scheduledCount = await center.pending().filter { planner.owns($0.id) }.count }
        return permission
    }
}

extension Notification.Name { static let studyNotificationOpened = Notification.Name("StudyNotificationOpened") }

final class StudyNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier.hasPrefix("review-") {
            DispatchQueue.main.async { NotificationCenter.default.post(name: .studyNotificationOpened, object: nil) }
        }
        completionHandler()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
