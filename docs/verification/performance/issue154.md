# Issue #154 — 記述式下書きの遅延保存

入力はStudyStoreのセッション状態に即時反映。600msのdebounce後に保存し、評価・解答公開・モード変更・Undo・中断・画面離脱・非アクティブ移行でflushする。同期保存はMainActorで行い、非同期なのは待機だけ。セッションPersistentIdentifier・カードUUID・タスクgenerationを確認し、古いタスクによる別カードへの保存を防ぐ。

保存失敗時は未保存文字列を保持し、評価/遷移を止めて再試行可能なエラーを出す。refreshStudyの再取得でも未保存入力を重ねる。保存成功後のみpendingを消す。スキーマ、FSRS、ReviewLog、保存済み回答、Undoの既存意味論は変更しない。

## 計測・検証（2026-10-12）

iPhone 17 Pro / iOS 26.5 Simulator、Debug、独立in-memoryストアで100文字連続入力。旧Repository.updateDraft経路は100 save / 75.40ms、新buffer経路は入力中0 save / 0.34ms、停止後1 save。入力ループの壁時計時間であり、IME・描画fps・実機ハング測定ではない。600msの待機と実保存時間は新入力ループ時間に含めない。

関連StudyRepositoryTests 55件成功。100文字の最新値、画面再取得、背景移行、公開、次カード、Undo、中断/再開、遅延タスク取消、保存失敗→評価停止→再試行、保存済み記述回答とUndo削除を確認。

Debug Simulatorビルド成功。既存UI `testTypingDraftSurvivesProcessRestartAndModeChange` 1件も実行したが、共有`create()`のライブラリ行確認（StudyUITests.swift:302、折り畳み階層下の問題文を探す）で失敗。以降の文字入力→background→再起動復元、モード変更、公開、評価、記録1回のアサーションは失敗なし。UIテスト全体の成功とは扱わず、無関係な共有ヘルパーは変更しない。復元テストは即時force-kill保証に依存しないよう、terminate前にHomeへ移行する。

再現: `xcodebuild test -only-testing:AnkiIOSTests/StudyRepositoryTests`。出力`TYPED_DRAFT`を参照。

実機の日本語IME変換・文字選択・入力ハングは接続不可のため未検証。OS強制終了前のイベントは保証せず、debounce内の未保存入力は失われ得る。受け入れ条件をすべて満たしたとは扱わずDraft PRとする。

## 実機再確認（2026-10-12）

指定どおり参考計測のみ・Closeしない。mainではPR #163がマージ済み。100文字入力ループ中央値0.405ms、入力中save 0、停止後save 1（in-memory、3回、600ms待機/実保存/IME/描画を含まない）。実機の日本語IME/文字選択・欠落・古い下書き復活の目視は未確認。

環境はiPhone 15 Pro / iOS 27.0.1 / Xcode 27 / Debug、専用Bundle ID・隔離ストア。実機データ・全標本・未確認条件・再現方法は[共通実機レポート](README.md)と[CSV](device-20261012.csv)を参照。先行Simulatorの値との改善率は算出しない。
