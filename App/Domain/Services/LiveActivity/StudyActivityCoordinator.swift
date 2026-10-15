import Foundation
#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

struct StudyActivitySnapshot: Equatable {
    let sessionID: String
    let state: StudyActivityState
}
struct StudyActivityHandle {
    let id: String
    let sessionID: String
    var reusable = true
}

@MainActor protocol StudyActivityDriver {
    var authorized: Bool { get }
    var activities: [StudyActivityHandle] { get }
    func start(_ snapshot: StudyActivitySnapshot) throws
    func update(_ id: String, state: StudyActivityState) async
    func end(_ id: String) async
}

// A serial chain prevents an older asynchronous update from overtaking pause/end.
// ActivityKit is intentionally outside all repository save transactions.
@MainActor final class StudyActivityCoordinator {
    private let driver: any StudyActivityDriver
    private var pending: Task<Void, Never>?
    private var lastRequest: Request?
    private struct Request: Equatable {
        let snapshot: StudyActivitySnapshot?
        let enabled: Bool
        let foreground: Bool
    }
    init(driver: any StudyActivityDriver) { self.driver = driver }

    func sync(_ snapshot: StudyActivitySnapshot?, enabled: Bool, foreground: Bool, reconcile: Bool = false) {
        let request = Request(snapshot: snapshot, enabled: enabled, foreground: foreground)
        guard reconcile || request != lastRequest else { return }
        lastRequest = request
        let previous = pending
        pending = Task { [driver] in
            await previous?.value
            let target = enabled && driver.authorized ? snapshot : nil
            let existing = driver.activities
            let matching = target.flatMap { target in existing.first { $0.sessionID == target.sessionID && $0.reusable } }
            for activity in existing where activity.id != matching?.id { await driver.end(activity.id) }
            guard let target else { return }
            if let matching { await driver.update(matching.id, state: target.state) }
            else if foreground {
                // Failed/OS-dismissed activities are retried only on a meaningful event.
                // Do not create a duplicate if an old activity has not disappeared yet.
                guard driver.activities.isEmpty else { return }
                try? driver.start(target)
            }
        }
    }
    func waitForSync() async { await pending?.value }

    static func system() -> StudyActivityCoordinator? {
        #if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
        return StudyActivityCoordinator(driver: SystemStudyActivityDriver())
        #else
        return nil
        #endif
    }
}

#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
@MainActor private final class SystemStudyActivityDriver: StudyActivityDriver {
    var authorized: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    var activities: [StudyActivityHandle] {
        Activity<StudyActivityAttributes>.activities.filter { $0.activityState != .dismissed }
            .map { StudyActivityHandle(id: $0.id, sessionID: $0.attributes.sessionID, reusable: $0.activityState == .active || $0.activityState == .stale) }
    }
    func start(_ snapshot: StudyActivitySnapshot) throws {
        _ = try Activity.request(attributes: StudyActivityAttributes(sessionID: snapshot.sessionID),
                                 content: content(snapshot.state), pushType: nil)
    }
    func update(_ id: String, state: StudyActivityState) async {
        guard let activity = Activity<StudyActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(content(state))
    }
    func end(_ id: String) async {
        guard let activity = Activity<StudyActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }
    private func content(_ state: StudyActivityState) -> ActivityContent<StudyActivityState> {
        // If the app is killed before delivering pause, never claim indefinitely
        // that learning is active. Stale rendering is a resume prompt, with no timer.
        ActivityContent(state: state, staleDate: state.paused ? nil : Date().addingTimeInterval(60))
    }
}
#endif
