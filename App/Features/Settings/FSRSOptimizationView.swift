import SwiftUI
import UIKit

struct FSRSOptimizationView: View {
    @Bindable var store: StudyStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = FSRSOptimizationState()
    @State private var worker: Task<OptimizationReport, Error>?
    @State private var failure: String?
    @State private var successNotice: String?
    @State private var unmetRequirements: [String] = []
    @State private var confirmingApply = false
    @State private var confirmingReset = false
    var body: some View {
        Form {
            Section {
                LabeledContent("現在の設定", value: state.activeParameters == nil ? "標準パラメータ" : "個人パラメータ")
                    .accessibilityIdentifier("optimizationStatus")
                if let successNotice {
                    Label(successNotice, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("optimizationSuccess")
                }
                Text("端末内の履歴を使って計算します。初回からの履歴、日をまたぐ復習400件、学習30日、20カード以上が必要です。最大1万件・60秒です。")
                Text("古い80%を学習用、残りを検証用に分けます。検証用80件以上で標準値よりLog lossが1%以上改善し、RMSEも悪化しない場合だけ適用できます。どちらの期間にも成功とAgainが5件以上必要です。")
                    .font(.footnote)
                if worker != nil {
                    ProgressView("端末内で計算中")
                    Button("計算をキャンセル", role: .cancel) { cancelCalculation() }
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
                    if report.accepted {
                        Label("比較条件を満たしました。適用前に履歴と設定の変更も確認します。", systemImage: "checkmark.circle")
                            .accessibilityIdentifier("optimizationDecision")
                    } else {
                        Label("比較条件を満たさなかったため、現在の設定を維持します。計算失敗や履歴不足ではありません。", systemImage: "info.circle")
                            .accessibilityIdentifier("optimizationDecision")
                    }
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
            if let failure {
                Section("計算・設定の案内") {
                    Label(failure, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("optimizationFailure")
                    ForEach(unmetRequirements, id: \.self) { requirement in
                        Text(requirement)
                    }
                }
            }
        }
        .navigationTitle("FSRS個人最適化")
        .onAppear { reload() }
        .onDisappear { worker?.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { worker?.cancel() } }
        .confirmationDialog("個人パラメータを適用しますか？", isPresented: $confirmingApply, titleVisibility: .visible) {
            Button("適用") { applyParameters() }
        } message: { Text("次回の評価から使用します。現在の復習予定は変更しません。") }
        .confirmationDialog("標準パラメータに戻しますか？", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("標準に戻す") { resetParameters() }
        } message: { Text("次回の評価から標準設定を使用します。現在の復習予定は変更しません。") }
    }
    @discardableResult
    private func reload() -> Bool {
        do {
            state = try store.repository.optimizationState()
            return true
        } catch {
            failure = "設定状態を読み込めませんでした。画面を開き直して確認してください。（\(error.localizedDescription)）"
            return false
        }
    }

    private func clearFeedback() {
        failure = nil
        successNotice = nil
        unmetRequirements = []
    }

    private func showSuccess(_ message: String) {
        failure = nil
        successNotice = message
        unmetRequirements = []
        // Only one success event per confirmed state transition; the service respects "off".
        store.haptics.play(.noteSaved, mode: store.settings.hapticsMode)
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    private func applyParameters() {
        clearFeedback()
        guard let report = state.report, report.accepted,
              state.activeParameters != report.parameters else {
            failure = "適用できる計算結果がありません。履歴から再計算してください。"
            return
        }
        guard store.perform({ try store.repository.applyOptimization(now: store.clock()) }) else {
            failure = "個人最適化の適用を確認できませんでした。\(store.failure ?? "設定を再表示して確認してください。")"
            return
        }
        guard reload() else { return }
        guard state.activeParameters == report.parameters else {
            failure = "適用中の設定を確認できませんでした。画面を開き直して確認してください。"
            return
        }
        showSuccess("個人最適化を適用しました。次回の回答から有効です")
    }

    private func resetParameters() {
        clearFeedback()
        guard state.activeParameters != nil else {
            failure = "すでに標準パラメータを使用中です。"
            return
        }
        guard store.perform({ try store.repository.resetOptimization(now: store.clock()) }) else {
            failure = "標準設定への復帰を確認できませんでした。\(store.failure ?? "設定を再表示して確認してください。")"
            return
        }
        guard reload() else { return }
        guard state.activeParameters == nil else {
            failure = "標準設定への復帰を確認できませんでした。画面を開き直して確認してください。"
            return
        }
        showSuccess("標準パラメータに戻しました。次回の回答から有効です")
    }

    private func cancelCalculation() {
        worker?.cancel()
        failure = "計算をキャンセルしました。パラメータは変更していません。"
        unmetRequirements = []
    }

    private func presentCalculationFailure(_ error: Error, reviews: [OptimizationReview]? = nil) {
        successNotice = nil
        unmetRequirements = []
        switch error as? OptimizationError {
        case .some(.insufficient):
            failure = "最適化の計算に必要な学習履歴の条件を満たしていません。復習を続けてから再計算してください。"
            if let reviews {
                unmetRequirements = FSRSOptimizationGuidance.unmetRequirements(for: reviews)
            }
        case .some(.tooLarge):
            failure = "履歴が上限の1万件を超えたため、この機能では計算できません。履歴を削除せず、現在の設定を引き続き使用できます。"
        case .some(.stale):
            failure = "履歴または設定が計算時から変わりました。もう一度「履歴から計算・比較」を実行してください。"
        case .some(.invalid):
            failure = "履歴または計算結果を検証できませんでした。アプリを開き直して再試行してください。"
        case .some(.timedOut):
            failure = "計算が60秒の上限に達しました。端末の負荷が少ないときに再計算してください。"
        case .none:
            failure = "計算できませんでした。もう一度試してください。（\(error.localizedDescription)）"
        }
    }

    private func calculate() {
        clearFeedback()
        do {
            let reviews = try store.repository.optimizationReviews()
            // Keep the original eligibility guard before starting CPU work.
            do {
                _ = try FSRSOptimization.prepare(reviews)
            } catch {
                presentCalculationFailure(error, reviews: reviews)
                return
            }
            let previous = state.activeParameters, now = store.clock()
            let task = Task.detached(priority: .utility) {
                try FSRSOptimization.run(reviews, previous: previous, now: now)
            }
            worker = task
            Task { @MainActor in
                defer { worker = nil }
                do {
                    let report = try await task.value
                    guard !task.isCancelled else { return }
                    guard store.perform({ try store.repository.saveOptimizationReport(report) }) else {
                        failure = "計算結果を保存・確認できませんでした。\(store.failure ?? "設定を再表示してください。")"
                        return
                    }
                    _ = reload()
                } catch is CancellationError {
                    if failure == nil {
                        failure = "計算を中止しました。パラメータは変更していません。"
                    }
                } catch {
                    if !task.isCancelled { presentCalculationFailure(error) }
                }
            }
        } catch {
            presentCalculationFailure(error)
        }
    }
}

// Read-only diagnostics. FSRSOptimization.prepare remains the authority for eligibility.
enum FSRSOptimizationGuidance {
    static func unmetRequirements(for reviews: [OptimizationReview]) -> [String] {
        let ordered = reviews.sorted {
            $0.date == $1.date ? $0.sequence < $1.sequence : $0.date < $1.date
        }
        let groups = Dictionary(grouping: ordered, by: \.cardID)
        let completeCards = Set(groups.compactMap {
            $0.value.first?.startsNew == true ? $0.key : nil
        })
        let events = ordered.filter { completeCards.contains($0.cardID) }
        var last: [UUID: Date] = [:]
        var eligible: [OptimizationReview] = []
        for event in events {
            if !event.startsNew, let date = last[event.cardID],
               event.date.timeIntervalSince(date) >= 86400 {
                eligible.append(event)
            }
            last[event.cardID] = event.date
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let days = Set(events.map { calendar.startOfDay(for: $0.date) }).count
        let cards = Set(eligible.map(\.cardID)).count
        var messages: [String] = []
        if eligible.count < 400 {
            messages.append("判定対象の復習は現在\(eligible.count)件です（必要400件）。前回回答から24時間以上空いた回答が対象です。")
        }
        if days < 30 {
            messages.append("初回記録のあるカードの学習日は現在\(days)日です（必要30日）。")
        }
        if cards < 20 {
            messages.append("判定対象の復習をしたカードは現在\(cards)枚です（必要20枚）。")
        }
        if events.count < reviews.count {
            messages.append("初回からの履歴が確認できないカードの回答は、判定対象から除外されます。")
        }

        // The same timestamp-based 80/20 boundary as prepare; do not predict future counts.
        if eligible.count >= 400 && days >= 30 && cards >= 20 {
            let split = eligible[Int(Double(eligible.count) * 0.8) - 1].date
            let training = eligible.filter { $0.date <= split }
            let validation = eligible.filter { $0.date > split }
            if training.count < 320 {
                messages.append("学習用の復習は現在\(training.count)件です（必要320件）。")
            }
            if validation.count < 80 {
                messages.append("検証用の復習は現在\(validation.count)件です（必要80件）。同時刻の回答は分割されません。")
            }
            for (title, segment) in [("学習用", training), ("検証用", validation)] {
                let again = segment.filter { $0.grade == 1 }.count
                let recalled = segment.count - again
                if again < 5 || recalled < 5 {
                    messages.append("\(title)の評価はAgain \(again)件・それ以外\(recalled)件です（それぞれ5件以上必要）。記憶状態に合わせて回答してください。")
                }
            }
        }
        return messages
    }
}

