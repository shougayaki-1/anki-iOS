import SwiftUI
import SwiftData

struct MainTabs: View {
    @Bindable var store: StudyStore
    let probeContainer: ModelContainer
    var sceneActivity: ((Bool) -> Void)? = nil
    @Environment(\.scenePhase) private var scenePhase
    @State private var shortcutNavigation = ShortcutNavigation.shared
    @State private var shortcutDeck: ShortcutDeckDestination?
    @State private var shortcutNotice: String?

    @State private var sidebarDeck: UUID?
    @State private var expandedDecks = Set<UUID>()
    @State private var compactColumn = NavigationSplitViewColumn.detail

    private func sidebarButton(_ title: String, icon: String, tab: Int, key: KeyEquivalent) -> some View {
        Button {
            sidebarDeck = nil; store.selectedTab = tab; compactColumn = .detail
        } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
        }.keyboardShortcut(key, modifiers: .command)
            .accessibilityIdentifier("sidebarTab-\(tab)")
            .accessibilityAddTraits(store.selectedTab == tab && sidebarDeck == nil ? .isSelected : [])
    }

    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom != .phone {
                NavigationSplitView(preferredCompactColumn: $compactColumn) {
                    List {
                        Section("暗記ノート") {
                            sidebarButton("ホーム", icon: "house", tab: 0, key: "1")
                            sidebarButton("ライブラリ", icon: "books.vertical", tab: 1, key: "2")
                            sidebarButton("記録", icon: "chart.bar", tab: 2, key: "3")
                            sidebarButton("設定", icon: "gearshape", tab: 3, key: "4")
                        }
                        Section("階層デッキ") {
                            ForEach(DeckTreeBuilder.visibleRows(roots: DeckTreeBuilder.roots(from: store.decks), expanded: expandedDecks)) { row in
                                HStack(spacing: 4) {
                                    if row.hasChildren {
                                        Button { if !expandedDecks.insert(row.id).inserted { expandedDecks.remove(row.id) } } label: {
                                            Image(systemName: expandedDecks.contains(row.id) ? "chevron.down" : "chevron.right")
                                                .frame(width: 32, height: 36)
                                        }.accessibilityLabel("\(row.path)の子デッキを開閉")
                                    }
                                    Button {
                                        sidebarDeck = row.id; store.selectedTab = 1; compactColumn = .detail
                                    } label: {
                                        Label(row.name, systemImage: "folder")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.accessibilityLabel(row.path)
                                        .accessibilityIdentifier("sidebarDeck-" + row.id.uuidString)
                                        .accessibilityAddTraits(sidebarDeck == row.id && store.selectedTab == 1 ? .isSelected : [])
                                }.padding(.leading, CGFloat(min(row.depth, 6)) * 12)
                            }
                        }
                    }.buttonStyle(.borderless)
                        .navigationTitle("暗記ノート")
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
                } detail: {
                    Group {
                        switch store.selectedTab {
                        case 1: LibraryView(store: store, shortcutDeck: $shortcutDeck, deckFilter: sidebarDeck)
                        case 2: StatisticsView(store: store)
                        case 3: SettingsView(store: store, probeContainer: probeContainer)
                        default: HomeView(store: store)
                        }
                    }
                }.navigationSplitViewStyle(.balanced)
                    // SplitView owns its navigation container. Recreate that container
                    // when switching root destinations so a pushed note cannot cover Home.
                    .id("\(store.selectedTab)-\(sidebarDeck?.uuidString ?? "all")")
            } else {
                TabView(selection: $store.selectedTab) {
                    HomeView(store: store).tabItem { Label("ホーム", systemImage: "house") }.tag(0)
                    LibraryView(store: store, shortcutDeck: $shortcutDeck)
                        .tabItem { Label("ライブラリ", systemImage: "books.vertical") }.tag(1)
                    StatisticsView(store: store).tabItem { Label("記録", systemImage: "chart.bar") }.tag(2)
                    SettingsView(store: store, probeContainer: probeContainer)
                        .tabItem { Label("設定", systemImage: "gearshape") }.tag(3)
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if let notice = store.noteSaveNotice {
                NoteSaveNoticeView(notice: notice) {
                    if store.noteSaveNotice?.id == notice.id { store.noteSaveNotice = nil }
                }
            }
        }
        .onOpenURL { url in
            guard let destination = WidgetDestination.parse(url) else { return }
            switch destination {
            case .home:
                if store.showingReview { store.pause(); guard !store.showingReview else { return } }
                store.selectedTab = 0; store.refreshHome()
            case .review: shortcutNavigation.submit(.study(.review))
            case .progress: shortcutNavigation.submit(.progress)
            }
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
        .onChange(of: store.decks.map(\.id)) { _, ids in
            if let sidebarDeck, !ids.contains(sidebarDeck) { self.sidebarDeck = nil }
        }
        .onChange(of: store.selectedTab) { _, tab in
            if tab == 0 { store.refreshHome() }
            if tab == 2 { store.refreshHome(); store.refreshStatistics() }
        }
        .onAppear { sceneActivity?(scenePhase == .active) }
        .onDisappear { sceneActivity?(false) }
        .onChange(of: scenePhase) { _, phase in
            if let sceneActivity { sceneActivity(phase == .active) }
            else { store.sceneChanged(active: phase == .active) }
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
            sidebarDeck = nil; compactColumn = .detail
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
                            Text("学習設定")
                            Spacer()
                            Text(HomeStudyPresentation.sessionSummary(answerLimit: store.sessionAnswerLimit, responseMode: store.sessionResponseMode))
                                .fixedSize(horizontal: false, vertical: true)
                                .foregroundStyle(Color("SecondaryText"))
                            Image(systemName: "chevron.down").font(.caption)
                        }
                    }
                    .accessibilityIdentifier("openSessionAnswerLimit")
                    .accessibilityHint("次の学習セッションの回答形式と回答数を選びます")
                }
                if store.homeFailure == nil {
                    DailyProgressSection(count: store.counts.learnedToday, goal: store.settings.dailyGoal)
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
                }
                if store.homeFailure == nil && store.hasCards && !store.canStart(.mixed) {
                    Section {
                        Text(store.sessionResponseMode == .ordering ? "今は並び替えで学習できるカードがありません。英文の一問一答・記述式が対象です。学習設定で回答形式を変更できます。" : "今はこの条件で学習できるカードがありません。")
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
                        Section("回答形式") {
                            Picker("回答形式", selection: Binding(get: { store.sessionResponseMode }, set: { store.changeSessionResponseMode($0) })) {
                                ForEach(SessionResponseMode.allCases, id: \.self) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }.accessibilityIdentifier("sessionResponseMode")
                            Text("次に開始する学習に適用します。中断中の学習は開始時の設定を保持します。並び替えは対応する英文カードだけを出題します。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach([10, 20, 30, 0], id: \.self) { count in
                            Button {
                                store.changeSessionAnswerLimit(count)
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
                    .navigationTitle("学習設定")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("閉じる") { editingSessionAnswerLimit = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $adding) { NoteEditorView(store: store, item: nil) }
            .sheet(isPresented: $showingHelp) {
                NavigationStack {
                    List {
                        ForEach(StudyMode.allCases) { mode in
                            Section(mode.title) { Text(mode.explanation) }
                        }
                        Section("1回の学習") {
                            Text(HomeStudyPresentation.explanation(answerLimit: store.sessionAnswerLimit))
                            Text("学習設定は次に開始する学習に適用します。中断中の学習は開始時の設定と残り回答数を保持します。今日の学習はユニークカード枚数で、回答回数とは別です。")
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
                    Text(mode == .review ? "復習できるカード" : "新しく学べるカード").font(.headline)
                    Text("\(count)枚").font(.largeTitle.bold())
                        .accessibilityIdentifier(mode == .review ? "dueCount" : "newCount")
                        .accessibilityLabel(HomeStudyPresentation.cardPool(mode: mode, count: count))
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
                        .accessibilityLabel(action.accessibilityLabel(answerLimit: store.sessionAnswerLimit))
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
                            Text(mode.title).font(.headline)
                                .foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        Text(HomeStudyPresentation.cardPool(mode: mode, count: store.homeCardCount(mode)))
                            .font(.subheadline).foregroundStyle(Color("SecondaryText"))
                            .accessibilityIdentifier(mode == .new ? "newCount" : "pool-\(mode.rawValue)")
                    }.padding(.vertical, 6)
                }.accessibilityIdentifier("start-\(mode.rawValue)").disabled(!store.canStart(mode))
                    .accessibilityLabel((store.review == nil ? "" : "新しい学習：") + HomeStudyPresentation.startTitle(mode: mode, answerLimit: store.sessionAnswerLimit) + "。" + HomeStudyPresentation.cardPool(mode: mode, count: store.homeCardCount(mode)))
                    .accessibilityHint((mode == .new ? store.newAvailabilityMessage : store.mixedAvailabilityMessage) + HomeStudyPresentation.explanation(answerLimit: store.sessionAnswerLimit))
                if mode == .new {
                    if store.counts.newRemaining == 0 {
                        Text(store.newAvailabilityMessage).font(.footnote).foregroundStyle(Color("SecondaryText"))
                            .accessibilityIdentifier("newAvailabilityMessage")
                    }
                    if store.isNewLimitReached {
                        Text(store.newLimitRemainingMessage).font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("newLimitRemaining")
                        NavigationLink("新規学習の上限を変更") { StudySettingsView(store: store) }
                            .accessibilityIdentifier("changeNewLimit")
                    }
                }
            }
        } header: { Text("学習を始める").foregroundStyle(Color("SecondaryText")) }
    }
}

struct DailyProgressSection: View {
    let count: Int
    let goal: Int?
    var body: some View {
        Section {
            if let goal, goal > 0 {
                ProgressView(value: Double(min(goal, count)), total: Double(goal)) {
                    Text(HomeStudyPresentation.dailyProgress(count: count, goal: goal))
                }.accessibilityIdentifier("goalProgress")
                    .accessibilityLabel("今日の学習、全デッキ、ユニークカード")
                    .accessibilityValue("\(count)枚、目標\(goal)枚")
            } else { Text(HomeStudyPresentation.dailyProgress(count: count, goal: nil)) }
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
                    DeckSelectionField("デッキ", decks: store.decks, selection: $draft.deckID, nilTitle: "すべてのデッキ", includesDescendants: true).accessibilityIdentifier("studyDeckPicker")
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

/// Kept above the destination view so dismissing the editor does not lose feedback.
struct NoteSaveNoticeView: View {
    let notice: NoteSaveNotice
    let clear: () -> Void

    var body: some View {
        Label(notice.message, systemImage: "checkmark.circle.fill")
            .font(.subheadline)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.regularMaterial)
            .accessibilityIdentifier("noteSaveNotice")
            .task(id: notice.id) {
                do {
                    // Let the editor dismissal finish before VoiceOver announces success.
                    try await Task.sleep(for: .milliseconds(500))
                    UIAccessibility.post(notification: .announcement, argument: notice.message)
                    try await Task.sleep(for: .seconds(4))
                    clear()
                } catch { } // A replaced notice cancels its old expiry task.
            }
    }
}
