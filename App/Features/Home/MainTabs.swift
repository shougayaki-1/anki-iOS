import SwiftUI
import SwiftData

struct MainTabs: View {
    @Bindable var store: StudyStore
    let probeContainer: ModelContainer
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $store.selectedTab) {
            HomeView(store: store).tabItem { Label("ホーム", systemImage: "house") }.tag(0)
            LibraryView(store: store).tabItem { Label("ライブラリ", systemImage: "books.vertical") }.tag(1)
            StatisticsView(store: store).tabItem { Label("記録", systemImage: "chart.bar") }.tag(2)
            SettingsView(store: store, probeContainer: probeContainer)
                .tabItem { Label("設定", systemImage: "gearshape") }.tag(3)
        }
        .fullScreenCover(isPresented: $store.showingReview) { ReviewView(store: store) }
        .alert("処理に失敗しました", isPresented: Binding(
            get: { store.failure != nil }, set: { if !$0 { store.failure = nil } }
        )) { Button("閉じる", role: .cancel) { store.failure = nil } }
        message: { Text(store.failure ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .studyNotificationOpened)) { _ in
            store.pause(); store.selectedTab = 0
        }
        .onChange(of: scenePhase) { _, phase in
            store.perform {
                try store.repository.setSessionActive(phase == .active && store.showingReview, now: store.clock())
            }
        }
    }
}

struct HomeView: View {
    @Bindable var store: StudyStore
    @State private var replacingWith: StudyMode?
    @State private var editingScope = false

    var body: some View {
        NavigationStack {
            List {
                Section("学習対象") {
                    Button("学習対象を変更") { editingScope = true }
                        .accessibilityIdentifier("openStudyFilter")
                }
                Section("今日の学習（全デッキ）") {
                    LabeledContent("復習待ち", value: "\(store.counts.due)枚").accessibilityIdentifier("dueCount")
                    LabeledContent("今日の新規残数", value: "\(store.counts.newRemaining)枚")
                        .accessibilityIdentifier("newCount")
                    LabeledContent("未学習カード", value: "\(store.counts.totalNew)枚")
                    if let goal = store.settings.dailyGoal {
                        ProgressView(value: Double(min(goal, store.counts.learnedToday)), total: Double(goal)) {
                            Text("学習目標 \(store.counts.learnedToday) / \(goal)枚")
                        }.accessibilityIdentifier("goalProgress")
                        if store.counts.learnedToday >= goal { Text("目標達成！引き続き学習できます。") }
                    } else {
                        Text("今日の学習: \(store.counts.learnedToday)枚")
                    }
                }
                if store.review != nil {
                    Section {
                        Button("中断した学習を再開", action: store.resume).accessibilityIdentifier("resumeStudy")
                    }
                }
                Section {
                    ForEach(StudyMode.allCases) { mode in
                        Button(mode.title) {
                            if store.review?.card != nil { replacingWith = mode }
                            else { store.start(mode) }
                        }.accessibilityIdentifier("start-\(mode.rawValue)")
                    }
                } footer: {
                    Text("復習は枚数無制限。新規枠は3つのモードで共通です。")
                }
                if store.notes.isEmpty {
                    Section { Text("ライブラリの＋から最初のカードを登録しましょう。") }
                }
            }
            .navigationTitle("ホーム")
            .sheet(isPresented: $editingScope) { LearningScopeSheet(store: store, initial: store.scope) }
            .confirmationDialog("中断中の学習を新しいモードに切り替えますか？",
                                isPresented: Binding(get: { replacingWith != nil }, set: { if !$0 { replacingWith = nil } })) {
                if let mode = replacingWith {
                    Button("\(mode.title)へ切り替える") { replacingWith = nil; store.start(mode) }
                }
                Button("キャンセル", role: .cancel) { replacingWith = nil }
            } message: { Text("未確定の回答下書きは破棄されます。確定済みの学習履歴は残ります。") }
            .task {
                while !Task.isCancelled {
                    store.perform { }
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }
    }
}

struct LearningScopeSheet: View {
    @Bindable var store: StudyStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LearningScope

    init(store: StudyStore, initial: LearningScope) {
        self.store = store; _draft = State(initialValue: initial)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("デッキ（子孫を含む）") {
                    Picker("デッキ", selection: $draft.deckID) {
                        Text("すべて").tag(UUID?.none)
                        ForEach(store.decks) { Text($0.name).tag(Optional($0.id)) }
                    }.accessibilityIdentifier("studyDeckPicker")
                }
                Section("タグ（選択したすべてを含む）") {
                    ForEach(store.tags) { tag in
                        Toggle(tag.name, isOn: Binding(get: { draft.tagIDs.contains(tag.id) }, set: { selected in
                            if selected { draft.tagIDs.append(tag.id) }
                            else { draft.tagIDs.removeAll { $0 == tag.id } }
                        })).accessibilityIdentifier("studyTag-\(tag.name)")
                    }
                }
                Button("リセット") { draft = LearningScope() }.accessibilityIdentifier("resetStudyFilter")
            }
            .navigationTitle("学習対象")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }.accessibilityIdentifier("cancelStudyFilter")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("適用") { if store.applyScope(draft) { dismiss() } }.accessibilityIdentifier("applyStudyFilter")
                }
            }
        }
    }
}
