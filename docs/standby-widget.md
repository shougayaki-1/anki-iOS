# StandBy「ながら暗記」 (#232)

StandByで「今日の1枚」のSmallを追加する。隣の時計・Streakやスタックの選択はOSと利用者に委ねる。新しいWidget、学習エンジン、設定操作は追加しない。

## 表示

iOS 17以上の `showsWidgetContainerBackground` がfalse、かつsystemSmallのときだけ、短い見出し → 大きな問題 → 「タップして確認」の順に表示する。これはStandBy判定専用APIではなく背景除去の環境値なので、同じ条件の他コンテキストにも適用する。通常ホーム画面のSmall/Mediumは従来の表示を維持。

デッキ名を省き、問題全体が入る28pt、次に24ptを `ViewThatFits` で選ぶ。全文が収まらない長文・画像カードは「アプリで問題を見る」へ切り替え、断片を問題として表示しない。空状態と期限切れは別の文言・記号で案内する。

背景は既存 `containerBackground(for: .widget)` 内に置き、OSによる除去を許可する。本文はprimary、補助情報はsecondaryで、独自の赤背景や夜間モードを作らない。夜間の赤系vibrant表示、アクセント単色化はOSに任せ、色だけで状態を表さない。

## 共通処理とデータ保護

DailyCardProvider、WidgetBundle、App Groupの問題のみのsnapshot、期限、#230のデッキ・タグ・期限到来優先・停止/休止除外処理をそのまま使用する。編集・削除・評価後の更新も既存publisher経由。表示によるReviewLog・FSRS・Streak・目標・SwiftDataの変更はない。共有ファイルに答えを追加しない。

タップは既存カード確認URL（答え非表示）へ進み、答え・正式評価・Undoはアプリ内。既存セッションの保護処理も変更しない。Widgetの更新タイミングはOSが制御し、即時反映は保証しない。Timerや常駐処理なし。手動の次カードApp Intentは共有snapshotを使う複数Widgetの選択を同時変更し、Extensionでの選定・状態管理を増やすため採用しない。

## ロック中のプライバシー

問題領域に既存同様 `privacySensitive()` を指定し、システムがprivacy redactionを要求した場合に隠す。これは常にロック中の問題を隠す保証ではない。StandByはロック中にも見えるため、設定によって問題が周囲に見られる可能性がある。機微な問題を表示したくない場合は「今日の1枚」をStandByへ追加せず、問題を共有しない進捗Widgetを使う。ロック解除・アプリ遷移の制限はOS標準動作に従う。

## 検証

- アプリ＋ExtensionのDebug Simulatorビルド成功。
- 関連WidgetSnapshotTests 13件成功（選定、対象範囲、Deep Link、共有内容、学習DB不変等）。全テストは未実行。
- iPhone 15 Pro / iOS 26.5 Simulator上の一時描画アプリで、製品のViewを174pt角で描画。短い英単語、一問一答、長文、画像、空、期限切れのライト/ダークを目視確認。通常ホームMediumの描画も確認。画像は [ライト](assets/issue232/layout-light.png)、[ダーク](assets/issue232/layout-dark.png)。ImageRendererによるレイアウト確認画像であり、StandBy実画面のスクリーンショットではない。
- 通常Smallは表示コードの維持を差分確認し、[短文・空状態の描画](assets/issue232/home-small.png)も確認（描画用コピーでfamilyのみ指定）。実際のホーム配置・WidgetKitによる背景除去の切替・タップ遷移は今回未確認。
- **実機確認なし**。充電横置き、時計/Streakとの実2列配置、夜間の赤系・低輝度、アクセントレンダリング、ロック時の秘匿/解除/タップ、電源再接続、長時間のOS更新遅延は未確認。Simulator描画では代替できない。

## UX評価

短文は見出しやデッキ名より大きく、机からの一瞥で問題を読める構成。長文・画像は問題の意味を失う省略を避けて案内する。単色でも問題・案内・空状態は文字と記号で区別できる。答えを見るまでの操作は既存のタップ1回のまま。通常ホーム表示は維持。遠距離・夜間の最終評価は実機で必要。

## 参照

- [Apple: StandByとCarPlay](https://developer.apple.com/documentation/widgetkit/adding-standby-and-carplay-support-to-your-widget)
- [追加コンテキストとレンダリング](https://developer.apple.com/documentation/widgetkit/preparing-widgets-for-additional-contexts-and-appearances)
- [背景の環境値](https://developer.apple.com/documentation/swiftui/environmentvalues/showswidgetcontainerbackground)
- [privacySensitive](https://developer.apple.com/documentation/swiftui/view/privacysensitive(_:))
- [Widget更新制限](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)

実装前にContext7のWidget Examplesも確認し、APIの意味は上記Apple公式資料とSDKで確認した。
