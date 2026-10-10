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
    @State private var adding = false
    @State private var showingHelp = false

    private func start(_ mode: StudyMode) {
        if store.review?.card != nil { replacingWith = mode }
        else { store.start(mode) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LearningScopeSelector(store: store) { editingScope = true }
                }
                ReviewHeroSection(count: store.counts.due) { start(.review) }
                if let review = store.review {
                    Section {
                        Button { store.resume() } label: {
                            Label("続きから再開（\(review.mode.title)）", systemImage: "play.circle")
                                .padding(.vertical, 6)
                        }.accessibilityIdentifier("resumeStudy")
                    }
                }
                OtherStudyModesSection(count: store.counts.newRemaining, start: start)
                DailyProgressSection(count: store.counts.learnedToday, goal: store.settings.dailyGoal)
                if store.notes.isEmpty {
                    Section { Text("右上の＋から最初のカードを登録しましょう。") }
                }
            }
            .navigationTitle("ホーム")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("学習モードの説明", systemImage: "questionmark.circle") { showingHelp = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("カード追加", systemImage: "plus") { adding = true }.accessibilityIdentifier("addHomeNote")
                }
            }
            .sheet(isPresented: $editingScope) { LearningScopeSheet(store: store, initial: store.scope) }
            .sheet(isPresented: $adding) { NoteEditorView(store: store, item: nil) }
            .sheet(isPresented: $showingHelp) {
                NavigationStack {
                    List {
                        ForEach(StudyMode.allCases) { mode in
                            Section(mode.title) { Text(mode.explanation) }
                        }
                        Section { Text("新規学習の短期復習も同じセッションで出題します。復習＋新規は復習3枚に新規1枚を基本に組み合わせます。新規枠は全デッキ・全モード共通です。") }
                    }.navigationTitle("学習モード")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { showingHelp = false } } }
                }
            }
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

struct LearningScopeSelector: View {
    let store: StudyStore
    let edit: () -> Void
    var body: some View {
        Button(action: edit) {
            HStack {
                Label("学習対象", systemImage: "line.3.horizontal.decrease")
                Spacer()
                Text(summary).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption)
            }.padding(.vertical, 4)
        }.accessibilityIdentifier("openStudyFilter")
            .accessibilityLabel("学習対象、\(summary)")
            .accessibilityHint("デッキとタグを変更します")
    }
    private var summary: String {
        let deck = store.decks.first { $0.id == store.scope.deckID }?.name ?? "全デッキ"
        let tags = store.tags.filter { store.scope.tagIDs.contains($0.id) }.map(\.name)
        return tags.isEmpty ? deck : "\(deck) · \(tags.joined(separator: "、"))"
    }
}

struct ReviewHeroSection: View {
    let count: Int
    let start: () -> Void
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("いま復習できるカード").font(.headline)
                Text("\(count)枚").font(.largeTitle.bold()).accessibilityIdentifier("dueCount")
                Button(action: start) {
                    Label(StudyMode.review.title, systemImage: "arrow.clockwise")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }.buttonStyle(.borderedProminent).tint(Color("PrimaryAction"))
                    .accessibilityIdentifier("start-review")
                Text(StudyMode.review.explanation).font(.footnote).foregroundStyle(.secondary)
            }.padding(.vertical, 4)
        }
    }
}

struct OtherStudyModesSection: View {
    let count: Int
    let start: (StudyMode) -> Void
    var body: some View {
        Section("ほかの学習") {
            ForEach([StudyMode.new, .mixed]) { mode in
                Button { start(mode) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(mode.title).font(.headline)
                            Spacer()
                            if mode == .new { Text("\(count)枚").accessibilityIdentifier("newCount") }
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        Text(mode.explanation).font(.footnote).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }.accessibilityIdentifier("start-\(mode.rawValue)")
            }
        }
    }
}

struct DailyProgressSection: View {
    let count: Int
    let goal: Int?
    var body: some View {
        Section("今日の学習（全デッキ）") {
            if let goal {
                ProgressView(value: Double(min(goal, count)), total: Double(goal)) {
                    Text("\(count) / \(goal)枚")
                }.accessibilityIdentifier("goalProgress")
                if count >= goal { Text("目標達成！引き続き学習できます。") }
            } else { Text("今日の学習: \(count)枚") }
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
