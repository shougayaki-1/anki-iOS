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
                        LabeledContent("継続日数", value: "\(stats.streak)日")
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
