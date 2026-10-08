import SwiftUI
import SwiftData

struct SettingsView: View {
    @Bindable var store: StudyStore
    let probeContainer: ModelContainer

    var body: some View {
        NavigationStack {
            Form {
                Section("学習") {
                    Stepper("1日の新規上限: \(store.settings.dailyNewLimit)枚", value: Binding(
                        get: { store.settings.dailyNewLimit }, set: { value in update { $0.dailyNewLimit = value } }
                    ), in: 0...500)
                    Toggle("学習目標を有効にする", isOn: Binding(
                        get: { store.settings.dailyGoal != nil }, set: { value in update { $0.dailyGoal = value ? 20 : nil } }
                    ))
                    if let goal = store.settings.dailyGoal {
                        Stepper("目標: \(goal)枚", value: Binding(get: { store.settings.dailyGoal ?? 20 }, set: { value in
                            update { $0.dailyGoal = value }
                        }), in: 1...500)
                    }
                    Stepper("学習日切替: \(store.settings.dayStartHour)時", value: Binding(
                        get: { store.settings.dayStartHour }, set: { value in update { $0.dayStartHour = value } }
                    ), in: 0...23)
                }
                Section("関連カード") {
                    Toggle("同じノートの兄弟カードを同日抑制", isOn: Binding(
                        get: { store.settings.siblingBuryEnabled }, set: { value in update { $0.siblingBuryEnabled = value } }
                    ))
                    Text("短期学習・再学習は例外です。復習予定そのものは変更しません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("FSRS-6") {
                    Slider(value: Binding(get: { store.settings.desiredRetention }, set: { value in
                        update { $0.desiredRetention = value }
                    }), in: 0.8...0.97, step: 0.01) {
                        Text("目標保持率")
                    }
                    Text("目標保持率: \(Int((store.settings.desiredRetention * 100).rounded()))%")
                    Text("変更は次の回答から適用されます。既存の復習予定は変わりません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("開発検証") {
                    NavigationLink("Phase 0検証") { Phase0View().modelContainer(probeContainer) }
                }
            }.navigationTitle("設定")
        }
    }
    private func update(_ edit: (inout StudySettings) -> Void) {
        var settings = store.settings; edit(&settings)
        store.perform { try store.repository.updateSettings(settings) }
    }
}
