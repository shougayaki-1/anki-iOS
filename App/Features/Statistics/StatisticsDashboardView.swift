import SwiftUI
import Charts

struct StatisticsView: View {
    @Bindable var store: StudyStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var historyDays = 7

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    filters
                    if store.statisticsLoading {
                        ProgressView("記録を集計しています…").frame(maxWidth: .infinity, minHeight: 160)
                    } else if let error = store.statisticsError {
                        ContentUnavailableView("記録を集計できません", systemImage: "exclamationmark.triangle", description: Text(error))
                        Button("再試行") { store.refreshStatistics() }
                    } else if let stats = store.statistics {
                        LearningSummarySection(store: store, stats: stats, days: historyDays)
                        StudyInsightsSection(store: store, insights: stats.insights[historyDays] ?? [])
                        MemoryGrowthSection(store: store, groups: stats.growth)
                        StudyCalendarSection(store: store, stats: stats)
                        DashboardForecastSection(store: store, stats: stats)
                        MemoryInsightsSection(store: store, stats: stats)
                        DashboardCard(title: "もっと詳しく", subtitle: "実績の内訳と、続けてきた足あと") {
                            NavigationLink { StatisticsDetailsView(store: store) } label: {
                                Label("回答推移・評価・学習時間", systemImage: "chart.xyaxis.line")
                            }.accessibilityIdentifier("openStatisticsDetails")
                            Divider()
                            NavigationLink { AchievementHistoryView(store: store) } label: {
                                Label("達成履歴", systemImage: "medal")
                            }.accessibilityIdentifier("dashboardAchievements")
                            Divider()
                            NavigationLink("保存したタイピング回答") { TypedAnswerHistoryView(store: store) }
                        }
                    }
                }
                .padding(20)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: historyDays)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("記録")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $store.showingAchievementHistory) { AchievementHistoryView(store: store) }
            .toolbar { Button("更新", systemImage: "arrow.clockwise") { store.refreshStatistics() }.disabled(store.statisticsLoading) }
            .task(id: store.selectedTab) {
                guard store.selectedTab == 2 else { return }
                store.refreshStatistics()
                var key = boundary
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    if key != boundary { key = boundary; store.refreshStatistics() }
                }
            }
            .onChange(of: store.statisticsScope) { _, _ in store.refreshStatistics() }
            .onChange(of: scenePhase) { _, phase in if phase == .active && store.selectedTab == 2 { store.refreshStatistics() } }
        }
    }
    private var boundary: String {
        AchievementProgress.dayKey(store.clock(), calendar: .current, startHour: store.settings.dayStartHour) + TimeZone.current.identifier
    }
    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("記録の対象", systemImage: "line.3.horizontal.decrease").font(.subheadline.weight(.semibold))
                Spacer()
                if store.statisticsScope.deckID != nil || !store.statisticsScope.tagIDs.isEmpty {
                    Button { store.statisticsScope = LearningScope() } label: {
                        Text("解除").padding(.horizontal, 10).frame(minWidth: 44, minHeight: 44)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                            .contentShape(Capsule())
                    }
                }
            }
            DeckSelectionField("デッキ", decks: store.decks, selection: $store.statisticsScope.deckID, nilTitle: "すべてのデッキ", includesDescendants: true)
                .accessibilityIdentifier("dashboardDeck")
            NavigationLink { ContextualTagScopeSheet(store: store, scope: $store.statisticsScope) } label: {
                HStack {
                    Text("タグ")
                    Spacer()
                    Text(store.tags.filter { store.statisticsScope.tagIDs.contains($0.id) }.map(\.name).joined(separator: "、").nilIfEmpty ?? "すべて")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.accessibilityIdentifier("dashboardTags")
            Picker("過去の実績の期間", selection: $historyDays) {
                Text("7日").tag(7); Text("30日").tag(30); Text("90日").tag(90); Text("全期間").tag(0)
            }.pickerStyle(.segmented).accessibilityIdentifier("dashboardPeriod")
            Text("期間は学習実績だけに適用。デッキは子孫を含み、タグはすべてを含む条件です。ホームの学習対象は変わりません。")
                .font(.caption).foregroundStyle(.secondary)
        }.buttonStyle(.plain)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct DashboardCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.bold()).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }
}

