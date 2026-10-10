# Issue #42 数値設定の直接入力

2026-10-10（日本時間）。SwiftUIのTextField・FocusState・キーボードToolbarのApple公式ドキュメントをContext7で取得してから実装した。

## 変更

新規上限・学習目標・学習日切替・FSRS保持率に共通の数値入力行を追加。編集中はStringの下書きだけを更新し、「完了」で検証・保存する。入力消去も保存を伴わない。キャンセル・フォーカス移動・画面離脱では保存済みの値へ戻す。不正値はクランプせず、行内に理由を表示する。Repositoryの新規上限・目標にも共通の500枚上限を適用した。

目標OFF→ONは同じ画面内で直前の保存値を復元する。OFFで再訪した場合は従来どおり20枚。保存失敗では保存値を保持し、保存後の画面更新失敗と区別する。データ形式・マイグレーションは追加せず、旧バックアップの許容範囲も維持した。

画像マスクにも%の直接入力を追加。小数%を保持し、位置＋寸法100%以内・幅と高さ1%以上を検証する。Sliderとドラッグを維持し、座標欄をFormの独立した行にしてラベルの重なりを防ぐ。最大文字サイズではラベルと入力欄を縦に並べ、数字と単位の幅を確保する。

## 検証

最終コード: iPhone 17 Pro / iOS 26.5 Simulator、96件中95件成功・失敗0・スキップ1（単体／結合91件＋UI4件成功）。[集計](issue42-test-summary.json)。前段ではiPhone SE (3rd generation) / iOS 26.5でも設定の入力・ホーム更新・再起動保持・最大文字サイズ・ダーク表示を確認した。最終の画像マスクと数字・単位の表示は[マスク画面](issue42/mask-input.png)と[最大文字サイズ・ダーク画面](issue42/largest-type-dark.png)で目視確認した。

キーボード表示時の `Invalid frame dimension (negative or non-finite).` 警告4件は集計に残した。最終画像で数値の欠け・マスク操作行の重なりがないことを確認。テスト完了後の `simctl diagnose --timeout=600` が待機を続けたため、その診断収集プロセスだけを停止した。xcodebuildは終了コード0、`TEST SUCCEEDED`で正常終了。テスト本体は停止していない。結果 `/private/tmp/anki-issue42-complete.xcresult`、ログ `/private/tmp/anki-issue42-complete.log`、Releaseログ `/private/tmp/anki-issue42-release-final.log` は一時ファイル。

- 単体／結合: 整数設定の境界値、空欄・負数・小数・数字以外・桁あふれ・範囲外の拒否、マスクx=80%/幅20%の許容とx=90%の拒否、小数座標の保持、保存失敗時のロールバック、ホーム新規枠の更新、保持率変更時のdue・FSRS履歴保全、既存バックアップの復元を検証。
- UI: 新規上限200/10/0/500、目標200/1/500とOFF/ON、日切替0/23、保持率80/90/97、キャンセル・エラー・再起動保持、ホームから上限変更、最大文字サイズ・ダークモード、マスク直接入力・不正値拒否・保存後の再起動を検証。
- Release: `generic/platform=iOS`、arm64、署名なしビルド成功。実機インストールや実機動作を確認した結果ではない。

再現コマンド（destinationは利用可能なシミュレーターIDに置換）:

```sh
xcodebuild test -project AnkiIOS.xcodeproj -scheme AnkiIOS \
  -destination 'platform=iOS Simulator,id=<ID>' -parallel-testing-enabled NO \
  -derivedDataPath /private/tmp/anki-issue42-final \
  -only-testing:AnkiIOSTests \
  -only-testing:AnkiIOSUITests/StudyUITests/testNumericSettingsDirectInputValidationCancellationAndRelaunch \
  -only-testing:AnkiIOSUITests/StudyUITests/testNewLimitNavigationRefreshAndRelaunch \
  -only-testing:AnkiIOSUITests/StudyUITests/testNumericSettingsLargestTypeAndDarkMode \
  -only-testing:AnkiIOSUITests/GeneratedCardUITests/testMaskDirectPercentageValidationAndPersistence \
  CODE_SIGNING_ALLOWED=NO
```

## 未確認

実機、iOS 17ランタイム、VoiceOver音声、実際の通知再配信、Slider・画像ドラッグの実機での操作感は未確認。UIテストには通常データと分離したUUIDの保存領域と生成画像を使った。実機専用の通知診断テストは明示的な実行指定がないためスキップする。Issueは実機確認が終わるまで閉じない。
