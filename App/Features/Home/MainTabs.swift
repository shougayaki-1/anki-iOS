import SwiftUI
import SwiftData

struct MainTabs: View {
    @Bindable var store: StudyStore
    let probeContainer: ModelContainer
    @Environment(\.scenePhase) private var scenePhase
    @State private var shortcutNavigation = ShortcutNavigation.shared
    @State private var shortcutDeck: ShortcutDeckDestination?
    @State private var shortcutNotice: String?

    var body: some View {
        TabView(selection: $store.selectedTab) {
            HomeView(store: store).tabItem { Label("ホーム", systemImage: "house") }.tag(0)
            LibraryView(store: store, shortcutDeck: $shortcutDeck)
                .tabItem { Label("ライブラリ", systemImage: "books.vertical") }.tag(1)
            StatisticsView(store: store).tabItem { Label("記録", systemImage: "chart.bar") }.tag(2)
            SettingsView(store: store, probeContainer: probeContainer)
                .tabItem { Label("設定", systemImage: "gearshape") }.tag(3)
        }
        .fullScreenCover(isPresented: $store.showingReview) { ReviewView(store: store) }
        // One alert presenter avoids two .alert modifiers competing on TabView.
        .alert(Text(store.failure != nil ? "処理に失敗しました" : "ショートカット"),
               isPresented: Binding(
                get: { !store.showingReview && (store.failure != nil || shortcutNotice != nil) },
                set: { if !$0 && !store.showingReview { store.failure = nil; shortcutNotice = nil } }
               )) {
            Button("閉じる", role: .cancel) { store.failure = nil; shortcutNotice = nil }
        } message: {
            Text(store.failure ?? shortcutNotice ?? "")
        }
        .onChange(of: shortcutNavigation.pending, initial: true) { _, _ in
            handleShortcut()
        }
        .onReceive(NotificationCenter.default.publisher(for: .studyNotificationOpened)) { _ in
            store.pause(); store.selectedTab = 0
        }
        .onChange(of: store.selectedTab) { _, tab in
            if tab == 0 { store.refreshHome() }
            if tab == 2 { store.refreshHome(); store.refreshStatistics() }
        }
        .onChange(of: scenePhase) { _, phase in
            store.sceneChanged(active: phase == .active)
            if phase == .active {
                shortcutNavigation.syncFromDisk()
                handleShortcut()
            }
        }
    }

    private func handleShortcut() {
        guard let request = shortcutNavigation.take() else { return }

        // Follow the app's normal pause path when navigating away from study.
        if store.showingReview {
            if case .study = request {} else {
                store.pause()
                // Keep the study screen when pausing could not be saved/refreshed.
                guard !store.showingReview else { return }
            }
        }

        switch request {
        case let .study(mode):
            store.selectedTab = 0
            store.refreshHome()
            let decision = ShortcutStudyDecision.resolve(
                mode: mode, sessionExists: store.review != nil,
                canResume: store.review?.card != nil, canStart: store.canStart(mode))
            switch decision {
            case let .start(mode):
                store.start(mode)
            case .resume:
                if !store.showingReview { store.resume() }
            case .showExistingSession:
                shortcutNotice = "中断中の学習セッションがあります。ホームから再開・完了するか、明示的に切り替えてください。"
            case .unavailable:
                shortcutNotice = mode == .new ? store.newAvailabilityMessage :
                    (store.homeFailure ?? "今は復習できるカードがありません。学習対象を確認してください。")
            }
        case .progress:
            store.selectedTab = 2
            store.refreshHome()
            store.refreshStatistics()
        case let .deck(id):
            store.selectedTab = 1
            do { try store.reload() }
            catch {
                shortcutNotice = "デッキの読み込みに失敗しました。再度お試しください。"
                return
            }
            guard store.decks.contains(where: { $0.id == id }) else {
                shortcutDeck = nil
                shortcutNotice = "指定したデッキが見つかりません。削除または復元されている可能性があります。"
                return
            }
            shortcutDeck = ShortcutDeckDestination(id: id)
        }
    }
}

struct HomeView: View {
    @Bindable var store: StudyStore
    @State private var replacingWith: StudyMode?
    @State private var editingScope = false
    @State private var adding = false
    @State private var showingHelp = false
    @State private var editingSessionAnswerLimit = false
    @Environment(\.scenePhase) private var scenePhase