struct LearningSummarySection: View {
    let store: StudyStore
    let stats: StudyStatistics
    let days: Int
    var body: some View {
        DashboardCard(title: "積み重ねた学習", subtitle: days == 0 ? "全期間の実績 · 選択中の対象" : "過去\(days)日間の実績 · 選択中の対象") {
            if let total = stats.dashboardPeriods[days] {
                NavigationLink { StatisticsDetailsView(store: store) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(total.cards.formatted()).font(.system(size: 48, weight: .bold, design: .rounded)).foregroundStyle(Color.accentColor)
                            Text("枚を学習").font(.headline)
                        }
                        HStack(spacing: 20) {
                            Label("\(total.durationMs / 60_000)分", systemImage: "clock")
                            Text("\(total.answers)回答")
                        }.font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityIdentifier("dashboardSummary")
                Text("同じカードへの再回答は、学習枚数に重ねて数えません。時間は保存された回答時間の合計です。")
                    .font(.caption).foregroundStyle(.secondary)
                if total.answers == 0 { Text("この期間の学習はこれから。自分のペースで積み重ねましょう。").font(.subheadline) }
            }
            Divider()
            if let progress = stats.achievements?.progress {
                NavigationLink { AchievementHistoryView(store: store) } label: {
                    HStack {
                        Label("\(progress.currentStreak)日連続", systemImage: "flame.fill").font(.headline).foregroundStyle(.orange)
                        Spacer()
                        Text("全デッキ共通").font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                }.buttonStyle(.plain)
                if let goal = store.settings.dailyGoal, goal > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("今日の目標").font(.subheadline)
                            Spacer()
                            Text("\(progress.uniqueCardsToday) / \(goal)枚").font(.subheadline.weight(.semibold)).monospacedDigit()
                        }
                        ProgressView(value: Double(min(goal, progress.uniqueCardsToday)), total: Double(goal)).tint(.green)
                            .accessibilityLabel("今日の目標、全デッキ共通")
                            .accessibilityValue("\(goal)枚のうち\(progress.uniqueCardsToday)枚")
                    }
                } else { Text("今日 \(progress.uniqueCardsToday)枚 · 日次目標はオフ").font(.subheadline) }
                Text("連続日数と今日の目標は、期間・デッキ・タグの絞り込みに関係しません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct StudyCalendarSection: View {
    let store: StudyStore
    let stats: StudyStatistics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var month: Date?
    @State private var selected: Date?
    private var calendar: Calendar { .current }
    private var today: Date { StudyDay(startHour: store.settings.dayStartHour).interval(containing: store.clock()).start }
    private var monthStart: Date { calendar.dateInterval(of: .month, for: month ?? today)!.start }
    private var selectedDate: Date { selected ?? today }
    private var bucket: StatisticsBucket? { stats.calendarDays.first { calendar.isDate($0.key, inSameDayAs: selectedDate) }?.value }
    private var dates: [Date] {
        let count = calendar.range(of: .day, in: .month, for: monthStart)!.count
        return (0..<count).map { calendar.date(byAdding: .day, value: $0, to: monthStart)! }
    }
    private var leading: Int { (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7 }
    var body: some View {
        DashboardCard(title: "学習のカレンダー", subtitle: "日ごとの実績 · 選択中の対象 · 上の期間に依存しません") {
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10)) }.accessibilityLabel("前の月")
                Spacer()
                Text(monthStart.formatted(.dateTime.year().month())).font(.headline)
                Spacer()
                Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10)) }
                    .accessibilityLabel("次の月").disabled(calendar.isDate(monthStart, equalTo: today, toGranularity: .month))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                ForEach(0..<7, id: \.self) { index in
                    Text(calendar.veryShortWeekdaySymbols[(index + calendar.firstWeekday - 1) % 7]).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(0..<leading, id: \.self) { _ in Color.clear.frame(height: 44) }
                ForEach(dates, id: \.self) { date in
                    dayCell(date)
                }
            }
            Text("薄い → 濃い：回答数 0 / 1–9 / 10–29 / 30以上")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(selectedDate.formatted(.dateTime.month().day()) + "の実績").font(.headline)
                HStack {
                    Text("\(bucket?.cards ?? 0)枚").font(.title2.bold())
                    Spacer()
                    Text("\(bucket?.answers ?? 0)回答 · \((bucket?.durationMs ?? 0) / 60_000)分").font(.subheadline)
                }
                HStack {
                    ForEach(ReviewGrade.allCases, id: \.self) { grade in
                        VStack(spacing: 4) {
                            Text(String(describing: grade).capitalized).font(.caption).foregroundStyle(.secondary)
                            Text("\(bucket?.ratings[grade, default: 0] ?? 0)").font(.subheadline.weight(.semibold))
                        }.frame(maxWidth: .infinity)
                    }
                }
                if (bucket?.answers ?? 0) == 0 { Text("学習の記録はありません。").font(.subheadline).foregroundStyle(.secondary) }
            }.accessibilityIdentifier("calendarDetails").accessibilityElement(children: .combine)
            Text("学習日は\(store.settings.dayStartHour):00に切り替わります。時間は回答時間の合計です。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func dayCell(_ date: Date) -> some View {
        let entry = stats.calendarDays.first { calendar.isDate($0.key, inSameDayAs: date) }?.value
        let answers = entry?.answers ?? 0
        let chosen = calendar.isDate(date, inSameDayAs: selectedDate)
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { selected = date }
            store.haptics.play(.swipeReady, mode: store.settings.hapticsMode)
        } label: {
            Text("\(calendar.component(.day, from: date))")
                .font(.subheadline.weight(chosen ? .bold : .regular)).foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(answers == 0 ? Color(.tertiarySystemFill) : Color.teal.opacity(answers < 10 ? 0.18 : answers < 30 ? 0.38 : 0.65), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(chosen ? Color.accentColor : .clear, lineWidth: 2))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(calendar.startOfDay(for: date) > calendar.startOfDay(for: today))
            .accessibilityLabel(date.formatted(.dateTime.year().month().day()) + "、\(answers)回答、\(entry?.cards ?? 0)枚")
            .accessibilityAddTraits(chosen ? [.isSelected] : [])
            .accessibilityIdentifier("calendarDay-\(calendar.component(.day, from: date))")
    }
    private func move(_ offset: Int) {
        month = calendar.date(byAdding: .month, value: offset, to: monthStart)!
        selected = month
        store.haptics.play(.swipeReady, mode: store.settings.hapticsMode)
    }
}

