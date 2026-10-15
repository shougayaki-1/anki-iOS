import SwiftUI
import SwiftData
import UserNotifications
import Observation

@main
struct AnkiIOSApp: App {
    private let notificationDelegate = StudyNotificationDelegate()
    init() {
        PronunciationPractice.cleanAbandonedRecordings()
        UNUserNotificationCenter.current().delegate = notificationDelegate
        StudyAppShortcuts.updateAppShortcutParameters()
    }
    var body: some Scene {
        WindowGroup { AppRootView().tint(Color("AccentColor")) }
        #if targetEnvironment(macCatalyst)
        .commands {
            CommandGroup(after: .newItem) {
                Button("同じ学習ウィンドウを開く") {
                    UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil)
                }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("学習") {
                Button("復習を開始・再開") { ShortcutNavigation.shared.submit(.study(.review)) }
                Button("新規学習を開始・再開") { ShortcutNavigation.shared.submit(.study(.new)) }
                Button("学習記録を表示") { ShortcutNavigation.shared.submit(.progress) }
            }
        }
        #endif
    }
}

struct AppRootView: View {
    @State private var workspace = AppWorkspace.forWindow()
    @State private var windowID = UUID()
    @State private var recovering = false

    var body: some View {
        Group {
            if let container = workspace.container {
                if workspace.diagnosticOnly {
                    Phase0View().modelContainer(container)
                } else if let store = workspace.store {
                    MainTabs(store: store, probeContainer: container, sceneActivity: { workspace.sceneChanged(id: windowID, active: $0) })
                }
            } else if let failure = workspace.failure {
                ContentUnavailableView {
                    Label("保存領域を開けません", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(failure)
                } actions: {
                    Button("再試行", action: workspace.load)
                    Button("バックアップから救済") { recovering = true }
                }
            } else {
                ProgressView("保存領域を読み込み中")
            }
        }
        .task { if workspace.container == nil { workspace.load() } }
        .sheet(isPresented: $recovering) {
            BackupRecoveryView(location: workspace.storageLocation, recover: workspace.recover)
        }
    }

}

// One actor and one repository own the Mac's learning state across windows.
// iPhone/iPad keep the same owner too when the OS opens another scene.
@MainActor @Observable final class AppWorkspace {
    static let shared = AppWorkspace()
    static func forWindow() -> AppWorkspace { shared }
    var container: ModelContainer?
    var failure: String?
    var store: StudyStore?
    var diagnosticOnly = false
    private var activity = WindowActivity()
    var storageLocation = StudyStorageLocation(canonicalStore: StudyStorageLocation.defaultStore)
    private var recoveryMediaStore = MediaStore()
    func recover(_ backup: ValidatedBackup) throws -> BackupRestoreOutcome {
        let restored = try BackupService.restore(backup, location: storageLocation, mediaStore: recoveryMediaStore, now: Date())
        let summary = try? BackupRestoreSummary(context: ModelContext(restored))
        var warning: String?
        // The commit already happened: do not call load() and potentially repeat migration of the broken store.
        do {
            store = try StudyStore(container: restored, mediaStore: recoveryMediaStore, storageLocation: storageLocation,
                                   widgetSnapshots: WidgetSnapshotPublisher(file: .shared()))
            container = (try? PersistenceController.makeContainer()) ?? restored
            diagnosticOnly = false; failure = nil
            store?.scheduleNotifications()
        } catch {
            // Successful restoration remains active; retry opens it next launch.
            warning = "復元は保存済みです。再試行して新しい保存領域を開いてください。\n" + error.localizedDescription
            failure = warning
        }
        return BackupRestoreOutcome(summary: summary, warning: warning)
    }

    func sceneChanged(id: UUID, active: Bool) {
        let wasActive = activity.isActive
        activity.set(id: id, active: active)
        if wasActive != activity.isActive { store?.sceneChanged(active: activity.isActive) }
    }

