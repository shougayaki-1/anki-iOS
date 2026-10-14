import SwiftUI

struct ExamPlansHomeRow: View {
    @Bindable var store: StudyStore
    @State private var next: ExamPlan?
    var body: some View {
        Group {
            if let next {
                Section {
                    NavigationLink {
                        ExamPlansView(store: store)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("試験・目標", systemImage: "calendar")
                            let days = next.daysRemaining(now: store.clock())
                            Text("\(next.name) · \(days == 0 ? "試験当日" : "あと\(days)日")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task(id: store.dataRevision) { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in reload() }
    }
    private func reload() {
        next = (try? store.repository.options().examPlans)?.filter {
            $0.valid && $0.isActive && $0.daysRemaining(now: store.clock()) >= 0
        }.sorted { $0.daysRemaining(now: store.clock()) < $1.daysRemaining(now: store.clock()) }.first
    }
}

struct ExamPlansView: View {
    @Bindable var store: StudyStore
    @State private var plans: [ExamPlan] = []
    @State private var editing: ExamPlan?
    @State private var failure: String?
    var body: some View {
        List {
            Section {
                Text("試験日はFSRSの復習期限とは別です。計画の作成・変更・終了でカードや学習履歴は変わりません。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("試験・目標を作成", systemImage: "plus") {
                    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
                    let parts = calendar.dateComponents([.year, .month, .day], from: store.clock())
                    editing = ExamPlan(name: "", year: parts.year!, month: parts.month!, day: parts.day!, scope: store.scope)
                }.accessibilityIdentifier("createExamPlan")
            }
            ForEach(plans) { plan in
                NavigationLink {
                    ExamPlanDetailView(store: store, planID: plan.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plan.name)
                        Text(status(plan)).font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("examPlan-\(plan.id)")
            }
            if let failure { Text(failure).foregroundStyle(.red) }
        }
        .navigationTitle("試験・目標")
        .onAppear { reload() }
        .sheet(item: $editing, onDismiss: { reload() }) { ExamPlanEditor(store: store, initial: $0) }
    }
    private func status(_ plan: ExamPlan) -> String {
        guard plan.isActive else { return "終了" }
        let days = plan.daysRemaining(now: store.clock())
        return days < 0 ? "試験日を過ぎています" : days == 0 ? "試験当日" : "試験まであと\(days)日"
    }
    private func reload() {
        do {
            plans = try (store.repository.options().examPlans ?? []).sorted {
                if $0.isActive != $1.isActive { return $0.isActive }
                return ($0.date() ?? .distantFuture) < ($1.date() ?? .distantFuture)
            }; failure = nil
        } catch { failure = error.localizedDescription }
    }
}

private struct ExamPlanEditor: View {
    @Bindable var store: StudyStore
    @Environment(\.dismiss) private var dismiss
    @State private var plan: ExamPlan
    @State private var date: Date
    @State private var budget: Int
    @State private var usesBudget: Bool
    @State private var failure: String?
    init(store: StudyStore, initial: ExamPlan) {
        self.store = store
        _plan = State(initialValue: initial)
        _date = State(initialValue: initial.date() ?? store.clock())
        _budget = State(initialValue: initial.dailyMinutes ?? 20)
        _usesBudget = State(initialValue: initial.dailyMinutes != nil)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("計画") {
                    TextField("名称", text: $plan.name).accessibilityIdentifier("examPlanName")
                    DatePicker("試験日", selection: $date, displayedComponents: .date)
                    Toggle("計画を有効にする", isOn: $plan.isActive)
                }
                Section("対象範囲") {
                    if let id = plan.scope.deckID, !store.decks.contains(where: { $0.id == id }) {
                        Text("対象デッキは削除されています。選び直してください。")
                    }
                    DeckSelectionField("デッキ", decks: store.decks, selection: $plan.scope.deckID, nilTitle: "すべて", includesDescendants: true)
                    ForEach(store.tags) { tag in
                        Toggle(tag.name, isOn: Binding(get: { plan.scope.tagIDs.contains(tag.id) }, set: { selected in
                            plan.scope.tagIDs.removeAll { $0 == tag.id }
                            if selected { plan.scope.tagIDs.append(tag.id) }
                        }))
                    }
                    if plan.scope.tagIDs.contains(where: { id in !store.tags.contains(where: { $0.id == id }) }) {
                        Button("削除されたタグを範囲から外す") { plan.scope.tagIDs.removeAll { id in !store.tags.contains(where: { $0.id == id }) } }
                    }
                    Text("子孫デッキを含み、選択したタグをすべて持つカードが対象です。学習の案内はホームのフィルターも尊重します。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("任意の時間目安") {
                    Toggle("1日の時間目安を設定", isOn: $usesBudget)
                    if usesBudget { Stepper("\(budget)分", value: $budget, in: 1...1440, step: 5) }
                    Text("時間目安は学習を制限・強制しません。試験日が来てもデッキを自動休止しません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .environment(\.calendar, Calendar(identifier: .gregorian))
            .navigationTitle("試験・目標を編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(plan.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("saveExamPlan")
                }
            }
        }
    }
    private func save() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        plan.year = parts.year!; plan.month = parts.month!; plan.day = parts.day!
        plan.dailyMinutes = usesBudget ? budget : nil
        plan.name = plan.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try store.repository.saveExamPlan(plan); store.perform(metadata: false) {}; dismiss() }
        catch { failure = error.localizedDescription }
    }
}

private struct ExamPlanDetailView: View {
    @Bindable var store: StudyStore
    let planID: UUID
    @State private var plan: ExamPlan?
    @State private var report: ExamPlanReport?
    @State private var failure: String?
    @State private var editing: ExamPlan?
    @State private var generation = 0
    @State private var ending = false
    @State private var worker: Task<ExamPlanReport, Error>?
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        List {
            if let plan {
                Section {
                    Text(plan.name).font(.headline)
                    if let date = plan.date() { LabeledContent("試験日", value: date.formatted(date: .abbreviated, time: .omitted)) }
                    let days = plan.daysRemaining(now: store.clock())
                    Text(!plan.isActive ? "終了した計画" : days < 0 ? "試験日を過ぎています" : days == 0 ? "試験当日" : "試験まであと\(days)日")
                    Text("試験日はカレンダーの日付です。学習日は\(store.settings.dayStartHour)時で切り替わります。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let report {
                    Section("対象の現在の状態") {
                        if let scope = report.scope {
                            LabeledContent("デッキ（子孫含む）", value: scope.deckID.flatMap { id in store.decks.first { $0.id == id }?.name } ?? "すべて")
                            if !scope.tagIDs.isEmpty { Text("タグ: " + store.tags.filter { scope.tagIDs.contains($0.id) }.map(\.name).joined(separator: "、")) }
                        }
                        LabeledContent("対象（停止カードを除く）", value: "\(report.total)枚")
                        LabeledContent("未学習（休止デッキを除く）", value: "\(report.newCards)枚")
                        LabeledContent("現時点の期限到来", value: "\(report.dueCards)枚")
                        if report.pausedCards > 0 { LabeledContent("休止デッキ内", value: "\(report.pausedCards)枚") }
                        if let recall = report.recall {
                            LabeledContent("学習済み範囲の推定想起確率", value: recall.formatted(.percent.precision(.fractionLength(0))))
                            Text("安定性・最終復習を持つ復習状態の\(report.recallSamples)枚の現在の平均です。未学習・短期学習・休止は含まず、試験時の記憶を保証しません。")
                        } else { Text("推定想起確率を算出できる復習カードがありません。") }
                        Text("ホームのフィルターと交差する範囲です。期限到来は保存済み期限の数で、当日非表示・兄弟抑制・回答形式などにより今出題できる数とは異なります。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let notice = report.notice { Text(notice) }
                    }
                    if let forecast = report.forecast {
                        Section("条件付きの見通し") {
                            Text("今日から試験日末まで（最大90学習日、今回\(report.forecastDays)日）の推定")
                            LabeledContent("新規を進める見込み", value: "\(forecast.days.reduce(0) { $0 + $1.newCards })枚")
                            LabeledContent("期間後に残る未学習の見込み", value: "\(forecast.remainingNew)枚")
                            LabeledContent("復習回答の見込み", value: "\(forecast.days.reduce(0) { $0 + $1.reviews })回")
                            LabeledContent("直近7学習日の新規ペース", value: "\(report.recentNewPerDay.formatted(.number.precision(.fractionLength(1))))枚/日")
                            Text("直近ペースは今日を除く7日間の正式な新規カード数÷7（学習しなかった日も含む）です。今後も同じペースなら約\(Int(report.recentNewPerDay * Double(report.forecastDays)))枚が目安ですが、上限・対象の残数・休止などで変わります。")
                            if let seconds = forecast.medianAnswerSeconds {
                                Text("回答時間の目安: 合計\((Double(forecast.projectedAnswers) * seconds / 60).formatted(.number.precision(.fractionLength(0))))分。直近30日の対象回答時間中央値\(seconds.formatted(.number.precision(.fractionLength(1))))秒×回答見込みです。")
                            } else { Text("時間の推定に使える回答履歴がありません。") }
                            if let minutes = plan.dailyMinutes { Text("設定した1日の時間目安: \(minutes)分。読む時間・休憩・カード形式によって実際の所要時間は変わります。") }
                            Text("全デッキで毎日終了前に各カード1回・すべてGoodで正式学習する仮定です。新規上限、デッキ上限、兄弟抑制、当日非表示、今日の使用枠を反映します。試験当日の翌日0時までを含みます。試験時刻は設定しません。達成を保証しません。複数計画の数字は重複し得るため合計しません。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if plan.isActive, plan.daysRemaining(now: store.clock()) >= 0, let scope = report.scope, report.total > report.pausedCards {
                        Section("次の一手") {
                            Button("通常の期限到来復習（正式FSRS）") { start(.review, scope: scope) }
                                .buttonStyle(PrimaryActionStyle()).disabled(busy)
                            Button("未学習を進める（正式FSRS）") { start(.new, scope: scope) }
                                .buttonStyle(SecondaryActionStyle()).disabled(busy)
                            NavigationLink("試験対策の任意練習（記録しない）") {
                                CustomStudyView(store: store, initialCondition: CustomStudyCondition(scope: scope))
                            }.disabled(busy)
                            Text("練習のみではFSRS・期限・正式履歴を変更しません。カスタム学習画面で条件を確認して開始します。")
                                .font(.footnote).foregroundStyle(.secondary)
                            if busy { Text("中断した学習・練習をホームまたはカスタム学習で再開・終了してください。") }
                        }
                    }
                } else if failure == nil { ProgressView("見通しを計算中…") }
                Section {
                    Button("計画を編集") { editing = plan }.accessibilityIdentifier("editExamPlan")
                    if plan.isActive { Button("計画を終了") { ending = true }.accessibilityIdentifier("endExamPlan") }
                }
            }
            if let failure { Text(failure).foregroundStyle(.red); Button("再試行") { refresh() } }
        }
        .navigationTitle("試験・目標の詳細")
        .toolbar { Button("更新", systemImage: "arrow.clockwise") { refresh() } }
        .onAppear { refresh() }
        .onDisappear { generation += 1; worker?.cancel() }
        .onChange(of: store.dataRevision) { _, _ in refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } else { worker?.cancel() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refresh() }
        .sheet(item: $editing, onDismiss: { refresh() }) { ExamPlanEditor(store: store, initial: $0) }
        .confirmationDialog("計画を終了しますか？カード・履歴は保持し、デッキの休止状態は変えません。", isPresented: $ending) {
            Button("計画を終了") {
                guard var plan else { return }; plan.isActive = false
                do { try store.repository.saveExamPlan(plan); store.perform(metadata: false) {}; refresh() }
                catch { failure = error.localizedDescription }
            }.accessibilityIdentifier("confirmEndExamPlan")
        }
        .task {
            var previousDay = StudyDay(startHour: store.settings.dayStartHour).interval(containing: store.clock()).start
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                let day = StudyDay(startHour: store.settings.dayStartHour).interval(containing: store.clock()).start
                if day != previousDay { previousDay = day; refresh() }
            }
        }
    }
    private var busy: Bool { store.review != nil || ((try? store.repository.options().customPractice) != nil) }
    private func start(_ mode: StudyMode, scope: LearningScope) {
        guard !busy else { return }
        if store.perform(metadata: false, changed: false, {
            try store.repository.start(mode: mode, scope: scope, now: store.clock())
        }) { store.showingReview = true }
        else { failure = store.failure }
    }
    private func refresh() {
        worker?.cancel(); generation += 1
        let token = generation; report = nil; failure = nil
        do {
            guard let selected = try store.repository.options().examPlans?.first(where: { $0.id == planID }) else { throw StudyError.missingRecord }
            plan = selected
            let data = try BackupData.capture(store.repository), scope = try store.repository.homeScope()
            let now = store.clock(), calendar = Calendar.current
            let task = Task.detached(priority: .utility) { try ExamPlanReport.calculate(plan: selected, data: data, homeScope: scope, now: now, calendar: calendar) }
            worker = task
            Task { @MainActor in
                do {
                    let value = try await task.value
                    guard token == generation, !task.isCancelled else { return }
                    report = value
                } catch {
                    guard token == generation, !task.isCancelled else { return }
                    failure = error.localizedDescription
                }
            }
        } catch { failure = error.localizedDescription }
    }
}
