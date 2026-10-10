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
        .onChange(of: store.selectedTab) { _, tab in
            if tab == 0 { store.refreshHome() }
            if tab == 2 { store.refreshHome(); store.refreshStatistics() }
        }
        .onChange(of: scenePhase) { _, phase in
            store.sceneChanged(active: phase == .active)
        }
    }
}

struct HomeView: View {
    @Bindable var store: StudyStore
    @State private var replacingWith: StudyMode?
    @State private var editingScope = false
    @State private var adding = false
    @State private var showingHelp = false
    @Environment(\.scenePhase) private var scenePhase

    private func start(_ mode: StudyMode) {
        if store.review != nil { replacingWith = mode }
        else { store.start(mode) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LearningScopeSelector(store: store) { editingScope = true }
                }
                if let error = store.homeFailure {
                    Section {
                        Label("学習情報を読み込めません", systemImage: "exclamationmark.triangle")
                        Text(error).font(.footnote)
                        Button("再試行") { store.perform { } }.accessibilityIdentifier("retryHome")
                    }
                } else if !store.hasCards {
                    Section {
                        Text("最初のカードを登録しましょう。")
                        Button("カードを追加する", systemImage: "plus") { adding = true }
                            .accessibilityIdentifier("addFirstHomeNote")
                    }
                } else {
                    ReviewHeroSection(count: store.counts.due, enabled: store.canStart(.review),
                                      elsewhere: store.globalCounts.due > 0) { start(.review) }
                }
                if let review = store.review {
                    Section {
                        Button { store.resume() } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("続きから再開").fixedSize(horizontal: false, vertical: true)
                                Text(review.mode.title).font(.subheadline).foregroundStyle(Color("SecondaryText"))
                                    .fixedSize(horizontal: false, vertical: true)
                            }.padding(.vertical, 6)
                        }.accessibilityIdentifier("resumeStudy")
                    }
                }
                if store.homeFailure == nil, let next = store.nextShortDue, store.counts.due == 0 {
                    Section {
                        Text("次の短期復習: \(next.formatted(date: .omitted, time: .shortened))")
                            .accessibilityIdentifier("nextShortReview")
                        Text("待機中のカードがあります。期限になると復習できます。")
                            .font(.footnote).foregroundStyle(Color("SecondaryText"))
                    }
                }
                if store.homeFailure == nil {
                    OtherStudyModesSection(store: store, start: start)
                    DailyProgressSection(count: store.counts.learnedToday, goal: store.settings.dailyGoal)
                }
                if store.homeFailure == nil && store.hasCards && !store.canStart(.mixed) {
                    Section {
                        Text("今はこの条件で学習できるカードがありません。")
                        Button("学習対象を変更") { editingScope = true }
                    }
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
                    if store.selectedTab == 0 && !store.showingReview && scenePhase == .active { store.refreshHome() }
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }
    }
}

struct LearningScopeSelector: View {
    let store: StudyStore
    let edit: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Button(action: edit) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("学習対象").fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if !typeSize.isAccessibilitySize {
                        Text(summary).foregroundStyle(Color("SecondaryText")).lineLimit(1)
                    }
                    Image(systemName: "chevron.down").font(.caption)
                }
                if typeSize.isAccessibilitySize {
                    Text(summary).foregroundStyle(Color("SecondaryText")).fixedSize(horizontal: false, vertical: true)
                }
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
    let enabled: Bool
    let elsewhere: Bool
    let start: () -> Void
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("いま復習できるカード").font(.headline)
                Text("\(count)枚").font(.largeTitle.bold()).accessibilityIdentifier("dueCount")
                    .accessibilityLabel("復習待ち、絞り込み後、\(String(count))枚")
                Button(action: start) {
                    Text(StudyMode.review.title).font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }.buttonStyle(.borderedProminent).tint(Color("PrimaryAction")).foregroundStyle(.white)
                    .accessibilityIdentifier("start-review").disabled(!enabled)
                if count == 0 {
                    Text("今は復習するカードがありません。")
                    if elsewhere { Text("ほかの学習対象に復習があります。") }
                }
                Text(StudyMode.review.explanation).font(.footnote).foregroundStyle(Color("SecondaryText"))
            }.padding(.vertical, 4)
        }
    }
}

struct OtherStudyModesSection: View {
    let store: StudyStore
    let start: (StudyMode) -> Void
    var body: some View {
        Section {
            ForEach([StudyMode.new, .mixed]) { mode in
                Button { start(mode) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(mode.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if mode == .new { Text("\(store.counts.newRemaining)枚").accessibilityIdentifier("newCount") }
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        Text(mode == .new ? mode.explanation : store.mixedAvailabilityMessage)
                            .font(.footnote).foregroundStyle(Color("SecondaryText"))
                    }.padding(.vertical, 6)
                }.accessibilityIdentifier("start-\(mode.rawValue)").disabled(!store.canStart(mode))
                    .accessibilityHint(mode == .new ? store.newAvailabilityMessage : store.mixedAvailabilityMessage)
                if mode == .new { Text(store.newAvailabilityMessage).font(.footnote).foregroundStyle(Color("SecondaryText")) }
            }
        } header: { Text("ほかの学習").foregroundStyle(Color("SecondaryText")) }
    }
}

struct DailyProgressSection: View {
    let count: Int
    let goal: Int?
    var body: some View {
        Section {
            if let goal {
                ProgressView(value: Double(min(goal, count)), total: Double(goal)) {
                    Text("\(count) / \(goal)枚")
                }.accessibilityIdentifier("goalProgress")
                    .accessibilityLabel("今日の学習、全デッキ、ユニークカード")
                    .accessibilityValue("\(count)枚、目標\(goal)枚")
                if count >= goal { Text("目標達成！引き続き学習できます。") }
            } else { Text("今日の学習: \(count)枚") }
        } header: { Text("今日の学習（全デッキ）").foregroundStyle(Color("SecondaryText")) }
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
