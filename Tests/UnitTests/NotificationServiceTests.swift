import XCTest
@testable import AnkiIOS

@MainActor
final class NotificationServiceTests: XCTestCase {
    final class Center: LocalNotificationCenter {
        var status = NotificationPermission.unknown
        var requests = 0
        var permissionReads = 0
        var scheduled: [PlannedNotification] = []
        var deliveredIDs = Set<String>()
        var added = 0
        var blockNextAdd = false
        var gate: CheckedContinuation<Void, Never>?
        func permission() async -> NotificationPermission { permissionReads += 1; return status }
        func requestPermission() async throws -> Bool { requests += 1; status = .allowed; return true }
        func pending() async -> [PlannedNotification] { scheduled }
        func delivered() async -> Set<String> { deliveredIDs }
        func remove(_ ids: [String]) { scheduled.removeAll { ids.contains($0.id) } }
        func add(_ item: PlannedNotification) async throws {
            if blockNextAdd { blockNextAdd = false; await withCheckedContinuation { gate = $0 } }
            scheduled.removeAll { $0.id == item.id }; scheduled.append(item); added += 1
        }
    }
    func testTurningOffDuringInFlightAddCannotLeaveStaleReservation() async throws {
        let center = Center(); center.status = .allowed; center.blockNextAdd = true
        let service = NotificationService(center: center), now = Date(timeIntervalSince1970: 1_700_000_000)
        let cards = [QueueCard(id: UUID(), state: "review", due: now, createdAt: now, suspended: false)]
        let older = Task { try await service.reconcile(cards: cards, options: NotificationOptions(enabled: true), calendar: .current, now: now) }
        for _ in 0..<1000 where center.gate == nil { await Task.yield() }
        XCTAssertNotNil(center.gate)
        let newer = Task { try await service.reconcile(cards: cards, options: NotificationOptions(), calendar: .current, now: now) }
        for _ in 0..<10 { await Task.yield() }
        center.gate?.resume(); center.gate = nil
        _ = try await older.value; _ = try await newer.value
        XCTAssertTrue(center.scheduled.isEmpty); XCTAssertEqual(service.scheduledCount, 0)
    }
    func testOffForegroundDoesNotRequestPermissionAndEnableIsExplicit() async throws {
        let center = Center(), service = NotificationService(center: Center())
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await service.reconcile(cards: [], options: NotificationOptions(), calendar: .current, now: now)
        XCTAssertEqual((service.center as! Center).requests, 0)
        let enabled = NotificationService(center: center)
        let allowed = try await enabled.enablePermission()
        XCTAssertTrue(allowed); XCTAssertEqual(center.requests, 1)
        _ = try await enabled.enablePermission(); XCTAssertEqual(center.requests, 1)
        center.status = .denied
        let denied = try await enabled.enablePermission(); XCTAssertFalse(denied); XCTAssertEqual(center.requests, 1)
    }
    func testReconciliationIsIdempotentAndCompletionOffAndDenialCancel() async throws {
        let center = Center(); center.status = .allowed
        let service = NotificationService(center: center), now = Date(timeIntervalSince1970: 1_700_000_000)
        let cards = [QueueCard(id: UUID(), state: "review", due: now, createdAt: now, suspended: false)]
        let options = NotificationOptions(enabled: true)
        _ = try await service.reconcile(cards: cards, options: options, calendar: .current, now: now)
        XCTAssertFalse(center.scheduled.isEmpty); let count = center.added
        _ = try await service.reconcile(cards: cards, options: options, calendar: .current, now: now)
        XCTAssertEqual(center.added, count)
        _ = try await service.reconcile(cards: [], options: options, calendar: .current, now: now)
        XCTAssertTrue(center.scheduled.isEmpty)
        _ = try await service.reconcile(cards: cards, options: options, calendar: .current, now: now)
        center.status = .denied
        _ = try await service.reconcile(cards: cards, options: options, calendar: .current, now: now)
        XCTAssertTrue(center.scheduled.isEmpty)
        center.status = .allowed
        _ = try await service.reconcile(cards: cards, options: options, calendar: .current, now: now)
        _ = try await service.reconcile(cards: cards, options: NotificationOptions(), calendar: .current, now: now)
        XCTAssertTrue(center.scheduled.isEmpty)
    }
}
