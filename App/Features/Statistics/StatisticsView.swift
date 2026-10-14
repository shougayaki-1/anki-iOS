import SwiftUI
import Charts

private enum StatisticsPeriod: String, CaseIterable, Identifiable {
    case day, week, month
    var id: Self { self }
    var title: String {
        switch self { case .day: return "日"; case .week: return "週"; case .month: return "月" }
    }
    var component: Calendar.Component {
        switch self { case .day: return .day; case .week: return .weekOfYear; case .month: return .month }
    }
    func label(for date: Date) -> String {
        switch self {
        case .day: return date.formatted(.dateTime.month().day())
        case .week: return date.formatted(.dateTime.year().month().day()) + "の週"
        case .month: return date.formatted(.dateTime.year().month())
        }
    }
    func buckets(in statistics: StudyStatistics) -> [StatisticsBucket] {
        switch self {
        case .day: return Array(statistics.days.reversed())
        case .week: return statistics.weeks
        case .month: return statistics.months
        }
    }
}

private enum StatisticsMetric: String, CaseIterable, Identifiable {
    case answers, uniqueCards, newAnswers, reviewAnswers, again, hard, good, easy, duration
    var id: Self { self }
    var title: String {
        switch self {
        case .answers: return "回答回数"
        case .uniqueCards: return "ユニークカード"
        case .newAnswers: return "新規の回答"
        case .reviewAnswers: return "復習の回答"
        case .again: return "Again（もう一度）"
        case .hard: return "Hard（難しい）"
        case .good: return "Good（普通）"
        case .easy: return "Easy（簡単）"
        case .duration: return "回答時間"
        }
    }
    var unit: String {
        switch self {
        case .uniqueCards: return "枚"
        case .duration: return "分"
        default: return "回"
        }
    }
    func value(_ bucket: StatisticsBucket) -> Double {
        switch self {
        case .answers: return Double(bucket.answers)
        case .uniqueCards: return Double(bucket.cards)
        case .newAnswers: return Double(bucket.newAnswers)
        case .reviewAnswers: return Double(bucket.reviewAnswers)
        case .again: return Double(bucket.ratings[.again, default: 0])
        case .hard: return Double(bucket.ratings[.hard, default: 0])
        case .good: return Double(bucket.ratings[.good, default: 0])
        case .easy: return Double(bucket.ratings[.easy, default: 0])
        case .duration: return Double(bucket.durationMs) / 60_000
        }
    }
    func formatted(_ value: Double) -> String {
        let count = self == .duration
            ? value.formatted(.number.precision(.fractionLength(1)))
            : Int(value).formatted()
        return count + unit
    }
}

// Owns the chart and its accessible numerical equivalent, independently of
// the library's deck-tree presentation.
private struct StatisticsTrendChart: View {
    let statistics: StudyStatistics
    let period: StatisticsPeriod
    let metric: StatisticsMetric
    @State private var showNumbers = false