struct DashboardForecastSection: View {
    let store: StudyStore
    let stats: StudyStatistics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var days = 7
    @State private var selection: Date?
    private var displayed: [ForecastDay] { Array(stats.scheduledDays.prefix(days)) }
    private var chosen: ForecastDay? {
        selection.flatMap { date in displayed.first { $0.start <= date && date < $0.end } } ?? displayed.first
    }
    var body: some View {
        DashboardCard(title: "これからの復習", subtitle: "現在保存されている期日 · 選択中の対象") {
            Picker("これからの期間", selection: $days) { Text("次の7日間").tag(7); Text("次の30日間").tag(30) }
                .pickerStyle(.segmented).accessibilityIdentifier("dashboardForecastPeriod")
            Text("\(displayed.reduce(0) { $0 + $1.scheduled })枚の予定").font(.title2.bold())
            Chart(displayed) { day in
                BarMark(x: .value("学習日", day.start, unit: .day), y: .value("保存済み期日", day.scheduled))
                    .foregroundStyle(chosen?.id == day.id ? Color.accentColor : Color.teal.opacity(0.45))
                    .accessibilityLabel(day.start.formatted(.dateTime.month().day()))
                    .accessibilityValue("\(day.scheduled)枚" + (chosen?.id == day.id ? "、選択中" : ""))
            }
            .chartXSelection(value: $selection)
            .frame(height: 150)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: days)
            if let chosen {
                Text(chosen.start.formatted(.dateTime.month().day()) + " · \(chosen.scheduled)枚")
                    .font(.headline).accessibilityIdentifier("forecastSelection")
            }
            // Buttons provide the same selection to VoiceOver and simple taps.
            ScrollView(.horizontal) {
                HStack {
                    ForEach(displayed) { day in
                        Button { selection = day.start } label: {
                            Text(day.start.formatted(.dateTime.month().day()) + " \(day.scheduled)枚")
                                .font(.caption).padding(.horizontal, 12).frame(minHeight: 44)
                                .background(chosen?.id == day.id ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemFill), in: Capsule())
                                .contentShape(Capsule())
                        }.accessibilityAddTraits(chosen?.id == day.id ? [.isSelected] : [])
                            .accessibilityIdentifier("forecastDay-\(displayed.firstIndex(where: { $0.id == day.id }) ?? 0)")
                    }
                }
            }.scrollIndicators(.hidden)
            Text("期限超過 \(stats.overdueCount)枚は今日に含みます。停止・休止は除外。将来の回答による追加復習は含まず、学習すると予定は変わります。")
                .font(.caption).foregroundStyle(.secondary)
            NavigationLink { ReviewForecastView(store: store) } label: {
                Label("条件付きの回答見込み・学習計画", systemImage: "arrow.up.right")
            }.accessibilityIdentifier("openReviewForecast")
            Text("詳細画面は独立したデッキ条件です。タグ条件は適用されません。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onChange(of: days) { _, _ in selection = nil }
        .onChange(of: selection) { _, _ in store.haptics.play(.swipeReady, mode: store.settings.hapticsMode) }
    }
}

