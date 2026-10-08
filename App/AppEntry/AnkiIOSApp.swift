import SwiftUI
import SwiftData

@main
struct AnkiIOSApp: App {
    var body: some Scene {
        WindowGroup { AppRootView() }
    }
}

struct AppRootView: View {
    @State private var container: ModelContainer?
    @State private var failure: String?

    var body: some View {
        Group {
            if let container {
                Phase0View().modelContainer(container)
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
            container = try PersistenceController.makeContainer(storeURL: storeURL)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}
