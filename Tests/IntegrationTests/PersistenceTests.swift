import XCTest
import SwiftData
@testable import AnkiIOS

@MainActor
final class PersistenceTests: XCTestCase {
    func testDiskStoreReopensWithIdenticalIDStateAndHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let scheduler = try ReviewScheduler()
        let expected = try writeStore(url: url, now: now, scheduler: scheduler)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let reopened = try PersistenceController.makeContainer(storeURL: url)
        let context = ModelContext(reopened)
        let probes = try context.fetch(FetchDescriptor<Phase0Probe>())
        XCTAssertEqual(probes.count, 1)
        let probe = try XCTUnwrap(probes.first)
        XCTAssertEqual(probe.id, expected.id)
        XCTAssertEqual(probe.createdAt, now)
        XCTAssertEqual(probe.snapshotData, expected.snapshot)
        XCTAssertEqual(probe.transitionsData, expected.transitions)
        let snapshot = try JSONDecoder().decode(SchedulerSnapshot.self, from: probe.snapshotData)
        let history = try JSONDecoder().decode([ReviewTransition].self, from: probe.transitionsData)
        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(snapshot, history.last?.after)
        XCTAssertEqual(probe.dueDate, try scheduler.summary(snapshot).dueDate)
        let continued = try scheduler.review(snapshot, grade: .good, now: probe.dueDate)
        XCTAssertEqual(try scheduler.summary(continued.after).repetitions, 5)
    }

    private func writeStore(url: URL, now: Date, scheduler: ReviewScheduler) throws
        -> (id: UUID, snapshot: Data, transitions: Data) {
        let container = try PersistenceController.makeContainer(storeURL: url)
        let context = ModelContext(container)
        try ProbeRepository(context: context).saveVerification(now: now, scheduler: scheduler)
        let probe = try XCTUnwrap(context.fetch(FetchDescriptor<Phase0Probe>()).first)
        return (probe.id, probe.snapshotData, probe.transitionsData)
    }
}
