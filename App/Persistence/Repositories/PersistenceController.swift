import Foundation
import SwiftData

enum PersistenceController {
    static func makeContainer(storeURL: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: Phase0Schema.self)
        let configuration: ModelConfiguration
        if let storeURL {
            configuration = ModelConfiguration("Phase0", schema: schema, url: storeURL,
                                               cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration("Phase0", schema: schema,
                                               isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

@MainActor
struct ProbeRepository {
    let context: ModelContext

    func saveVerification(now: Date, scheduler: ReviewScheduler) throws {
        let verification = try SchedulerVerification.run(now: now, scheduler: scheduler)
        let snapshot = try JSONEncoder().encode(verification.finalSnapshot)
        let transitions = try JSONEncoder().encode(verification.transitions)
        let due = try scheduler.summary(verification.finalSnapshot).dueDate
        let probe = Phase0Probe(createdAt: now, snapshotData: snapshot,
                                transitionsData: transitions, dueDate: due)
        context.autosaveEnabled = false
        context.insert(probe)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
