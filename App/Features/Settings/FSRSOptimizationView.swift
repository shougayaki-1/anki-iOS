import SwiftUI
import UIKit

struct FSRSOptimizationView: View {
    @Bindable var store: StudyStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var presentation = FSRSOptimizationPresentation()
    @State private var worker: Task<OptimizationReport, Error>?
    @State private var failure: String?
    @State private var operationWarning: String?
    @State private var lastOperation: FSRSOptimizationOperation?
    @State private var unmetRequirements: [String] = []
    @State private var confirmingApply = false
    @State private var confirmingReset = false
    var body: some View {
        Form {
            Section {
                LabeledContent("現在の設定", value: presentation.statusText)
                    .accessibilityIdentifier("optimizationStatus")
                if let successNotice = presentation.successNotice {
                    Label(successNotice, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("optimizationSuccess")
                }
                if let readFailure = presentation.readFailure {
                    Label(readFailure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("optimizationReadFailure")
                    Button("設定状態を再確認") { _ = reload() }
                        .accessibilityIdentifier("retryOptimizationState")
                }
                Text("端末内の履歴を使って計算します。初回からの履歴、日をまたぐ復習400件、学習30日、20カード以上が必要です。最大1万件・60秒です。")
                Text("古い80%を学習用、残りを検証用に分けます。検証用80件以上で標準値よりLog lossが1%以上改善し、RMSEも悪化しない場合だけ適用できます。どちらの期間にも成功とAgainが5件以上必要です。")
                    .font(.footnote)
                if worker != nil {
                    ProgressView("端末内で計算中")
                    Button("計算をキャンセル", role: .cancel) { cancelCalculation() }
                } else {
                    Button("履歴から計算・比較") { calculate() }
                        .buttonStyle(SecondaryActionStyle())
                        .disabled(presentation.state == nil)
                        .accessibilityIdentifier("computeFSRSParameters")
                }
            } header: { Text("個人最適化") }
            if let report = presentation.state?.report {
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
                        .buttonStyle(PrimaryActionStyle())
                        .disabled(!presentation.canApply(report, computing: worker != nil))
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
                    .disabled(!presentation.canReset(computing: worker != nil))
                    .accessibilityIdentifier("resetFSRSParameters")
                Text("適用と撤回は次回の評価から有効です。既存の復習予定・学習状態・履歴は書き換えません。デッキ別の目標保持率は引き続き使います。結果と適用履歴は完全バックアップに含まれます。")
                    .font(.footnote)
            }
            if let state = presentation.state, !state.changes.isEmpty {
                Section("適用・撤回履歴（最新20回）") {
                    ForEach(Array(state.changes.reversed().enumerated()), id: \.offset) { _, change in
                        Text("\(change.date.formatted()) · \(change.after == nil ? "標準に戻した" : "個人設定を適用")")
                    }
                }
            }
            if let operationWarning = lastOperation?.warning ?? operationWarning {
                Section("設定の変更結果") {
                    Label(operationWarning, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("optimizationOperationWarning")
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
        .onAppear {
            // A success notice is only shown during its originating screen visit.
            presentation.successNotice = nil
            operationWarning = nil
            lastOperation = nil
            _ = reload()
        }
        .onDisappear {
            worker?.cancel()
            presentation.successNotice = nil
        }
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
            presentation.didRead(try store.repository.optimizationState())
            refreshOperationRead()
            return true
        } catch {
            presentation.readFailed("設定状態を確認できません。再確認してください。（\(error.localizedDescription)）")
            refreshOperationRead()
            return false
        }
    }

    private func refreshOperationRead() {
        guard var operation = lastOperation else { return }
        // Settings read only changes the read status; it never retries a write or home refresh.
        operation.recheck(presentation.state)
        lastOperation = operation
    }

    private func clearFeedback() {
        failure = nil
        presentation.successNotice = nil
        operationWarning = nil
        lastOperation = nil
        unmetRequirements = []
    }

    private func showSuccess(_ message: String) {
        presentation.successNotice = message
        // Exactly one feedback for a complete, verified operation; obey the haptics setting.
        store.haptics.play(.noteSaved, mode: store.settings.hapticsMode)
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    private func describeChange(
        kind: FSRSOptimizationOperation.Kind,
        expected: FSRSOptimizationOperation.Target,
        repositorySucceeded: Bool,
        homeReloadSucceeded: Bool
    ) {
        // perform=false may mean that only the home reload failed.
        let errorDetail = homeReloadSucceeded ? nil : store.failure
        _ = reload()
        let outcome = FSRSOptimizationPersistenceOutcome.classify(
            repositorySucceeded: repositorySucceeded,
            homeReloadSucceeded: homeReloadSucceeded,
            confirmedMatch: expected.matches(presentation.state)
        )
        lastOperation = FSRSOptimizationOperation(
            kind: kind, target: expected, outcome: outcome, errorDetail: errorDetail
        )
        if outcome.isComplete, let success = kind.successMessage {
            showSuccess(success)
        }
    }

    private func applyParameters() {
        clearFeedback()
        guard let verifiedState = presentation.state, let report = verifiedState.report,
              report.accepted, verifiedState.activeParameters != report.parameters else {
            operationWarning = "適用できる計算結果がありません。設定状態を再確認し、必要なら再計算してください。"
            return
        }
        var repositorySucceeded = false
        let homeReloadSucceeded = store.perform {
            try store.repository.applyOptimization(now: store.clock())
            repositorySucceeded = true
        }
        describeChange(kind: .apply, expected: .parameters(report.parameters),
                       repositorySucceeded: repositorySucceeded,
                       homeReloadSucceeded: homeReloadSucceeded)
    }

    private func resetParameters() {
        clearFeedback()
        guard let verifiedState = presentation.state, verifiedState.activeParameters != nil else {
            operationWarning = "現在の設定を確認できません。再確認してから操作してください。"
            return
        }
        var repositorySucceeded = false
        let homeReloadSucceeded = store.perform {
            try store.repository.resetOptimization(now: store.clock())
            repositorySucceeded = true
        }
        describeChange(kind: .reset, expected: .parameters(nil),
                       repositorySucceeded: repositorySucceeded,
                       homeReloadSucceeded: homeReloadSucceeded)
    }

    private func cancelCalculation() {
        worker?.cancel()
        failure = "計算をキャンセルしました。パラメータは変更していません。"
        unmetRequirements = []
    }

    private func presentCalculationFailure(_ error: Error, reviews: [OptimizationReview]? = nil) {
        presentation.successNotice = nil
        failure = FSRSOptimizationGuidance.failureDescription(error)
        unmetRequirements = []
        if let optimizationError = error as? OptimizationError,
           case .insufficient = optimizationError, let reviews {
            unmetRequirements = FSRSOptimizationGuidance.unmetRequirements(for: reviews)
        }
    }

    private func calculate() {
        clearFeedback()
        guard let verifiedState = presentation.state else {
            operationWarning = "設定状態を確認できません。再確認してから計算してください。"
            return
        }
        do {
            let reviews = try store.repository.optimizationReviews()
            // Keep the original eligibility guard before starting CPU work.
            do {
                _ = try FSRSOptimization.prepare(reviews)
            } catch {
                presentCalculationFailure(error, reviews: reviews)
                return
            }
            let previous = verifiedState.activeParameters, now = store.clock()
            let task = Task.detached(priority: .utility) {
                try FSRSOptimization.run(reviews, previous: previous, now: now)
            }
            worker = task
            Task { @MainActor in
                defer { worker = nil }
                do {
                    let report = try await task.value
                    guard !task.isCancelled else { return }
                    var repositorySucceeded = false
                    let homeReloadSucceeded = store.perform {
                        try store.repository.saveOptimizationReport(report)
                        repositorySucceeded = true
                    }
                    describeChange(kind: .report, expected: .report(report),
                                   repositorySucceeded: repositorySucceeded,
                                   homeReloadSucceeded: homeReloadSucceeded)
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

// Displayed settings are always based on a verified persistent state.
struct FSRSOptimizationPresentation {
    private(set) var state: FSRSOptimizationState?
    private(set) var readFailure: String?
    var successNotice: String?

    var statusText: String {
        guard let state else { return "未確認（再確認してください）" }
        return state.activeParameters == nil ? "標準パラメータ" : "個人パラメータ"
    }

    mutating func didRead(_ verifiedState: FSRSOptimizationState) {
        state = verifiedState
        readFailure = nil // Keep unrelated calculation failures intact.
    }

    mutating func readFailed(_ message: String) {
        state = nil // Cached parameters must not be presented as current.
        readFailure = message
        successNotice = nil
    }

    func canApply(_ report: OptimizationReport, computing: Bool) -> Bool {
        guard let state else { return false }
        return !computing && report.accepted && state.activeParameters != report.parameters
    }

    func canReset(computing: Bool) -> Bool {
        !computing && state?.activeParameters != nil
    }

    func matchesActiveParameters(_ expected: [Double]?) -> Bool? {
        guard let state else { return nil }
        return state.activeParameters == expected
    }

    func matchesReport(_ report: OptimizationReport) -> Bool? {
        guard let state else { return nil }
        return state.report == report
    }
}

struct FSRSOptimizationPersistenceOutcome: Equatable {
    enum Save: Equatable { case succeeded, failed }
    enum Home: Equatable { case succeeded, failed, notAttempted }
    enum Read: Equatable { case matched, mismatched, unavailable }

    let save: Save
    let home: Home
    var read: Read

    var isComplete: Bool { save == .succeeded && home == .succeeded && read == .matched }

    static func classify(repositorySucceeded: Bool, homeReloadSucceeded: Bool, confirmedMatch: Bool?) -> Self {
        Self(save: repositorySucceeded ? .succeeded : .failed,
             home: !repositorySucceeded ? .notAttempted : (homeReloadSucceeded ? .succeeded : .failed),
             read: readResult(confirmedMatch))
    }

    static func readResult(_ match: Bool?) -> Read {
        switch match {
        case .some(true): return .matched
        case .some(false): return .mismatched
        case .none: return .unavailable
        }
    }
}

// Only the latest operation on this screen visit is retained.
// A settings retry updates read, never the known save or home refresh outcome.
struct FSRSOptimizationOperation {
    enum Kind: CaseIterable {
        case apply, reset, report

        var title: String {
            switch self {
            case .apply: return "個人最適化"
            case .reset: return "標準設定への復帰"
            case .report: return "計算結果"
            }
        }

        var successMessage: String? {
            switch self {
            case .apply: return "個人最適化を適用しました。次回の回答から有効です"
            case .reset: return "標準パラメータに戻しました。次回の回答から有効です"
            case .report: return nil
            }
        }
    }

    enum Target {
        case parameters([Double]?)
        case report(OptimizationReport)

        func matches(_ state: FSRSOptimizationState?) -> Bool? {
            guard let state else { return nil }
            switch self {
            case .parameters(let expected): return state.activeParameters == expected
            case .report(let expected): return state.report == expected
            }
        }
    }

    let kind: Kind
    let target: Target
    var outcome: FSRSOptimizationPersistenceOutcome
    let errorDetail: String?

    mutating func recheck(_ state: FSRSOptimizationState?) {
        outcome.read = FSRSOptimizationPersistenceOutcome.readResult(target.matches(state))
    }

    var warning: String? {
        if outcome.isComplete { return nil }
        var messages: [String] = []
        switch outcome.save {
        case .failed:
            messages.append("\(kind.title)を保存できませんでした。")
        case .succeeded:
            if outcome.home == .failed {
                messages.append("\(kind.title)は保存されましたが、ホーム画面の更新に失敗しました。")
            } else if outcome.read == .unavailable {
                messages.append("\(kind.title)の保存処理は完了しましたが、設定状態を確認できません。")
            }
        }
        if outcome.read == .mismatched && outcome.save == .succeeded {
            messages.append("再取得した内容が予想と異なります。必要なら再計算してください。")
        }
        // The separate read failure remains retryable; a retry cannot clear save/home errors.
        if let errorDetail, outcome.save == .failed || outcome.home == .failed {
            messages.append(errorDetail)
        }
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }
}

// Read-only diagnostics. FSRSOptimization.prepare remains the authority for eligibility.
enum FSRSOptimizationGuidance {
    static func appliedConfirmation(expected: [Double], active: [Double]?) -> String? {
        guard active == expected else { return nil }
        return "個人最適化を適用しました。次回の回答から有効です"
    }

    static func resetConfirmation(wasPersonalized: Bool, active: [Double]?) -> String? {
        guard wasPersonalized && active == nil else { return nil }
        return "標準パラメータに戻しました。次回の回答から有効です"
    }

    static func failureDescription(_ error: Error) -> String {
        switch error as? OptimizationError {
        case .some(.insufficient):
            return "最適化の計算に必要な学習履歴の条件を満たしていません。復習を続けてから再計算してください。"
        case .some(.tooLarge):
            return "履歴が上限の1万件を超えたため、この機能では計算できません。履歴を削除せず、現在の設定を引き続き使用できます。"
        case .some(.stale):
            return "履歴または設定が計算時から変わりました。もう一度「履歴から計算・比較」を実行してください。"
        case .some(.invalid):
            return "履歴または計算結果を検証できませんでした。アプリを開き直して再試行してください。"
        case .some(.timedOut):
            return "計算が60秒の上限に達しました。端末の負荷が少ないときに再計算してください。"
        case .none:
            return "計算できませんでした。もう一度試してください。（\(error.localizedDescription)）"
        }
    }

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