    private var buckets: [StatisticsBucket] { period.buckets(in: statistics) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Chart(buckets) { bucket in
                BarMark(
                    x: .value("期間", bucket.date, unit: period.component),
                    y: .value(metric.title, metric.value(bucket))
                )
                .foregroundStyle(Color.accentColor)
            }
            .frame(height: 200)
            .chartYAxisLabel(metric.unit)
            // Each value is available as a standard VoiceOver row below.
            .accessibilityHidden(true)

            let total = buckets.reduce(0.0) { $0 + metric.value($1) }
            Text("表示期間の棒の合計: \(metric.formatted(total))")
                .font(.subheadline)
                .accessibilityAddTraits(.isSummaryElement)

            DisclosureGroup("期間ごとの数値を表示", isExpanded: $showNumbers) {
                ForEach(buckets) { bucket in
                    LabeledContent(period.label(for: bucket.date),
                                   value: metric.formatted(metric.value(bucket)))
                }
            }
            Text("ユニーク枚数は各期間内で重複を除きます。複数期間の合計では同じカードを再び数えることがあります。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }
}

struct StatisticsView: View {
    @Bindable var store: StudyStore
    @State private var period: StatisticsPeriod = .day
    @State private var metric: StatisticsMetric = .answers

    private var selectedTagNames: String {
        let names = store.tags.filter { store.statisticsScope.tagIDs.contains($0.id) }.map(\.name)
        return names.isEmpty ? "すべて" : names.joined(separator: "、")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink("保存したタイピング回答") { TypedAnswerHistoryView(store: store) }
                        .accessibilityIdentifier("typedAnswerHistory")
                    NavigationLink("復習負荷予測・学習計画") { ReviewForecastView(store: store) }
                        .accessibilityIdentifier("openReviewForecast")
                }
                if let progress = store.achievementProgress {
                    Section("続けた記録（全デッキ）") {
                        LabeledContent("現在の連続学習", value: "\(progress.currentStreak)日")
                        LabeledContent("最長記録", value: "\(progress.longestStreak)日")
                        LabeledContent("今日", value: progress.studiedToday ? "学習済み" : "これから学習できます")
                        LabeledContent("今日学習したカード", value: "\(progress.uniqueCardsToday)枚")
                        if let goal = store.settings.dailyGoal, goal > 0 {
                            LabeledContent("今日の目標", value: "\(goal)枚")
                        }
                        NavigationLink("達成履歴") {
                            List {
                                if store.achievementHistory.isEmpty { Text("これからの達成がここに残ります。") }
                                ForEach(store.achievementHistory) { record in
                                    VStack(alignment: .leading) {
                                        Text(record.title)
                                        Text(record.studyDay).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Text("達成時の記録です。現在の実績はUndo・カードの変更で変わります。長期定着はReview状態かつStabilityが21日以上のFSRS推定で、永久記憶を保証しません。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }.navigationTitle("達成履歴")
                        }
                    }
                }
                Section("集計条件") {
                    DeckSelectionField("デッキ（子孫を含む）", decks: store.decks, selection: $store.statisticsScope.deckID, nilTitle: "すべてのデッキ", includesDescendants: true)
                    NavigationLink {
                        ContextualTagScopeSheet(store: store, scope: $store.statisticsScope)
                    } label: {
                        LabeledContent("タグ（すべてを含む）", value: selectedTagNames)
                    }
                    Text("ここでの絞り込みは記録専用です。ホームの学習対象には影響しません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if store.statisticsLoading {
                    Section { ProgressView("記録を集計しています…") }
                } else if let error = store.statisticsError {
                    Section {
                        ContentUnavailableView("記録を集計できません", systemImage: "exclamationmark.triangle",
                                               description: Text(error))
                        Button("再試行") { store.refreshStatistics() }
                    }
                } else if let stats = store.statistics {
                    Section("今日の記録") {
                        let today = stats.days[0]
                        LabeledContent("学習したカード（ユニーク）", value: "\(today.cards)枚")
                        LabeledContent("確定した回答", value: "\(today.answers)回")
                            .accessibilityIdentifier("todayAnswerCount")
                        LabeledContent("新規の回答", value: "\(today.newAnswers)回")
                        LabeledContent("復習の回答", value: "\(today.reviewAnswers)回")
                        LabeledContent("集計対象の継続日数", value: "\(stats.streak)日")
                        Text("学習日は\(store.settings.dayStartHour)時を境界とします（24時間表記）。今日の目標や、進行中セッションの残り回答数とは異なります。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("学習推移") {
                        Picker("期間", selection: $period) {
                            ForEach(StatisticsPeriod.allCases) { value in
                                Text(value.title).tag(value)
                            }
                        }.pickerStyle(.segmented)
                        Picker("指標", selection: $metric) {
                            ForEach(StatisticsMetric.allCases) { value in
                                Text(value.title).tag(value)
                            }
                        }
                        StatisticsTrendChart(statistics: stats, period: period, metric: metric)
                    }
                    Section("自己評価（全履歴）") {
                        ForEach(ReviewGrade.allCases, id: \.self) { grade in
                            let name: String = {
                                switch grade {
                                case .again: return "Again（もう一度）"
                                case .hard: return "Hard（難しい）"
                                case .good: return "Good（普通）"
                                case .easy: return "Easy（簡単）"
                                }
                            }()
                            LabeledContent(name, value: "\(stats.ratings[grade, default: 0])回")
                        }
                        LabeledContent("確定した回答時間の合計",
                                       value: "\(stats.durationMs / 60_000)分")
                    }
                    Section("現在の定着状況（推定）") {
                        NavigationLink("記憶の状態を詳しく見る") { MemoryAnalysisView(store: store) }
                            .accessibilityIdentifier("openMemoryAnalysis")
                        if let memory = stats.memory {
                            LabeledContent("長期定着カード（推定）", value: "\(memory.matureCardCount)枚")
                        }
                        if let retention = stats.meanRetrievability {
                            LabeledContent("FSRS予測保持率",
                                           value: retention.formatted(.percent.precision(.fractionLength(1))))
                        } else {
                            Text("予測できる学習済みカードがありません。")
                        }
                        LabeledContent("期限超過のカード", value: "\(stats.overdueCount)枚")
                        Text("保持率は停止中・未学習カードを除いた現在の予測想起確率の平均で、観測した正答率ではありません。期限超過は、期限を過ぎた学習済み・停止していないカードの枚数です。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("集計について") {
                        Text("回答回数は保存済みFSRS評価の数です。同じカードへの再回答も数え、Undoで削除された履歴は数えません。ヒント・解答表示・並び替え操作は数えません。")
                        if stats.unattributedAnswers > 0 {
                            Text("削除などにより現在の所属先を特定できない履歴が\(stats.unattributedAnswers)件あります。全体の記録に含みますが、デッキ・タグ別には割り当てません。")
                        }
                        Text("デッキ・タグ別の過去の回答は、現在残っているカードの所属で再分類します。移動前の所属を復元した履歴ではありません。")
                    }.font(.footnote).foregroundStyle(.secondary)
                } else {
                    Section { ContentUnavailableView("まだ記録を読み込んでいません", systemImage: "chart.bar") }
                }
            }
            .navigationTitle("記録")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("更新", systemImage: "arrow.clockwise") { store.refreshStatistics() }
                        .disabled(store.statisticsLoading)
                }
            }
            .task(id: store.selectedTab) {
                guard store.selectedTab == 2 else { return }
                // TabView may retain this view across reloads and tab changes.
                store.refreshStatistics()
            }
            .onChange(of: store.statisticsScope) { _, _ in store.refreshStatistics() }
        }
    }
}


struct TypedAnswerSettingsView: View {
    @Bindable var store: StudyStore
    @State private var policy = TypedAnswerPolicy()
    @State private var failure: String?
    @State private var confirming = false
    var body: some View {
        Form {
            Section("タイピング回答の保存") {
                Toggle("評価時の回答本文を保存", isOn: Binding(get: { policy.enabled }, set: { value in save { $0.enabled = value } }))
                    .accessibilityIdentifier("typedAnswerSaveToggle")
                Picker("保存期間", selection: Binding(get: { policy.retentionDays }, set: { value in save { $0.retentionDays = value } })) {
                    Text("7日").tag(7); Text("30日").tag(30); Text("90日").tag(90); Text("手動削除まで").tag(0)
                }.accessibilityIdentifier("typedAnswerRetention")
                Text("初期値はOFFです。ONの間に文字入力方式で自己評価した回答だけを、問題・模範解答・評価・時刻と一緒に保存します。AI採点は行いません。")
                Text("端末内のみで保存し、外部送信しません。完全バックアップには回答本文も含まれます。通常のライブラリ検索には含めません。")
                Text("期間を過ぎた回答は起動・評価・履歴表示・バックアップ時に削除します。期間を短くすると古い回答を削除します。OFFにしても保存済みの回答は期間まで残ります。")
            }
            Section {
                NavigationLink("保存したタイピング回答") { TypedAnswerHistoryView(store: store) }
                Button("保存した回答本文をすべて削除", role: .destructive) { confirming = true }
                    .accessibilityIdentifier("deleteAllTypedAnswers")
                Text("本文の削除ではFSRS・回答回数・復習予定は変わりません。書き出したバックアップには過去の本文が残るため、必要ならそのファイルも削除してください。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("回答の保存設定")
        .task { do { policy = try store.repository.options().typedAnswerPolicy ?? TypedAnswerPolicy() } catch { failure = error.localizedDescription } }
        .confirmationDialog("保存した回答本文をすべて削除しますか？", isPresented: $confirming, titleVisibility: .visible) {
            Button("本文をすべて削除", role: .destructive) {
                do { try store.repository.deleteTypedAnswers() } catch { failure = error.localizedDescription }
            }
        }
        .alert("保存できませんでした", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("閉じる", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }
    private func save(_ change: (inout TypedAnswerPolicy) -> Void) {
        var value = policy; change(&value)
        do { try store.repository.updateTypedAnswerPolicy(value, now: store.clock()); policy = value }
        catch { failure = error.localizedDescription }
    }
}

struct TypedAnswerHistoryView: View {
    @Bindable var store: StudyStore
    @State private var answers: [TypedAnswerRecord] = []
    @State private var search = ""
    @State private var failure: String?
    private var filtered: [TypedAnswerRecord] {
        search.isEmpty ? answers : answers.filter { [$0.question, $0.answer, $0.modelAnswer].contains { $0.localizedStandardContains(search) } }
    }
    var body: some View {
        List {
            Section {
                Text("回答時点の問題・模範解答です。後のカード編集や削除では変わりません。本文を削除してもFSRSと評価履歴は保持します。")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink("回答の保存設定") { TypedAnswerSettingsView(store: store) }
            }
            if filtered.isEmpty {
                ContentUnavailableView("保存した回答がありません", systemImage: "text.bubble",
                                       description: Text("設定をONにした後のタイピング回答を表示します。"))
                    .accessibilityIdentifier("typedAnswerHistoryEmpty")
            }
            ForEach(filtered) { answer in
                VStack(alignment: .leading, spacing: 8) {
                    Text(answer.question).font(.headline)
                    Text(answer.reviewedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("自己評価: " + (ReviewGrade(rawValue: answer.grade).map { String(describing: $0).capitalized } ?? ""))
                    Text("自分の回答").font(.caption).foregroundStyle(.secondary)
                    Text(answer.answer.isEmpty ? "（未入力）" : answer.answer).accessibilityIdentifier("savedTypedAnswer-" + answer.id.uuidString)
                    Text("模範解答").font(.caption).foregroundStyle(.secondary)
                    Text(answer.modelAnswer).accessibilityIdentifier("savedModelAnswer-" + answer.id.uuidString)
                }.textSelection(.enabled)
            }
            .onDelete { offsets in
                let ids = Set(offsets.map { filtered[$0].id })
                do { try store.repository.deleteTypedAnswers(ids: ids); answers.removeAll { ids.contains($0.id) } }
                catch { failure = error.localizedDescription }
            }
        }
        .navigationTitle("タイピング回答")
        .searchable(text: $search, prompt: "保存した問題・回答・模範解答を検索")
        .task { do { answers = try store.repository.savedTypedAnswers(now: store.clock()) } catch { failure = error.localizedDescription } }
        .alert("履歴を読み込めませんでした", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("閉じる", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }
}

struct MemoryAnalysisView: View {
    @Bindable var store: StudyStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var days = 30
    private var scopeLabel: String {
        let deck = store.decks.first { $0.id == store.statisticsScope.deckID }?.name ?? "すべてのデッキ"
        let tags = store.tags.filter { store.statisticsScope.tagIDs.contains($0.id) }.map(\.name)
        return deck + (tags.isEmpty ? "" : " · " + tags.joined(separator: "、"))
    }
    var body: some View {
        List {
            Section("対象") {
                Text(scopeLabel)
                Text("記録タブのデッキ（子孫を含む）・タグ条件を使用します。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("最新の状態に更新", systemImage: "arrow.clockwise") { store.refreshStatistics() }
                    .disabled(store.statisticsLoading)
            }
            if store.statisticsLoading {
                Section { ProgressView("記憶の状態を集計しています…") }
            } else if let error = store.statisticsError {
                Section { Text(error); Button("再試行") { store.refreshStatistics() } }
            } else if let report = store.statistics?.memory {
                Section("現在のカード（FSRS推定）") {
                    Text("集計日時: " + report.generatedAt.formatted(date: .abbreviated, time: .shortened))
                    Text("現在残っている学習済みカードが対象です。停止中・未学習・削除済みカードを除き、学習中・再学習中は含みます。過去の期間別状態ではありません。")
                        .font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("推定記憶済み枚数", value: report.estimatedRemembered.formatted(.number.precision(.fractionLength(1))) + "枚")
                    Text("各カードの想起確率の和を小数第1位に丸めます。必ず覚えている枚数ではありません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(report.distributions) { distribution in
                    Section(distribution.id) {
                        MemoryDistributionView(store: store, distribution: distribution)
                    }
                }
                Section("実際の保持率（実測）") {
                    Picker("対象期間", selection: $days) {
                        Text("7日").tag(7); Text("30日").tag(30); Text("90日").tag(90)
                    }.pickerStyle(.segmented)
                    if let observed = report.retention.first(where: { $0.days == days }) {
                        LabeledContent("実測保持率", value: observed.rate.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "—")
                        LabeledContent("成功数 / 対象試行", value: "\(observed.successes) / \(observed.trials)")
                        Text(observed.start.formatted(date: .abbreviated, time: .shortened) + " 〜 " + observed.end.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                        if observed.trials == 0 { Text("この期間に長期Review状態からの対象評価がありません。") }
                        else if observed.trials < 20 { Text("試行が20件未満のため、期間比較や優劣の判断には使いません。") }
                        if observed.trials > 0 {
                            Chart {
                                BarMark(x: .value("評価", "成功"), y: .value("試行", observed.successes))
                                BarMark(x: .value("評価", "Again"), y: .value("試行", observed.trials - observed.successes))
                            }.frame(height: 120).accessibilityHidden(true)
                            LabeledContent("Again（失敗）", value: "\(observed.trials - observed.successes)試行")
                        }
                        NavigationLink("根拠のカード（\(observed.cardIDs.count)枚）") {
                            MemoryEvidenceCardsView(store: store, ids: observed.cardIDs)
                        }
                    }
                    LabeledContent("現在の目標保持率", value: report.targets.isEmpty ? "—（対象カードなし）" : report.targets.map { $0.formatted(.percent.precision(.fractionLength(1))) }.joined(separator: "、"))
                    Text("目標は現在の設定値です。複数の目標がある対象では全値を表示し、平均しません。過去の回答時の目標ではありません。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("評価前が長期Reviewのカードについて、カード×学習日の最初の対象評価を1試行とします。Againは失敗、Hard・Good・Easyは成功です。短期学習・再学習は除外します。学習日は\(store.settings.dayStartHour)時に切り替わります。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Undoで取り消した履歴は含みません。削除済みカードの履歴は全デッキに残りますが、現在の所属を特定できないためデッキ・タグ別には含みません。停止中カードの過去の対象評価は含みます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("記憶の状態")
        .onAppear { store.refreshStatistics() }
        .onChange(of: scenePhase) { _, value in if value == .active { store.refreshStatistics() } }
        .task {
            var day = StudyDay(startHour: store.settings.dayStartHour).interval(containing: store.clock()).start
            var zone = TimeZone.current.identifier
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                let next = StudyDay(startHour: store.settings.dayStartHour).interval(containing: store.clock()).start
                if next != day || zone != TimeZone.current.identifier {
                    day = next; zone = TimeZone.current.identifier; store.refreshStatistics()
                }
            }
        }
    }
}

private struct MemoryDistributionView: View {
    let store: StudyStore
    let distribution: MemoryDistribution
    @State private var selected: String?
    private func number(_ value: Double) -> String {
        distribution.unit.isEmpty ? value.formatted(.percent.precision(.fractionLength(1)))
            : value.formatted(.number.precision(.fractionLength(1))) + distribution.unit
    }
    var body: some View {
        Text(distribution.explanation).font(.footnote).foregroundStyle(.secondary)
        LabeledContent("対象", value: "\(distribution.count)枚")
        if let median = distribution.median, let minimum = distribution.minimum, let maximum = distribution.maximum {
            LabeledContent("中央値", value: number(median))
            LabeledContent("範囲", value: number(minimum) + " 〜 " + number(maximum))
            Chart(distribution.buckets) { bucket in
                BarMark(x: .value("区間", bucket.label), y: .value("カード", bucket.cards.count))
                    .foregroundStyle(bucket.label == selected ? Color.orange : Color.accentColor)
            }
            .frame(height: 160)
            .chartXSelection(value: $selected)
            .accessibilityHidden(true)
            if let bucket = distribution.buckets.first(where: { $0.label == selected }) {
                Text("選択中: \(bucket.label) · \(bucket.cards.count)枚").font(.subheadline)
                NavigationLink("選択した区間のカードを見る") {
                    MemoryEvidenceCardsView(store: store, ids: bucket.cards.map(\.id), cards: bucket.cards)
                }
            }
        } else { Text("対象となるカードがありません。") }
        ForEach(distribution.buckets) { bucket in
            NavigationLink {
                MemoryEvidenceCardsView(store: store, ids: bucket.cards.map(\.id), cards: bucket.cards)
            } label: { LabeledContent(bucket.label, value: "\(bucket.cards.count)枚") }
            .accessibilityIdentifier("memoryBucket-" + distribution.id + "-" + bucket.label)
        }
        Text("区間は下端を含み、上端を含みません。最終区間は上端も含みます。非有限・範囲外の値は除外し、数値は小数第1位に丸めます。")
            .font(.footnote).foregroundStyle(.secondary)
    }
}

private struct MemoryEvidenceCardsView: View {
    let store: StudyStore
    let ids: [UUID]
    var cards: [MemoryCard] = []
    var body: some View {
        let titles = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0.title) })
        List {
            Section {
                Text("\(ids.count)枚。カードを開くと現在の内容を確認できます。削除されたカードの過去評価は残りますが、内容は開けません。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if ids.isEmpty { ContentUnavailableView("該当するカードがありません", systemImage: "rectangle.stack") }
            ForEach(ids, id: \.self) { id in
                NavigationLink {
                    NoteDetailView(store: store, cardID: id)
                } label: {
                    VStack(alignment: .leading) {
                        Text(titles[id] ?? "評価対象カード")
                        Text(id.uuidString).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle("根拠のカード")
    }
}
