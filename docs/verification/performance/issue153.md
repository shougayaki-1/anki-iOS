# Issue #153 — 評価・Undo・開始の履歴取得

## 対象と変更

変更前に独立したSQLiteストア（1,000穴埋めノート/3,000カード/10,000過去履歴）で開始→評価→Undoを3回測定。全履歴取得2回とキュー投影6回が確認されたため、全履歴走査と重複キューを削減した。

- 新規評価の上限判定は評価対象のQueueCardと当日履歴を使用。兄弟カードのID、グローバル上限、親デッキ上限を維持。
- 当日履歴の保存済み上限スナップショットを優先。旧ログのfallbackは当日参照カード・ノートのみ400 IDずつ取得し、現デッキ祖先へ対応する。
- 開始は検証済みキューの先頭を再利用。カード・履歴を変更していない範囲でのみ共有する。
- counts/学習空状態も当日履歴へ限定。空状態はpresentationに渡したカードDTOを共有。
- 永続モデル・FSRS計算・評価保存/Undoのトランザクションを変更しない。新たな常駐モデルキャッシュは導入しない。

## 測定結果

2026-10-12、iPhone 17 Pro / iOS 26.5 Simulator、Debug。各値は3回の最小〜最大、時間はms。基準/最終とも同じfixture・計測コード。キュー件数と履歴件数はリポジトリAPIの計測で、内部SQL/fault問い合わせ数ではない。

| 項目 | 変更前 | 変更後 |
| --- | ---: | ---: |
| Repository開始 | 464.50〜471.11 | 96.20〜99.08 |
| Store評価＋画面投影 | 578.31〜614.64 | 214.20〜217.68 |
| Store Undo＋画面投影 | 157.23〜158.67 | 112.43〜113.14 |
| 1巡の全履歴取得 | 2回 | 0回 |
| 1巡の履歴取得行数 | 20,002行 | 2行 |
| 1巡のキュー投影 | 6回 | 4回 |
| 1巡のキュー投影時間 | 289.20〜300.33 | 185.98〜188.21 |
| 1巡のFSRS状態decode | 2回 | 2回 |

開始はRepository API、評価/UndoはStore API。時間に描画fps/通知debounce完了は含まれない。通知とWidgetの投影APIは維持し、Store更新経路を変更していない。

関連StudyRepositoryTests 53件・ReviewQueueTests 12件・規模回帰1件、合計66件成功。Debugビルド成功。上限継承/移動/Undo/旧履歴fallback/日境界/兄弟抑制/待機/セッション残数/保存失敗の既存回帰を含む。Releaseでは追加計測カウンターをコンパイルしない。

再現: `xcodebuild test`に`-only-testing:AnkiIOSTests/ScaleRepositoryTests/testReviewHotPathThreeThousandCardsTenThousandLogs`を指定。ログの`REVIEW_HOT_PATH`を確認する。

## 未完了の受け入れ項目

SCW-iPhone（iPhone 15 Pro）はdevicectl上でunavailable。実機3,000枚の前後比較、Instrumentsでのハング/fps・ピークRAM、主要SQL fetch数は未検証。Draft PRとしてIssueは自動クローズしない。純粋な処理時間を実機の画面性能と混同しない。