    func load() {
        let interval = PerformanceProbe.begin("Workspace.load")
        defer { PerformanceProbe.end(interval) }
        do {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-study-test-accessibility") { UITestFixtures.configureAccessibilityScene() }
            else if ProcessInfo.processInfo.arguments.contains("-study-test-dark") { UITestFixtures.configureAccessibilityScene(largeText: false) }
            #endif
            // Each UI test gets its own on-disk store, reused across process restarts.
            var storeURL: URL?
            #if DEBUG
            if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-phase0-test-store"),
               ProcessInfo.processInfo.arguments.count > index + 1 {
                let name = ProcessInfo.processInfo.arguments[index + 1]
                let directory = URL.applicationSupportDirectory.appendingPathComponent("UITestStores")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                storeURL = directory.appendingPathComponent(name).appendingPathExtension("store")
            }
            #endif
            let probe = try PersistenceController.makeContainer(storeURL: storeURL)
            #if DEBUG
            diagnosticOnly = ProcessInfo.processInfo.arguments.contains("-phase0-test-store")
            #endif
            if !diagnosticOnly {
                var studyURL: URL?
                var mediaStore = MediaStore()
                var notifications = NotificationService()
                #if DEBUG
                let args = ProcessInfo.processInfo.arguments
                if let index = args.firstIndex(of: "-study-test-store"), args.count > index + 1 {
                    let directory = URL.applicationSupportDirectory.appendingPathComponent("UITestStores")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    studyURL = directory.appendingPathComponent(args[index + 1]).appendingPathExtension("store")
                    mediaStore = MediaStore(root: URL.applicationSupportDirectory.appendingPathComponent("UITestMedia").appendingPathComponent(args[index + 1]))
                    notifications = NotificationService(identifierPrefix: "review-test-\(args[index + 1])-")
                    if args.contains("-study-test-file-fixtures") {
                        try UITestFixtures.prepare(name: args[index + 1])
                    }
                }
                #endif
                storageLocation = StudyStorageLocation(canonicalStore: studyURL ?? StudyStorageLocation.defaultStore)
                recoveryMediaStore = mediaStore
                store = try StudyStore(container: PersistenceController.makeStudyContainer(storeURL: studyURL, mediaStore: mediaStore), mediaStore: mediaStore, storageLocation: StudyStorageLocation(canonicalStore: studyURL ?? StudyStorageLocation.defaultStore), notifications: notifications, widgetSnapshots: (studyURL == nil || ProcessInfo.processInfo.arguments.contains("-study-test-widget")) ? WidgetSnapshotPublisher(file: .shared()) : nil)
                #if DEBUG
                if studyURL != nil, args.contains("-study-test-deck-update"), let store,
                   let index = args.firstIndex(of: "-study-test-store"), args.count > index + 1 {
                    try UITestFixtures.populateDeckUpdate(store, name: args[index + 1])
                }
                if studyURL != nil, let index = args.firstIndex(of: "-study-test-garden"), args.count > index + 1, let store,
                   let name = args.firstIndex(of: "-study-test-store"), args.count > name + 1, UUID(uuidString: args[name + 1]) != nil {
                    try UITestFixtures.populateGarden(store, scenario: args[index + 1])
                }
                if studyURL != nil, args.contains("-study-test-dashboard"), let store {
                    try UITestFixtures.populateDashboard(store)
                }
                if studyURL != nil, args.contains("-study-test-celebration-flow"), let store {
                    try UITestFixtures.populateCelebrationFlow(store)
                }
                if studyURL != nil, let index = args.firstIndex(of: "-study-test-celebration"), args.count > index + 1, let store {
                    store.celebration = UITestFixtures.celebration(args[index + 1])
                }
                if studyURL != nil, let index = args.firstIndex(of: "-study-test-recommendation"), args.count > index + 1, let store {
                    try UITestFixtures.populateHomeRecommendation(store, scenario: args[index + 1])
                }
                if studyURL != nil, args.contains("-study-test-widget"), let store {
                    try UITestFixtures.populateDueNotification(store.repository, now: store.clock())
                    try store.reload()
                }
                if studyURL != nil, args.contains("-study-test-library-tree"), let store {
                    try UITestFixtures.populateLibraryTree(store.repository, now: store.clock())
                    try store.reload()
                }
                if studyURL != nil, args.contains("-study-test-ordering"), let store {
                    try UITestFixtures.populateOrdering(store.repository, now: store.clock())
                    try store.reload()
                }
                if studyURL != nil, args.contains("-study-test-hints"), let store {
                    try UITestFixtures.populateHints(store.repository, now: store.clock())
                    try store.reload()
                }
                if studyURL != nil, args.contains("-study-test-new-review-due"), let store {
                    try UITestFixtures.populateNewReviewDue(store)
                }
                if studyURL != nil, (args.contains("-study-test-scale") || args.contains("-study-test-scale-basic")), let store {
                    try UITestFixtures.populateScale(store.repository, now: store.clock(), basic: args.contains("-study-test-scale-basic"), multipleDecks: args.contains("-study-performance"))
                    if args.contains("-study-test-exam-scale"), try store.repository.options().examPlans == nil {
                        let date = Calendar.current.date(byAdding: .day, value: 30, to: store.clock())!
                        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
                        try store.repository.saveExamPlan(ExamPlan(name: "性能確認", year: parts.year!, month: parts.month!, day: parts.day!, scope: LearningScope()))
                    }
                    try store.reload()
                }
                if studyURL != nil, args.contains("-study-test-custom-media"), let store {
                    try UITestFixtures.populateCustomMedia(store.repository, now: store.clock()); try store.reload()
                }
                if studyURL != nil, args.contains("-study-test-custom-scale"), let store {
                    try UITestFixtures.populateCustomScale(store.repository, now: store.clock()); try store.reload()
                }
                if studyURL != nil, args.contains("-study-test-tag-filters"), let store {
                    try UITestFixtures.populateTagFilters(store.repository, now: store.clock())
                    try store.reload()
                }
                if studyURL != nil, args.contains("-study-test-home-filters"), let store {
                    try UITestFixtures.populateHomeFilters(store.repository, now: store.clock())
                    try store.reload()
                }
                if studyURL != nil, args.contains("-study-test-notification-due"), let store {
                    try UITestFixtures.populateDueNotification(store.repository, now: store.clock())
                    try store.reload()
                }
                if studyURL != nil, args.contains("-study-test-numeric-mask"), let store {
                    try UITestFixtures.populateMask(store.repository, now: store.clock())
                    try store.reload()
                }
                // UI tests can exercise the navigation adapter without launching Siri.
                if studyURL != nil, let index = args.firstIndex(of: "-study-test-shortcut"),
                   args.count > index + 1 {
                    switch args[index + 1] {
                    case "review": ShortcutNavigation.shared.submit(.study(.review))
                    case "new": ShortcutNavigation.shared.submit(.study(.new))
                    case "progress": ShortcutNavigation.shared.submit(.progress)
                    case "deck:first":
                        if let store, let first = try? store.repository.decks().first {
                            ShortcutNavigation.shared.submit(.deck(first.id))
                        }
                    default:
                        if args[index + 1].hasPrefix("deck:"),
                           let id = UUID(uuidString: String(args[index + 1].dropFirst(5))) {
                            ShortcutNavigation.shared.submit(.deck(id))
                        }
                    }
                }
                #endif
            }
            container = probe
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

struct WindowActivity {
    private var active = Set<UUID>()
    var isActive: Bool { !active.isEmpty }
    mutating func set(id: UUID, active value: Bool) {
        if value { active.insert(id) } else { active.remove(id) }
    }
}