    private func start(_ mode: StudyMode) {
        if store.review != nil { replacingWith = mode }
        else { store.start(mode) }
    }
    private var refreshDeadline: Date? {
        store.selectedTab == 0 && !store.showingReview && scenePhase == .active ? store.nextHomeRefresh : nil
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LearningScopeSelector(store: store) { editingScope = true }
                    Button { editingSessionAnswerLimit = true } label: {
                        HStack {
                            Text("今回の回答数")
                            Spacer()
                            Text(store.sessionAnswerLimit == 0 ? "すべて" : "\(store.sessionAnswerLimit)問")
                                .foregroundStyle(Color("SecondaryText"))
                            Image(systemName: "chevron.down").font(.caption)
                        }
                    }
                    .accessibilityIdentifier("openSessionAnswerLimit")
                    .accessibilityHint("次の学習セッションの回答数を選びます")
                }
                if let error = store.homeFailure {
                    Section {
                        Label("学習情報を読み込めません", systemImage: "exclamationmark.triangle")
                        Text(error).font(.footnote)
                        Button("再試行") { store.perform { } }.accessibilityIdentifier("retryHome")
                    }
                } else {
                    ReviewHeroSection(store: store) {
                        switch store.homePrimaryAction {
                        case .resume: store.resume()
                        case let .start(mode, _): store.start(mode)
                        case .addCards: adding = true
                        case .complete: store.completeSession()
                        case .waiting, .unavailable: break
                        }
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
            .sheet(isPresented: $editingSessionAnswerLimit) {
                NavigationStack {
                    List {
                        ForEach([10, 20, 30, 0], id: \.self) { count in
                            Button {
                                store.changeSessionAnswerLimit(count)
                                if store.failure == nil { editingSessionAnswerLimit = false }
                            } label: {
                                HStack {
                                    Text(count == 0 ? "すべて（上限なし）" : "\(count)問")
                                    Spacer()
                                    if store.sessionAnswerLimit == count {
                                        Image(systemName: "checkmark")
                                    }
                                }.foregroundStyle(.primary)
                            }
                        }
                    }
                    .navigationTitle("今回の回答数")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("閉じる") { editingSessionAnswerLimit = false }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
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
            .onAppear { store.refreshHome() }
            .task(id: refreshDeadline) {
                guard let deadline = refreshDeadline else { return }
                do { try await Task.sleep(for: .seconds(max(0.01, deadline.timeIntervalSince(store.clock())))) }
                catch { return }
                guard !Task.isCancelled else { return }
                store.refreshHome()
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
    let store: StudyStore
    let execute: () -> Void
    private var action: HomePrimaryAction { store.homePrimaryAction }
    private var executable: Bool {
        switch action {
        case .waiting, .unavailable: return false
        default: return true
        }
    }
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                switch action {
                case let .resume(mode):
                    Text("中断中の学習").font(.headline)
                    Text(mode.title).font(.subheadline)
                    Text("開始時の学習対象で続けます。回答下書きと確定済みの履歴は保持されます。")
                        .font(.footnote).foregroundStyle(Color("SecondaryText"))
                case let .waiting(next):
                    Text(action.title).font(.headline)
                    Text("次の短期復習: \(next.formatted(date: .omitted, time: .shortened))")
                        .accessibilityIdentifier("nextShortReview")
                    Text("開始時の学習対象で待機しています。期限になると続きから再開できます。")
                    Button("今回の学習を完了", action: { store.completeSession() })
                        .accessibilityIdentifier("completeStudy")
                case .complete:
                    Text("今回の出題は完了しました").font(.headline)
                    Text("確定済みの学習履歴と次回の予定を保存して、今回の学習を完了します。")
                case let .start(mode, count):
                    Text(mode == .review ? "いま復習できるカード" : "いま新しく覚えられるカード").font(.headline)
                    Text("\(count)枚").font(.largeTitle.bold())
                        .accessibilityIdentifier(mode == .review ? "dueCount" : "primaryNewCount")
                        .accessibilityLabel("\(mode.title)、絞り込み後、\(String(count))枚")
                    Text(mode.explanation).font(.footnote).foregroundStyle(Color("SecondaryText"))
                case .addCards:
                    Text("最初のカードを登録しましょう。").font(.headline)
                case .unavailable:
                    Text(action.title).font(.headline)
                    if let next = store.nextShortDue {
                        Text("次の短期復習: \(next.formatted(date: .omitted, time: .shortened))")
                            .accessibilityIdentifier("nextShortReview")
                    }
                    if store.globalCounts.due > 0 { Text("ほかの学習対象に復習があります。") }
                }
                if executable {
                    Button(action: execute) {
                        Text(action.title).font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }.buttonStyle(.borderedProminent).tint(Color("PrimaryAction")).foregroundStyle(.white)
                        .accessibilityIdentifier(action.identifier)
                }
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
        }
    }
}

struct OtherStudyModesSection: View {
    let store: StudyStore
    let start: (StudyMode) -> Void
    var body: some View {
        Section {
            ForEach(StudyMode.allCases.filter { mode in
                if case let .start(primary, _) = store.homePrimaryAction { return mode != primary }
                return true
            }) { mode in
                Button { start(mode) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(store.review == nil ? mode.title : "新しい学習：\(mode.title)").font(.headline)
                                .foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if mode == .new {
                                Text("\(store.counts.newRemaining)枚").foregroundStyle(Color.primary)
                                    .accessibilityIdentifier("newCount")
                            }
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        Text(mode == .new ? mode.explanation : store.mixedAvailabilityMessage)
                            .font(.footnote).foregroundStyle(Color("SecondaryText"))
                    }.padding(.vertical, 6)
                }.accessibilityIdentifier("start-\(mode.rawValue)").disabled(!store.canStart(mode))
                    .accessibilityHint(mode == .new ? store.newAvailabilityMessage : store.mixedAvailabilityMessage)
                if mode == .new {
                    Text(store.newAvailabilityMessage).font(.footnote).foregroundStyle(Color("SecondaryText"))
                        .accessibilityIdentifier("newAvailabilityMessage")
                    if store.isNewLimitReached {
                        Text(store.newLimitRemainingMessage).font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("newLimitRemaining")
                        NavigationLink("新規学習の上限を変更") { StudySettingsView(store: store) }
                            .accessibilityIdentifier("changeNewLimit")
                    }
                }
            }
            if case .start(.new, _) = store.homePrimaryAction {
                Text("今日学べる新規カード: \(store.counts.newRemaining)枚").accessibilityIdentifier("newCount")
            }
        } header: { Text(store.review == nil ? "ほかの学習" : "別の学習を開始").foregroundStyle(Color("SecondaryText")) }
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
