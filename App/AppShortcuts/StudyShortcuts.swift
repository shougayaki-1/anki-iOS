import Foundation
import AppIntents
import Observation

// Commands are navigation requests, not background changes to learning state.
enum ShortcutRequest: Codable, Equatable {
    case study(StudyMode)
    case progress
    case deck(UUID)
}

@MainActor @Observable
final class ShortcutNavigation {
    static let shared = ShortcutNavigation()
    private static let key = "appShortcuts.pendingNavigation.v1"
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var pending: ShortcutRequest?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pending = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(ShortcutRequest.self, from: $0) }
    }

    func submit(_ request: ShortcutRequest) {
        if let encoded = try? JSONEncoder().encode(request) { defaults.set(encoded, forKey: Self.key) }
        pending = request
    }

    func syncFromDisk() {
        if let data = defaults.data(forKey: Self.key),
           let request = try? JSONDecoder().decode(ShortcutRequest.self, from: data) {
            pending = request
        }
    }

    func take() -> ShortcutRequest? {
        syncFromDisk()
        let request = pending
        pending = nil
        defaults.removeObject(forKey: Self.key)
        return request
    }
}

// Existing sessions always win; replacing them requires a home-screen confirmation.
enum ShortcutStudyDecision: Equatable {
    case start(StudyMode), resume, showExistingSession, unavailable

    static func resolve(mode: StudyMode, sessionExists: Bool, canResume: Bool, canStart: Bool) -> Self {
        if sessionExists { return canResume ? .resume : .showExistingSession }
        return canStart ? .start(mode) : .unavailable
    }
}

struct ShortcutDeckEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "デッキ"
    static var defaultQuery = ShortcutDeckQuery()

    let id: String
    let path: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(path)") }
}

// Uses existing UUIDs and the repository's hierarchy-path calculation, not the deck tree UI.
@MainActor
enum ShortcutDeckDirectory {
    static func read(from repository: StudyRepository) throws -> [ShortcutDeckEntity] {
        try repository.decks().map {
            ShortcutDeckEntity(id: $0.id.uuidString, path: try repository.deckPath($0.id))
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func readLocal() throws -> [ShortcutDeckEntity] {
        let container = try PersistenceController.makeStudyContainer()
        return try read(from: StudyRepository(container: container))
    }

    static func matching(_ identifiers: [String], in available: [ShortcutDeckEntity]) -> [ShortcutDeckEntity] {
        let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        return identifiers.compactMap { byID[$0] }
    }
}

struct ShortcutDeckQuery: EntityStringQuery {
    func entities(for identifiers: [ShortcutDeckEntity.ID]) async throws -> [ShortcutDeckEntity] {
        try await MainActor.run { ShortcutDeckDirectory.matching(identifiers, in: try ShortcutDeckDirectory.readLocal()) }
    }

    func suggestedEntities() async throws -> [ShortcutDeckEntity] {
        try await MainActor.run { try ShortcutDeckDirectory.readLocal() }
    }

    // Spoken deck names can be resolved without relying on the visual #40 tree.
    // A hierarchical full path disambiguates identical leaf names.
    func entities(matching string: String) async throws -> [ShortcutDeckEntity] {
        try await MainActor.run {
            let decks = try ShortcutDeckDirectory.readLocal()
            return decks.filter { $0.path.localizedStandardContains(string) }
        }
    }
}

struct StartReviewShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "復習を開始"
    static let description = IntentDescription("アプリを開き、現在の学習対象の復習を始めます。中断中の学習を優先します。")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        ShortcutNavigation.shared.submit(.study(.review))
        return .result()
    }
}

struct StartNewStudyShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "新規学習を開始"
    static let description = IntentDescription("現在の学習対象と新規学習上限に従って学習を始めます。")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        ShortcutNavigation.shared.submit(.study(.new))
        return .result()
    }
}

struct ShowStudyProgressShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "学習進捗を見る"
    static let description = IntentDescription("今日の学習カード枚数と回答回数を記録画面で確認します。")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        ShortcutNavigation.shared.submit(.progress)
        return .result()
    }
}

struct OpenStudyDeckShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "指定デッキを開く"
    static let description = IntentDescription("指定したデッキと下位デッキのカード一覧を開きます。")
    static let openAppWhenRun = true

    @Parameter(title: "デッキ", description: "開くデッキを選択")
    var deck: ShortcutDeckEntity

    @MainActor func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: deck.id),
              try ShortcutDeckDirectory.readLocal().contains(where: { $0.id == id.uuidString }) else {
            throw StudyError.missingRecord
        }
        ShortcutNavigation.shared.submit(.deck(id))
        return .result()
    }
}

struct StudyAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartReviewShortcutIntent(),
                    phrases: ["\(.applicationName)で復習を開始", "\(.applicationName)の復習を始める"],
                    shortTitle: "復習を開始", systemImageName: "arrow.clockwise")
        AppShortcut(intent: StartNewStudyShortcutIntent(),
                    phrases: ["\(.applicationName)で新規学習を開始", "\(.applicationName)で新しく覚える"],
                    shortTitle: "新規学習を開始", systemImageName: "plus.rectangle.on.rectangle")
        AppShortcut(intent: ShowStudyProgressShortcutIntent(),
                    phrases: ["\(.applicationName)の学習進捗を見る", "\(.applicationName)の記録を開く"],
                    shortTitle: "学習進捗を見る", systemImageName: "chart.bar")
        AppShortcut(intent: OpenStudyDeckShortcutIntent(),
                    phrases: ["\(.applicationName)で指定デッキを開く", "\(.applicationName)のデッキを開く"],
                    shortTitle: "指定デッキを開く", systemImageName: "books.vertical")
    }
}
