import SwiftUI
import Charts

struct ReviewForecastView: View {
    @Bindable var store: StudyStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var days = 7
    @State private var deckID: UUID?
    @State private var report: ReviewForecast?
    @State private var failure: String?
    @State private var loading = false
    @State private var worker: Task<ReviewForecast, Error>?
    @State private var generation = 0
    @State private var visible = false
    var body: some View {
        List {
            Section("予測条件") {
                Picker("期間", selection: $days) {
                    Text("7日").tag(7); Text("30日").tag(30)
                }.pickerStyle(.segmented).accessibilityIdentifier("forecastPeriod")
                Picker("デッキ（子孫を含む）", selection: $deckID) {
                    Text("すべてのデッキ").tag(UUID?.none)
                    ForEach(store.decks) { Text($0.name).tag(Optional($0.id)) }
                }.accessibilityIdentifier("forecastDeck")
                Text("確定済み期日は現在の予定です。見込みは、全デッキで毎日学習日終了前に各カード1回・すべてGoodと仮定した回答数です。2つの数値は重複するため合計しません。")
                    .font(.footnote)
                Text("新規は古い順、全体とデッキの上限・兄弟カード抑制を使用します。今日の使用枠を反映します。今日回答済みのカードと短期学習の同日再回答は含まず、実際の学習量は増減します。")
                    .font(.footnote)
            }
            if loading { Section { ProgressView("復習量を予測しています…") } }
            if let failure {
                Section { Text(failure).foregroundStyle(.red); Button("再試行") { refresh() } }
            }
            if let report {
                Section("期間の合計") {
                    LabeledContent("確定済み期日", value: "\(report.scheduled)枚").accessibilityIdentifier("forecastScheduled")
                    LabeledContent("現在の期限超過", value: "\(report.overdue)枚")
                    LabeledContent("回答の見込み", value: "\(report.projectedAnswers)回").accessibilityIdentifier("forecastAnswers")
                    LabeledContent("期間後も残る新規の見込み", value: "\(report.remainingNew)枚")
                    if let seconds = report.medianAnswerSeconds {
                        LabeledContent("直近30日の回答時間中央値", value: "\(seconds.formatted(.number.precision(.fractionLength(1))))秒")
                        Text("時間の見込みは中央値×回答数です。読む・考える長さやカード形式で変わります。")
                    } else { Text("回答時間の見込みには直近30日の履歴が必要です。") }
                    if let goal = report.dailyGoal {
                        Text("現在の学習目標は全デッキ共通で1日\(goal)枚です。新規上限や回答回数の上限とは異なり、予測を制限しません。")
                    } else { Text("学習目標はオフです。") }
                }
                Section("復習量の推移") {
                    Chart(report.days) { day in
                        BarMark(x: .value("学習日", day.start, unit: .day), y: .value("件数", day.scheduled))
                            .foregroundStyle(by: .value("種別", "確定済み期日（枚）"))
                            .position(by: .value("種別", "確定済み期日（枚）"))
                        BarMark(x: .value("学習日", day.start, unit: .day), y: .value("件数", day.projectedAnswers))
                            .foregroundStyle(by: .value("種別", "回答見込み（回）"))
                            .position(by: .value("種別", "回答見込み（回）"))
                    }.frame(height: 200).accessibilityHidden(true)
                    Text("回答見込みには新規・既存期日・学習後の追加復習を含みます。停止中は除外します。")
                        .font(.footnote)
                }
                Section("日ごとの数値") {
                    ForEach(report.days) { day in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(day.start.formatted(.dateTime.month().day()))
                            Text("確定期日 \(day.scheduled)枚 · 新規 \(day.newCards)枚 · 復習見込み \(day.reviews)回")
                            if let minutes = day.minutes { Text("時間見込み \(minutes.formatted(.number.precision(.fractionLength(1))))分") }
                        }.accessibilityElement(children: .combine)
                    }
                }
                Section("計算について") {
                    Text("学習日は\(store.settings.dayStartHour)時で切り替わります。期日超過は今日にまとめます。回答・Undo・新規追加・設定変更後の再訪、期間やデッキの変更、時刻・時間帯の変更後に再計算します。")
                    Text("この画面は復習予定・FSRS・履歴・設定を変更しません。")
                    Text("計算日時: \(report.generatedAt.formatted())")
                }.font(.footnote)
            }
        }
        .navigationTitle("復習負荷予測")
        .toolbar { Button("更新", systemImage: "arrow.clockwise") { refresh() }.accessibilityIdentifier("refreshForecast") }
        .onAppear { visible = true; refresh() }
        .onDisappear { visible = false; generation += 1; worker?.cancel() }
        .onChange(of: store.dataRevision) { _, _ in refresh() }
        .onChange(of: days) { _, _ in refresh() }
        .onChange(of: deckID) { _, _ in refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } else { worker?.cancel() } }
        .task {
            // Recompute on study-day/timezone changes while this screen remains visible.
            var dayStart = StudyDay(startHour: store.settings.dayStartHour).interval(containing: store.clock()).start
            var zone = TimeZone.current.identifier
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                let current = StudyDay(startHour: store.settings.dayStartHour).interval(containing: store.clock()).start
                if current != dayStart || zone != TimeZone.current.identifier { dayStart = current; zone = TimeZone.current.identifier; refresh() }
            }
        }
    }
    private func refresh() {
        guard visible else { return }
        worker?.cancel(); generation += 1
        let token = generation
        report = nil; failure = nil; loading = true
        do {
            let data = try BackupData.capture(store.repository), now = store.clock(), calendar = Calendar.current
            let selected = deckID, period = days
            let task = Task.detached(priority: .utility) {
                try ReviewForecast.calculate(data: data, deckID: selected, days: period, now: now, calendar: calendar)
            }
            worker = task
            Task { @MainActor in
                do {
                    let value = try await task.value
                    guard generation == token && !task.isCancelled else { return }
                    report = value; loading = false
                } catch {
                    guard generation == token && !task.isCancelled else { return }
                    failure = error.localizedDescription; loading = false
                }
            }
        } catch { failure = error.localizedDescription; loading = false }
    }
}
