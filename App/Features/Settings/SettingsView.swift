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
                StudySettingsSection(store: store)
                Section("ウィジェット") {
                    Text("ホーム画面の追加メニューから「暗記ノート」を選べます。全デッキの件数と進捗のみ共有し、問題文・答えは共有しません。更新の頻度や時刻はiOSが制御します。")
                        .font(.footnote)
                    Button("ウィジェットの更新をリクエスト") { store.refreshWidget() }.accessibilityIdentifier("refreshWidget")
                    if let failure = store.widgetFailure { Text(failure).font(.footnote) }
                }
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
                    NumericSettingRow(title: "目標保持率", value: String(Int((store.settings.desiredRetention * 100).rounded())),
                                      unit: "%", identifier: "desiredRetention") { text in
                        guard let percent = NumericSettingsInput.integer(text, in: StudySettings.retentionPercentRange) else {
                            return .invalid("80〜97の整数を入力してください。")
                        }
                        return store.updateSettings { $0.desiredRetention = Double(percent) / 100 } ? nil : .saveFailed
                    }
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
                Section {
                    Picker("英語音声", selection: Binding(
                        get: { store.settings.speech.accent },
                        set: { accent in update { $0.speech.accent = accent } }
                    )) {
                        ForEach(SpeechAccent.allCases) { accent in Text(accent.title).tag(accent) }
                    }.accessibilityIdentifier("speechAccent")
                    Picker("読み上げの速さ", selection: Binding(
                        get: { store.settings.speech.pace },
                        set: { pace in update { $0.speech.pace = pace } }
                    )) {
                        ForEach(SpeechPace.allCases) { pace in Text(pace.title).tag(pace) }
                    }.accessibilityIdentifier("speechPace")
                    NavigationLink("デッキ別の自動読み上げ") { DeckSpeechSettingsView(store: store) }
                    Text("既存デッキはすべてオフです。音声はiOS標準機能を使い、消音スイッチを尊重します。再生速度は倍率ではありません。")
                        .font(.footnote).foregroundStyle(Color("SecondaryText"))
                } header: { Text("英文読み上げ") }.headerProminence(.increased)
                Section { Button("バックアップ・復元") { backup = true }.accessibilityIdentifier("openBackup") } header: { Text("データ").foregroundStyle(Color("SecondaryText")) }.headerProminence(.increased)
                #if DEBUG
                Section {
                    NavigationLink("Phase 0検証") { Phase0View().modelContainer(probeContainer) }
                } header: { Text("開発検証").foregroundStyle(Color("SecondaryText")).accessibilityIdentifier("settingsDevelopmentHeader") }.headerProminence(.increased)
                #endif
            }.scrollDismissesKeyboard(.interactively).navigationTitle("設定")
                .sheet(isPresented: $backup) { BackupView(store: store) }
        }
    }
    private func update(_ edit: (inout StudySettings) -> Void) {
        store.updateSettings(edit)
    }
}

struct StudySettingsSection: View {
    @Bindable var store: StudyStore
    @State private var lastGoal = 20
    var body: some View {
        Section {
            NumericSettingRow(title: "1日の新規上限", value: String(store.settings.dailyNewLimit), unit: "枚", identifier: "dailyNewLimit") { text in
                save(text, range: StudySettings.newLimitRange) { $0.dailyNewLimit = $1 }
            }
            Text("0〜500枚。0枚では新規カードを学習しません。")
                .font(.footnote).foregroundStyle(Color("SecondaryText"))
            Toggle("学習目標を有効にする", isOn: Binding(
                get: { store.settings.dailyGoal != nil }, set: { enabled in
                    if let goal = store.settings.dailyGoal { lastGoal = goal }
                    store.updateSettings { $0.dailyGoal = enabled ? lastGoal : nil }
                }
            )).accessibilityIdentifier("dailyGoalToggle")
            if let goal = store.settings.dailyGoal {
                NumericSettingRow(title: "学習目標", value: String(goal), unit: "枚", identifier: "dailyGoal") { text in
                    save(text, range: StudySettings.goalRange) { $0.dailyGoal = $1 }
                }
            }
            Text("目標は1〜500枚。オフにすると未確定の入力を取り消し、この画面では直前の保存値でオンに戻します。再訪時は20枚です。目標達成後も学習できます。")
                .font(.footnote).foregroundStyle(Color("SecondaryText"))
            NumericSettingRow(title: "学習日切替", value: String(store.settings.dayStartHour), unit: "時", identifier: "dayStartHour") { text in
                save(text, range: StudySettings.dayStartRange) { $0.dayStartHour = $1 }
            }
            Text("0〜23時（0＝午前0時、23＝午後11時）。学習日の境界で、通知時刻とは別です。")
                .font(.footnote).foregroundStyle(Color("SecondaryText"))
            Text("数値は「完了」で保存します。キャンセル・別の欄への移動・画面離脱では未確定の入力を取り消します。")
                .font(.footnote).foregroundStyle(Color("SecondaryText"))
        } header: { Text("学習").foregroundStyle(Color("SecondaryText")) }.headerProminence(.increased)
            .onAppear { lastGoal = store.settings.dailyGoal ?? 20 }
    }
    private func save(_ text: String, range: ClosedRange<Int>, edit: (inout StudySettings, Int) -> Void) -> NumericSettingError? {
        guard let value = NumericSettingsInput.integer(text, in: range) else {
            return .invalid("\(range.lowerBound)〜\(range.upperBound)の整数を入力してください。")
        }
        return store.updateSettings { edit(&$0, value) } ? nil : .saveFailed
    }
}

struct StudySettingsView: View {
    @Bindable var store: StudyStore
    var body: some View {
        Form {
            StudySettingsSection(store: store)
            Section {
                Text("新規上限は全デッキ・全モード共通です。変更しても今日の学習履歴は保持します。学習目標の達成後も学習できます。")
            }
        }.scrollDismissesKeyboard(.interactively).navigationTitle("学習設定")
    }
}


/// Kept out of DeckManagerView to avoid coupling speech with folder-tree edits.
private struct DeckSpeechSettingsView: View {
    @Bindable var store: StudyStore
    var body: some View {
        Form {
            ForEach(store.decks) { deck in
                Picker(deck.name, selection: Binding(
                    get: { store.settings.speech.deckAutoplay[deck.id.uuidString] ?? .off },
                    set: { value in
                        _ = store.updateSettings {
                            if value == .off { $0.speech.deckAutoplay.removeValue(forKey: deck.id.uuidString) }
                            else { $0.speech.deckAutoplay[deck.id.uuidString] = value }
                        }
                    }
                )) {
                    ForEach(SpeechAutoplay.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .accessibilityIdentifier("deckSpeech-\(deck.id.uuidString)")
            }
            Text("デッキごとに独立して設定します。カードで個別設定した場合はそちらを優先します。子デッキには自動継承されません。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("デッキ別読み上げ")
    }
}
