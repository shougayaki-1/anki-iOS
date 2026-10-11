import SwiftUI

struct FSRSOptimizationView: View {
    @Bindable var store: StudyStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = FSRSOptimizationState()
    @State private var worker: Task<OptimizationReport, Error>?
    @State private var failure: String?
    @State private var confirmingApply = false
    @State private var confirmingReset = false
    var body: some View {
        Form {
            Section {
                Text(state.activeParameters == nil ? "標準パラメータを使用中" : "個人パラメータを使用中")
                    .accessibilityIdentifier("optimizationStatus")
                Text("端末内の履歴を使って計算します。初回からの履歴、日をまたぐ復習400件、学習30日、20カード以上が必要です。最大1万件・60秒です。")
                Text("古い80%を学習用、残りを検証用に分けます。検証用80件以上で標準値よりLog lossが1%以上改善し、RMSEも悪化しない場合だけ適用できます。どちらの期間にも成功とAgainが5件以上必要です。")
                    .font(.footnote)
                if worker != nil {
                    ProgressView("端末内で計算中")
                    Button("計算をキャンセル", role: .cancel) { worker?.cancel() }
                } else {
                    Button("履歴から計算・比較") { calculate() }.accessibilityIdentifier("computeFSRSParameters")
                }
            } header: { Text("個人最適化") }
            if let report = state.report {
                Section("検証結果") {
                    LabeledContent("計算日時", value: report.generatedAt.formatted())
                    LabeledContent("履歴", value: "\(report.reviews)件・\(report.days)日")
                    LabeledContent("検証用", value: "\(report.standard.count)件")
                    LabeledContent("標準 Log loss", value: report.standard.logLoss.formatted(.number.precision(.fractionLength(4))))
                    LabeledContent("個人 Log loss", value: report.candidate.logLoss.formatted(.number.precision(.fractionLength(4))))
                    LabeledContent("標準 RMSE", value: report.standard.rmse.formatted(.number.precision(.fractionLength(4))))
                    LabeledContent("個人 RMSE", value: report.candidate.rmse.formatted(.number.precision(.fractionLength(4))))
                    if let previous = report.previous {
                        LabeledContent("前の個人 Log loss", value: previous.logLoss.formatted(.number.precision(.fractionLength(4))))
                        LabeledContent("前の個人 RMSE", value: previous.rmse.formatted(.number.precision(.fractionLength(4))))
                    }
                    Text(report.accepted ? "比較条件を満たしました。適用前に履歴と設定の変更も確認します。" : "比較条件を満たさないため、適用しません。現在の設定を継続します。")
                        .accessibilityIdentifier("optimizationDecision")
                    Button("この結果を適用") { confirmingApply = true }
                        .disabled(!report.accepted || worker != nil || state.activeParameters == report.parameters)
                        .accessibilityIdentifier("applyFSRSParameters")
                    DisclosureGroup("21個のパラメータ") {
                        ForEach(Array(report.parameters.enumerated()), id: \.offset) { index, value in
                            LabeledContent("w[\(index)]", value: value.formatted(.number.precision(.fractionLength(4))))
                        }
                    }
                }
            }
            Section {
                Button("標準設定に戻す") { confirmingReset = true }
                    .disabled(state.activeParameters == nil || worker != nil).accessibilityIdentifier("resetFSRSParameters")
                Text("適用と撤回は次回の評価から有効です。既存の復習予定・学習状態・履歴は書き換えません。デッキ別の目標保持率は引き続き使います。結果と適用履歴は完全バックアップに含まれます。")
                    .font(.footnote)
            }
            if !state.changes.isEmpty {
                Section("適用・撤回履歴（最新20回）") {
                    ForEach(Array(state.changes.reversed().enumerated()), id: \.offset) { _, change in
                        Text("\(change.date.formatted()) · \(change.after == nil ? "標準に戻した" : "個人設定を適用")")
                    }
                }
            }
            if let failure { Section { Text(failure).foregroundStyle(.red).accessibilityIdentifier("optimizationFailure") } }
        }
        .navigationTitle("FSRS個人最適化")
        .onAppear { reload() }
        .onDisappear { worker?.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { worker?.cancel() } }
        .confirmationDialog("個人パラメータを適用しますか？", isPresented: $confirmingApply, titleVisibility: .visible) {
            Button("適用") {
                if store.perform({ try store.repository.applyOptimization(now: store.clock()) }) { reload() }
            }
        } message: { Text("次回の評価から使用します。現在の復習予定は変更しません。") }
        .confirmationDialog("標準パラメータに戻しますか？", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("標準に戻す") {
                if store.perform({ try store.repository.resetOptimization(now: store.clock()) }) { reload() }
            }
        } message: { Text("次回の評価から標準設定を使用します。現在の復習予定は変更しません。") }
    }
    private func reload() {
        do { state = try store.repository.optimizationState() }
        catch { failure = error.localizedDescription }
    }
    private func calculate() {
        failure = nil
        do {
            let reviews = try store.repository.optimizationReviews(), previous = state.activeParameters, now = store.clock()
            // Check the eligibility before starting CPU work, without capturing SwiftData objects.
            _ = try FSRSOptimization.prepare(reviews)
            let task = Task.detached(priority: .utility) { try FSRSOptimization.run(reviews, previous: previous, now: now) }
            worker = task
            Task { @MainActor in
                defer { worker = nil }
                do {
                    let report = try await task.value
                    guard !task.isCancelled else { return }
                    if store.perform({ try store.repository.saveOptimizationReport(report) }) { reload() }
                } catch is CancellationError {
                    failure = "計算を中止しました。設定は変更されていません。"
                } catch { failure = error.localizedDescription }
            }
        } catch { failure = error.localizedDescription }
    }
}
