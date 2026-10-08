import SwiftUI
import SwiftData

struct MainTabs: View {
    @Bindable var store: StudyStore
    let probeContainer: ModelContainer
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            HomeView(store: store).tabItem { Label("ホーム", systemImage: "house") }
            LibraryView(store: store).tabItem { Label("ライブラリ", systemImage: "books.vertical") }
            NavigationStack {
                List {
                    Section("今日の記録") {
                        LabeledContent("学習カード", value: "\(store.counts.learnedToday)枚")
                        LabeledContent("回答回数", value: "\(store.counts.answerCount)回").accessibilityIdentifier("todayAnswerCount")
                        Text("学習日の切替は午前\(store.settings.dayStartHour)時です。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.navigationTitle("記録")
            }.tabItem { Label("記録", systemImage: "chart.bar") }
            SettingsView(store: store, probeContainer: probeContainer)
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
        .fullScreenCover(isPresented: $store.showingReview) { ReviewView(store: store) }
        .alert("処理に失敗しました", isPresented: Binding(
            get: { store.failure != nil }, set: { if !$0 { store.failure = nil } }
        )) { Button("閉じる", role: .cancel) { store.failure = nil } }
        message: { Text((store.failure ?? "") + "\n変更は確定されていません。操作をもう一度お試しください。") }
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

    var body: some View {
        NavigationStack {
            List {
                Section("今日の学習") {
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
