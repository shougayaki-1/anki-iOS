# PR統合検証（2026-10-11、日本時間）

対象：#70、#71、#73、#74、#75、#76、#77、#78、#80、#81、#82、#83、#84、#85、#86、#87。
依存PRを先にmainへマージし、後続PRのbaseをmainへ変更。各競合は既存機能と追加機能を保持して解消し、関連テストを実施した。

## 最終統合候補の検証

- iPhone 17 Pro / iOS 26.5：全単体・結合228件、227成功、既存の実機専用1件スキップ、失敗0。
- iPhone UI3件成功：画像ZIP100枚のFiles取込・学習・Undo・再起動、CSVのFiles取込・破損バックアップ拒否、ライブラリ選択終了・検索・取消時の対象保持。
- iPad Pro 13-inch (M5) / iOS 26.5：#86統合時の全単体・結合224件、223成功、既存1件スキップ、失敗0。階層絞込みとサイドバー・回転・編集・学習のUI2件成功。
- 最終Mac Catalyst Releaseビルド成功（署名なし、arm64 / x86_64）。
- git diff --check成功。

## 主な競合解消

- 回答形式設定・デッキ新規枠・個人FSRS設定・回答本文保存を保持。評価時の本文保存と新規枠消費、Undo時の双方の取消を同じトランザクション内に維持。
- 縦書き面設定と両面音声IDを編集・プレビュー・保存・反転で保持。
- 登録数表示と苦手練習導線、iPadデッキ絞込みと選択モード・キーボード追加操作を保持。
- iOSのWidget App Group権限とMac専用署名設定を保持。iOSウィジェットの依存・埋込みをiOSだけに限定し、Macへの異なるプラットフォームの拡張埋込みを防止。
- MacのCSV/TSV/TXT入力確認と画像ZIPのFiles取込を両立。

## 結果ファイル

一時ファイルのため永続保管は保証しない。

- `/private/tmp/anki-merge87-final.xcresult`
- `/private/tmp/anki-merge87-ui.xcresult`
- `/private/tmp/anki-merge86.xcresult`
- `/private/tmp/anki-merge86-ui.xcresult`
- `/private/tmp/anki-merge87-mac-final.log`

Simulatorの起動拒否が発生した実行は成功件数に含めず、再実行の成功結果を記載。
各PRに記録された実機・旧OS・配布署名・Mac UI等の未確認事項は本統合検証では解消していない。
