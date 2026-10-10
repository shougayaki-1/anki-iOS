# Issue #56 — 英文並び替えのドラッグ再配置

## 実装

- 回答欄のチップはタップで個別取消を維持し、長押しからのネイティブDrag & Dropで語順を変更する。候補チップのタップ追加、リセット、判定は従来通り。
- 選択欄全体がドロップ領域。各チップのフレームと行の上端を使い、横方向の中点から挿入位置を算出。複数行では指に最も近い行を選び、行先頭・末尾、チップ間の空白も扱う。挿入ガイドを表示し、Reduce Motion時にはアニメーションを抑制。
- OrderingAction.move(id, to:) は移動後の最終位置を受け取り、配列のremove/insertを実施（swapしない）。元の整数IDは出現位置に紐づき、同じ綴りの複数の単語を取り違えない。無効ID、未選択語句、範囲外の移動は拒否。
- ドロップ範囲外・移動前と同じ位置では配列を変更しない。専用ドラッグ型により他のテキストドロップを受け付けない。ドラッグ中はOS標準のプレビューでチップが浮く。
- VoiceOverは前・後・先頭・末尾に移動可能なアクション、現在位置と操作後の英文アナウンスを提供。チップの操作領域は最低44pt。
- 既存のOrderingDraftRecord（schemaVersion 1）を更新するため、SwiftDataスキーマ・バックアップ形式の変更は不要。中断・再起動・バックアップ、UndoとFSRSを維持。ドラッグと正誤判定のみではReviewLogを保存しない。
- 追加／取消はSwiftUI選択触覚、ドラッグ開始はlight impact、挿入先の変更は選択触覚（0.1秒間隔で間引き）、位置が変わるドロップはlight impact。保存済みの正解はsuccess、不正解はerrorを一度だけ発火。従来のrevealと重複させない。アプリの触覚オフ・OS設定を尊重。

## テストコードの追加

- Unit: 前・後・端への挿入、同位置、無効操作、JSONの往復、重複語と誤答再試行、複数行の挿入先計算。
- Integration: 複数回並び替えと中断再開、Card/FSRS/dueDate/ReviewLog不変、判定後でも評価まで履歴が未確定であること。
- UI: チップを取り消さず I school walk to を I walk to school の正解順へ変更、判定、順序の中断・再起動保持。
- #58/#63との統合時にはStudyUITests・並び替え・答え表示・4段階評価を回帰テストする。

## 検証状況

- GitHub上の実装・テストコード作成済み。mainとの差分を確認。
- 未実施: xcodebuild、XCTest、Simulator、iPhone実機ドラッグ・触覚。現在の環境にXcode/iOS SDKがないため、成功扱いにはしない。
- 未確認: スクロールとの競合、エリア外キャンセル、小画面・最大Dynamic Type・ダークモード・VoiceOverの音声・Reduce Motion・触覚の遅延、#54固定操作エリアとの併用。

## Mac / iPhoneでの受け入れ確認

1. Xcodeでビルドし、OrderingAnswerTests、OrderingRepositoryTests、OrderingUITests、StudyUITestsおよびバックアップの関連テストを実行。
2. 小型・通常サイズのiPhoneで I / school / walk / to の walk を school の前、続けて to を school の前へ移動。先頭・中央・末尾でも選択済みの他のチップが消えないことを確認。
3. I think I can.、句読点、短縮形、ハイフン、長い語句、複数行をまたぐドラッグ、空白へのドロップ、外側キャンセル、通常の縦スクロールとタップ操作を確認。
4. VoiceOverの前後・先頭末尾アクションと語順の読み上げ、Dynamic Type最大、Dark Mode、Reduce Motionを確認。
5. 触覚対応実機で追加→持ち上げ→挿入位置変更→ドロップ→不正解→修正→正解を確認。触覚オフと再描画による二重発火も確認。
6. 中断・再開、回答方式切替、再試行、評価・Undo、バックアップ・復元の整合性を検証。

端末検証の完了までDraft PRを維持し、試験結果と機種・OS・Xcodeバージョンを追記する。
