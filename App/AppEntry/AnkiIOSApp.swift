import SwiftUI
import SwiftData
import UserNotifications

@main
struct AnkiIOSApp: App {
    private let notificationDelegate = StudyNotificationDelegate()
    init() { UNUserNotificationCenter.current().delegate = notificationDelegate }
    var body: some Scene {
        WindowGroup { AppRootView() }
    }
}

struct AppRootView: View {
    @State private var container: ModelContainer?
    @State private var failure: String?
    @State private var store: StudyStore?
    @State private var diagnosticOnly = false

    var body: some View {
        Group {
            if let container {
                if diagnosticOnly {
                    Phase0View().modelContainer(container)
                } else if let store {
                    MainTabs(store: store, probeContainer: container)
                }
            } else if let failure {
                ContentUnavailableView {
                    Label("保存領域を開けません", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(failure)
                } actions: {
                    Button("再試行", action: load)
                }
            } else {
                ProgressView("保存領域を読み込み中")
            }
        }
        .task { if container == nil { load() } }
    }

    private func load() {
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
                store = try StudyStore(container: PersistenceController.makeStudyContainer(storeURL: studyURL), mediaStore: mediaStore, storageLocation: StudyStorageLocation(canonicalStore: studyURL ?? StudyStorageLocation.defaultStore), notifications: notifications)
                #if DEBUG
                if studyURL != nil, args.contains("-study-test-scale"), let store {
                    try UITestFixtures.populateScale(store.repository, now: store.clock())
                    try store.reload()
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