struct MemoryInsightsSection: View {
    let store: StudyStore
    let stats: StudyStatistics
    var body: some View {
        DashboardCard(title: "記憶のコンディション", subtitle: "現在の推定と、過去の実測 · 選択中の対象") {
            NavigationLink { MemoryAnalysisView(store: store) } label: {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("思い出せる可能性（現在の推定）", value: stats.meanRetrievability.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "—")
                    if let report = stats.memory {
                        ForEach(Array(report.distributions.prefix(2))) { distribution in
                            LabeledContent(distribution.id, value: distribution.median.map { $0.formatted(.number.precision(.fractionLength(1))) + distribution.unit } ?? "—")
                        }
                        if let observed = report.retention.first(where: { $0.days == 30 }) {
                            LabeledContent("実際の保持率（過去30日）", value: observed.rate.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "—")
                            Text("\(observed.trials)試行 · 長期Reviewの最初の評価／カード／学習日").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Label("分布・定義・根拠カードを見る", systemImage: "arrow.up.right").font(.subheadline).foregroundStyle(Color.accentColor)
                }.font(.subheadline).foregroundStyle(.primary)
            }.buttonStyle(.plain).accessibilityIdentifier("openMemoryAnalysis")
            Text("安定度・覚えにくさは中央値。想起確率はFSRS推定、保持率は保存済み評価からの実測です。試行なしは「—」。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}


struct StudyInsightsSection: View {
    let store: StudyStore
    let insights: [StudyInsight]
    private var scope: String {
        let deck = store.statisticsScope.deckID.flatMap { id in store.decks.first { $0.id == id }?.name } ?? "すべてのデッキ"
        let tags = store.tags.filter { store.statisticsScope.tagIDs.contains($0.id) }.map(\.name)
        return deck + "（子孫を含む） · " + (tags.isEmpty ? "すべてのタグ" : tags.joined(separator: "、") + "（すべてを含む）")
    }
    var body: some View {
        if !insights.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("記録からの気づき").font(.headline)
                ForEach(insights) { insight in
                    NavigationLink {
                        StudyInsightEvidenceView(store: store, insight: insight, scope: insight.global ? "全デッキ共通・タグ絞り込みなし" : scope)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: insight.icon).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(insight.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Text(insight.explanation).font(.subheadline).foregroundStyle(.secondary)
                                Text(insight.global ? "全デッキ共通" : scope).font(.caption).foregroundStyle(.secondary)
                                Text(insight.start.formatted(.dateTime.month().day()) + "〜" + insight.end.formatted(.dateTime.month().day()))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                        }.padding(16).frame(minHeight: 44)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain).accessibilityIdentifier("insight-" + insight.id)
                }
            }
        }
    }
}

struct StudyInsightEvidenceView: View {
    let store: StudyStore
    let insight: StudyInsight
    let scope: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DashboardCard(title: insight.title, subtitle: scope) {
                    Text(insight.explanation)
                    Text("参考期間：" + insight.start.formatted(.dateTime.year().month().day().hour().minute()) + "〜" + insight.end.formatted(.dateTime.year().month().day().hour().minute()))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("タップ時の集計結果です。最新の結果は記録画面の更新で確認できます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                evidence
            }.padding(20)
        }.background(Color(.systemGroupedBackground)).navigationTitle("気づきの根拠").navigationBarTitleDisplayMode(.inline)
    }
    @ViewBuilder private var evidence: some View {
        switch insight.evidence {
        case .volume(let comparison):
            DashboardCard(title: "同じ長さの期間で比較", subtitle: "期間内のユニークCard ID数") {
                Chart {
                    BarMark(x: .value("期間", "前の期間"), y: .value("枚数", comparison.previous))
                    BarMark(x: .value("期間", "直近の期間"), y: .value("枚数", comparison.recent)).foregroundStyle(.teal)
                }.frame(height: 180)
                Text("前の期間：\(comparison.previous)枚（" + interval(comparison.previousStart, comparison.recentStart) + "）")
                Text("直近の期間：\(comparison.recent)枚（" + interval(comparison.recentStart, comparison.end) + "）")
                Text("各期間で同じカードへの回答は1枚と数えます。今日の未完了の学習日は除外し、両期間より前から記録がある場合だけ比較します。記録の削除後は残っている記録で再集計します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .forecast(let days, let peak):
            DashboardCard(title: "次の7日間の保存済み期日", subtitle: "停止カード・休止デッキを除外") {
                Chart(days) { day in
                    BarMark(x: .value("学習日", day.start, unit: .day), y: .value("枚数", day.scheduled))
                        .foregroundStyle(day.start == peak ? Color.accentColor : .teal)
                }.frame(height: 180)
                ForEach(days) { day in
                    Text(day.start.formatted(.dateTime.month().day()) + "：\(day.scheduled)枚" + (day.start == peak ? "（最多）" : ""))
                }
                Text("期限超過は今日に含みます。将来の回答による追加復習は含みません。同数の最多日は最初の日を表示します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .retention(let retention, let target):
            DashboardCard(title: "実測と設定目標", subtitle: "過去\(retention.days)日・\(retention.trials)対象試行") {
                Chart {
                    BarMark(x: .value("種類", "実測"), y: .value("割合", retention.rate ?? 0)).foregroundStyle(.teal)
                    BarMark(x: .value("種類", "設定目標"), y: .value("割合", target))
                }.chartYScale(domain: 0...1).frame(height: 180)
                Text("成功：\(retention.successes) / \(retention.trials)試行・対象カード\(retention.cardIDs.count)枚")
                Text("回答前がReview状態の、各カード・学習日の最初の回答だけが対象です。Hard / Good / Easyを成功とし、Againを含む全対象試行が分母です。20試行未満や複数の設定目標が混在する対象では表示しません。目標は現在の設定で、過去の設定やFSRS推定値ではありません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .streak(let days, let cards, let date):
            DashboardCard(title: "連続学習の節目", subtitle: "全デッキ共通") {
                Text("\(days)日連続・" + date.formatted(.dateTime.month().day()) + "は\(cards)枚")
                Text("1回以上の保存済み回答がある学習日を連続で数えます。今日も学習し、3 / 7 / 14 / 30 / 100日になった当日だけ表示します。Undo・削除後は残る回答で再集計します。")
                    .font(.caption).foregroundStyle(.secondary)
                NavigationLink("日ごとの回答・達成履歴を確認") { AchievementHistoryView(store: store) }
            }
        }
    }
    private func interval(_ start: Date, _ end: Date) -> String {
        start.formatted(.dateTime.month().day().hour().minute()) + "〜" + end.formatted(.dateTime.month().day().hour().minute()) + "未満"
    }
}
