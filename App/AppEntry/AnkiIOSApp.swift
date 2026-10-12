import SwiftUI
import SwiftData
import UserNotifications
import Observation

@main
struct AnkiIOSApp: App {
    private let notificationDelegate = StudyNotificationDelegate()
    init() {
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
                }
            } else {
                ProgressView("保存領域を読み込み中")
            }
        }
        .task { if workspace.container == nil { workspace.load() } }
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

    func sceneChanged(id: UUID, active: Bool) {
        let wasActive = activity.isActive
        activity.set(id: id, active: active)
        if wasActive != activity.isActive { store?.sceneChanged(active: activity.isActive) }
    }

    func load() {
        do {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-study-test-accessibility") { UITestFixtures.configureAccessibilityScene() }
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
                store = try StudyStore(container: PersistenceController.makeStudyContainer(storeURL: studyURL), mediaStore: mediaStore, storageLocation: StudyStorageLocation(canonicalStore: studyURL ?? StudyStorageLocation.defaultStore), notifications: notifications, widgetSnapshots: (studyURL == nil || ProcessInfo.processInfo.arguments.contains("-study-test-widget")) ? WidgetSnapshotPublisher(file: .shared()) : nil)
                #if DEBUG
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
                if studyURL != nil, args.contains("-study-test-scale"), let store {
                    try UITestFixtures.populateScale(store.repository, now: store.clock())
                    try store.reload()
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
