import SwiftUI
import SwiftData

struct Phase0View: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Phase0Probe.createdAt, order: .reverse) private var probes: [Phase0Probe]
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                Section("開発環境の検証") {
                    Label("SwiftUI / iOS 17以降", systemImage: "iphone")
                    Label("SwiftData / 端末内保存", systemImage: "externaldrive")
                    Label("FSRS-6 / 21パラメータ / 保持率90%", systemImage: "brain")
                    Text("Phase 0の検証画面です。学習機能は今後のPhaseで実装します。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("検証して保存", action: verify)
                        .accessibilityIdentifier("saveVerification")
                    Text("仮想日時で good → good → again → good を実行します。保存後にアプリを終了し、同じIDと状態が表示されることを確認してください。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let probe = probes.first {
                    Section("最新の保存結果") {
                        Text(probe.id.uuidString).font(.caption).textSelection(.enabled)
                            .accessibilityIdentifier("probeID")
                        Text("保存済み: \(probes.count)件")
                            .accessibilityIdentifier("probeCount")
                        Text(probe.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                        snapshotDetails(probe)
                    }
                } else {
                    Text("検証結果はまだありません")
                }
            }
            .navigationTitle("暗記アプリ · Phase 0")
            .alert("検証・保存に失敗しました", isPresented: Binding(
                get: { failure != nil }, set: { if !$0 { failure = nil } }
            )) {
                Button("再試行", action: verify)
                Button("閉じる", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }
    }

    @ViewBuilder
    private func snapshotDetails(_ probe: Phase0Probe) -> some View {
        if let result = try? details(probe) {
            Text(result).accessibilityIdentifier("probeState")
        } else {
            Label("保存データを読み取れません", systemImage: "exclamationmark.triangle")
        }
    }

    private func details(_ probe: Phase0Probe) throws -> String {
        let scheduler = try ReviewScheduler()
        let snapshot = try JSONDecoder().decode(SchedulerSnapshot.self, from: probe.snapshotData)
        let transitions = try JSONDecoder().decode([ReviewTransition].self, from: probe.transitionsData)
        let summary = try scheduler.summary(snapshot)
        let states = try transitions.map { try scheduler.summary($0.after).state }.joined(separator: " → ")
        return "\(states)\n状態: \(summary.state) / 回答: \(summary.repetitions) / 忘却: \(summary.lapses)\n次回: \(summary.dueDate.formatted())"
    }

    private func verify() {
        do {
            try ProbeRepository(context: context).saveVerification(now: Date(), scheduler: ReviewScheduler())
        } catch {
            failure = error.localizedDescription
        }
    }
}
