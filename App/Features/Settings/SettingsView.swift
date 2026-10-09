import SwiftUI
import SwiftData

struct SettingsView: View {
    @Bindable var store: StudyStore
    let probeContainer: ModelContainer
    @Environment(\.openURL) private var openURL
    @State private var requestingNotification = false
    @State private var backup = false

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
                Section("通知") {
                    Toggle("復習が必要な日だけ通知", isOn: Binding(get: { store.settings.notification.enabled }, set: { enabled in
                        Task {
                            requestingNotification = true
                            defer { requestingNotification = false }
                            await store.setNotificationEnabled(enabled)
                        }
                    })).disabled(requestingNotification).accessibilityIdentifier("notificationToggle")
                    LabeledContent("予約通知", value: "\(store.scheduledNotificationCount)件").accessibilityIdentifier("notificationCount")
                    DatePicker("通知時刻", selection: Binding(get: {
                        Calendar.current.date(bySettingHour: store.settings.notification.hour, minute: store.settings.notification.minute, second: 0, of: store.clock()) ?? store.clock()
                    }, set: { date in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                        update { $0.notification.hour = parts.hour ?? 20; $0.notification.minute = parts.minute ?? 0 }
                    }), displayedComponents: .hourAndMinute)
                    if store.settings.notification.enabled && store.notificationPermission == .denied {
                        Text("通知権限がありません。設定アプリで許可してください。")
                        Button("設定アプリを開く") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                    }
                    if let failure = store.notificationFailure {
                        Text(failure).foregroundStyle(.red)
                        Button("通知を再計画", action: store.scheduleNotifications)
                    }
                    Text("新規カードだけでは通知しません。今後30日分を予約し、学習・Undo・予定変更・起動時に更新します。長期間アプリを開かない場合の補充や、iOSの配信時刻は保証されません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("触覚") {
                    Picker("フィードバック", selection: Binding(get: { store.settings.hapticsMode }, set: { value in update { $0.hapticsMode = value } })) {
                        ForEach(HapticsMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("答え表示・評価・Undo・目標達成で控えめに反応します。「豊か」は対応実機の目標達成時にカスタムパターンを使います。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("データ") { Button("バックアップ・復元") { backup = true }.accessibilityIdentifier("openBackup") }
                #if DEBUG
                Section("開発検証") {
                    NavigationLink("Phase 0検証") { Phase0View().modelContainer(probeContainer) }
                }
                #endif
            }.navigationTitle("設定")
                .sheet(isPresented: $backup) { BackupView(store: store) }
        }
    }
    private func update(_ edit: (inout StudySettings) -> Void) {
        var settings = store.settings; edit(&settings)
        store.perform { try store.repository.updateSettings(settings) }
    }
}
