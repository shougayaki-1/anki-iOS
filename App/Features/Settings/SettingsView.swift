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
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "暗記ノート")
                                .font(.headline).accessibilityIdentifier("appDisplayName")
                            Text("覚える、思い出す、少しずつ。")
                                .font(.subheadline).foregroundStyle(Color("SecondaryText"))
                        }
                    } icon: {
                        Image(systemName: "rectangle.on.rectangle").foregroundStyle(Color("AccentColor"))
                            .accessibilityHidden(true)
                    }
                    Text("カードと学習履歴は端末内に保存します。機種変更の前にバックアップを書き出してください。")
                        .font(.footnote).foregroundStyle(Color("SecondaryText"))
                }
                Section {
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
                } header: { Text("学習").foregroundStyle(Color("SecondaryText")) }.headerProminence(.increased)
                Section {
                    Toggle("同じノートの兄弟カードを同日抑制", isOn: Binding(
                        get: { store.settings.siblingBuryEnabled }, set: { value in update { $0.siblingBuryEnabled = value } }
                    ))
                    Text("短期学習・再学習は例外です。復習予定そのものは変更しません。")
                        .font(.footnote).foregroundStyle(Color("SecondaryText"))
                } header: { Text("関連カード").foregroundStyle(Color("SecondaryText")) }.headerProminence(.increased)
                Section {
                    Slider(value: Binding(get: { store.settings.desiredRetention }, set: { value in
                        update { $0.desiredRetention = value }
                    }), in: 0.8...0.97, step: 0.01) {
                        Text("目標保持率")
                    }
                    Text("目標保持率: \(Int((store.settings.desiredRetention * 100).rounded()))%")
                    Text("変更は次の回答から適用されます。既存の復習予定は変わりません。")
                        .font(.footnote).foregroundStyle(Color("SecondaryText"))
                } header: { Text("FSRS-6").foregroundStyle(Color("SecondaryText")) }.headerProminence(.increased)
                Section {
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
                        .font(.footnote).foregroundStyle(Color("SecondaryText"))
                } header: { Text("通知").foregroundStyle(Color("SecondaryText")) }.headerProminence(.increased)
                Section {
                    Picker("フィードバック", selection: Binding(get: { store.settings.hapticsMode }, set: { value in update { $0.hapticsMode = value } })) {
                        ForEach(HapticsMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("答え表示・評価・Undo・目標達成で控えめに反応します。「豊か」は対応実機の目標達成時にカスタムパターンを使います。")
                        .font(.footnote).foregroundStyle(Color("SecondaryText"))
                } header: { Text("触覚").foregroundStyle(Color("SecondaryText")) }.headerProminence(.increased)
                Section {
                    Toggle("スワイプ操作を有効にする", isOn: Binding(
                        get: { store.settings.reviewAppearance.gesturesEnabled },
                        set: { enabled in update { $0.reviewAppearance.gesturesEnabled = enabled } }
                    )).accessibilityIdentifier("reviewGesturesToggle")
                    Picker("文字サイズ", selection: Binding(
                        get: { store.settings.reviewAppearance.textSize },
                        set: { value in update { $0.reviewAppearance.textSize = value } }
                    )) {
                        ForEach(ReviewTextSize.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("reviewTextSize")
                    Picker("画像の表示", selection: Binding(
                        get: { store.settings.reviewAppearance.imageDisplay },
                        set: { value in update { $0.reviewAppearance.imageDisplay = value } }
                    )) {
                        ForEach(ReviewImageDisplay.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("reviewImageDisplay")
                    Toggle(isOn: Binding(
                        get: { store.settings.reviewAppearance.answerFirst },
                        set: { value in update { $0.reviewAppearance.answerFirst = value } }
                    )) { Text("解答を先に表示").fixedSize(horizontal: false, vertical: true) }
                    .accessibilityIdentifier("reviewAnswerFirst")
                    Toggle("学習時のアニメーション", isOn: Binding(
                        get: { store.settings.reviewAppearance.animationsEnabled },
                        set: { value in update { $0.reviewAppearance.animationsEnabled = value } }
                    )).accessibilityIdentifier("reviewAnimationsToggle")
                    Text("解答の表示順は答え表示後に適用します。スワイプは専用領域で操作し、VoiceOver使用中はボタンを使います。画像マスクは常に表示し、端末の文字サイズと「視差効果を減らす」設定を反映します。")
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.footnote).foregroundStyle(Color("SecondaryText"))
                } header: { Text("学習画面").foregroundStyle(Color("SecondaryText")) }.headerProminence(.increased)
                Section { Button("バックアップ・復元") { backup = true }.accessibilityIdentifier("openBackup") } header: { Text("データ").foregroundStyle(Color("SecondaryText")) }.headerProminence(.increased)
                #if DEBUG
                Section {
                    NavigationLink("Phase 0検証") { Phase0View().modelContainer(probeContainer) }
                } header: { Text("開発検証").foregroundStyle(Color("SecondaryText")).accessibilityIdentifier("settingsDevelopmentHeader") }.headerProminence(.increased)
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
