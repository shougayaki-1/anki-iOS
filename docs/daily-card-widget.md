# 今日の1枚（Issue #230）

既存の「復習と今日の進捗」と別のSmall / Medium Widget。問題を見て頭の中で回答し、「アプリで答えを見る」からカード確認画面へ進む。確認画面では答えを表示・非表示にでき、明示的に「このカードを正式に復習」を選ぶと通常の4段階評価とUndoへ進む。中断中セッションがある場合は上書きせず、先に既存の学習を完了するよう案内する。

## 選定と更新

- アプリのホームで選択中のデッキ・子孫デッキ・タグを使用。Widgetごとの対象設定は今回追加しない。
- 既存ReviewQueueBuilderのreviewキューを優先。期限到来なしの場合はnewキューを使用。停止・休止・一時非表示・兄弟カード埋没・グローバル/階層の新規上限を適用する。
- 同一期日の並びだけUUIDで固定する。Widget再描画で再選定しない。アプリの保存・学習・設定変更・更新時に再生成するため、正式回答後は次の対象へ進む。
- 問題は最大500文字、デッキパスは120文字。表示行数を制限し、長文の全文や画像マスクはアプリの正式学習画面へ誘導する。
- 次のホーム更新時刻または学習日境界の早い方まで有効。期限後は古い問題・完了状態を残さず「アプリを開いて更新」にする。OSが更新を遅らせる場合がある。
- 対象0件は「今の学習はひと区切り」。新規カードの制限や選択スコープによる0件を、全デッキの復習完了と誤表示しない。

## データ保護とプライバシー

既存App Group内のatomicなprogress-v1.jsonに任意フィールドを追加。旧スナップショットも読み取れる。進捗Widgetの既存schemaVersionと集計は維持する。Extensionは小さなスナップショットを読むだけで、SwiftData・FSRS・全件カード/履歴にアクセスしない。

共有するのはカードID・デッキ名・表示用問題・有効期限のみ。**答えは共有しない**。プレビューは架空の問題を使用し、問題にprivacySensitiveを指定する。ロック画面のWidgetサイズは提供しない。ホーム画面の問題自体は表示されるので、内容を隠したい場合は従来の進捗Widgetを利用する。

カード確認と答え表示は読み取り専用。正式復習開始時にカードの存在・対象条件を再確認し、既存startのトランザクションで指定カードを選択する。保存失敗時はロールバックし、ReviewLog・FSRS状態・達成記録を変更しない。復習結果の保存とUndoは従来処理を使用する。

## App Intentsの検討と今回のフォールバック

iOS 17のButton(intent:)は実装可能であり、APIの非対応を理由としたフォールバックではない。今回のStaticConfiguration/共有ファイル構成では、共有の解答表示フラグとreloadTimelinesを使うと、同じ設定の複数Widgetに解答が表示される。独立したインスタンスの識別/設定とロック時の認証・解答状態失効までを導入すると構成変更が広がるため、初版はIssueで許容されているDeep Link方式を採用した。

Widget内に解答表示状態を保存せず、**「アプリで答えを見る」**と明示する。複数Widget間で解答状態が混ざらず、再起動・更新・日跨ぎでも答えを自動露出しない。Widget内での表示/非表示操作は未実装。App Intentsによる完結操作は将来検討であり、#231〜#234は変更しない。

参考: [Apple: Adding interactivity](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)、[Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)。実装前にContext7のWidget ExamplesでiOS 17 AppIntent / App Group / Timelineの例を確認した。

## 検証

iPhone 15 Pro Simulator / iOS 26.5、Debugビルド成功。関連Unitテスト35件（ReviewQueueTests 23、WidgetSnapshotTests 11、既存の評価/Undo保存失敗テスト1）が成功。UIではSmall/Mediumギャラリー、既存進捗Widget両サイズ、ホームへのMedium追加、実際のWidgetの解答リンク、解答の表示/非表示、正式復習、対象外ID、空状態、ライト/ダークを確認した。画像は `docs/assets/issue230/`。

実機、iOS 17実行、ロック中、機内モード切替、長文のホーム配置、OSによる長時間の更新遅延は未確認。日跨ぎ・期限・階層上限・兄弟埋没は関連Unitで確認し、実時間を跨いだSimulator放置検証は行っていない。Widgetのリロード時刻はOSに委ねられる。
