# Issue #110 検証

2026-10-11（日本時間）、Xcode 27.0、iPhone 17 Pro / iOS 26.5 Simulator。

- ReviewQueueTests 11件・StudyRepositoryTests 50件、計61件成功。日次4時境界・目標・上限・フィルター・保存失敗・Undoを含む。
- StudyUITestsのホーム回答上限変更/中断再開、復習ワンタップ開始/進捗配置/説明重複除去/ヘルプ表示の2件成功。
- Debug Simulatorテストビルド、Release iOS（署名なし）ビルド成功。
- home.pngで進捗がモードより上、主CTAが初期表示内、長文が繰り返されないことを目視確認。
- 実機・VoiceOver音声・最大Dynamic Typeは今回未検証。

結果バンドル `/private/tmp/anki-issue110-tests.xcresult`、ログ `/private/tmp/anki-issue110-tests.log`、Releaseログ `/private/tmp/anki-issue110-release.log`。一時ファイルの永続保持は保証しない。

追加回帰検証：iPhone 17 Pro Max / iOS 26.5で `testHomeParentDeckAndMultipleTagsApplyResetAndMixedMode` 成功。親デッキ＋複数タグAND、リセット、混合開始と中断再開、新規件数表示を確認（結果 `/private/tmp/anki-issue110-filter-tests.xcresult`）。
