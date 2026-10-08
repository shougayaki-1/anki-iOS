# MVP実装進捗

仕様の正本：`docs/requirements.md`。作業ブランチ：`codex/implement-mvp`。

## Phase別状況

| Phase | 状態 | 証拠・次の作業 |
|---|---|---|
| 0 | 完了 | e50918eで保存・origin/mainに反映済み。自動テスト6件・Releaseビルドの既存結果を継承 |
| 1 | 完了 | 全20テスト成功（既存6＋追加14）。Debug Simulator / Release arm64成功。UIで作成・学習・Undo・再起動・編集・削除・下書き復元を検証 |
| 2 | 完了 | 全30件成功（単体／結合25＋UI5）。Release arm64成功。階層スコープ学習・一括登録UI・結果画像を確認 |
| 3 | 完了 | 全43件同時成功＋追加保護テストを含む単体／結合36件再成功（計44件）。Debug/Release成功。穴埋め・写真マスク・OCR UIと4画面の画像を確認 |
| 4 | 準備中 | 通知計画・センター差分同期・統計・触覚のサービスを作成。まだアプリへ接続・検証していない。完全バックアップ未着手 |
| 5 | 未着手 | 全機能統合・UI・性能・アクセシビリティ検証 |

## 設計・データ保全

- Phase 0の検証ストアとコードを維持。通常の学習データは独立した `Study/Study.store` に保存する。
- 学習データはVersionedSchema v1.0.0から開始。モデルを変更する後続工程では既存ストアを削除せず移行を検証する。
- 時刻・カレンダーを注入可能にし、午前4時の日境界、新規枠、期限超過をサービスで計算する。
- 評価はCard全FSRS状態、ReviewLog、SessionDraftを一度の明示saveで保存。失敗時はrollbackし、UIを進めない。
- 削除されたカードの履歴は分析と日次新規枠のため残す。Undoだけは取り消す評価のログを削除して評価前に復元する。

## 未検証・既知の制約

- Phase 1は20件成功・失敗0。iOS 26.2上でも単体／結合17件成功。`docs/verification/phase1-test-summary.json` を保存。
- SwiftData rollback後のモデル参照は無効化されるため、再取得した状態で失敗検証。UIはモデルを直接保持せず値を利用。
- UIテストではテキスト挿入位置と合成アクセシビリティラベルを踏まえて要素を指定し、保存した値そのものを比較。
- Phase 1コミット：`dea8bba`。origin/codex/implement-mvpへpush済み。
- Phase 2：V1モデルを変更せず、V2でTag / ImportBatch / SessionScope / ExtraPreferencesを追加。軽量移行で既存UUID・FSRS・履歴・下書きを保持するテストが成功。
- 引用符・改行・エスケープを扱うCSV/TSV、Q:/A:貼り付け、通常文章の編集、列マッピング、ヘッダー有無、重複skip/add/update、行エラー、原子的バッチ保存を実装。
- 階層デッキの循環を拒否。削除は子孫ノートを移動／削除する確認操作を要求し、履歴は保全。
- 兄弟カードの抑制はキューのみ。短期学習は例外、due/FSRSを変更しない。
- Phase 2結果：`docs/verification/phase2-test-summary.json`。ネイティブファイル選択のUI操作は未自動化。
- 次はPhase 3：安定clozeIDでのカード生成・再生成、画像取り込み／マスク編集・独立した復習状態、Vision OCR、画像参照整合性。
- 実機起動、iOS 17ランタイム上の動作は未検証。利用可能なシミュレーターはiOS 26.2 / 26.5。
- Goal全体は進行中。Phase 1だけで終了しない。

## Phase 3作業中のメモ

- NoteItemの表示IDをCard IDにし、1ノートから複数カードができてもSwiftUIの行IDが衝突しないようにした。編集には元のNote内容を使用する。
- 内容payload v2を追加し、v1も読み込み可能。SwiftData既存モデルのフィールドは変更していない。
- 穴番号の並べ替えでFSRS状態・Card IDを維持するテスト、同じ穴番号の複数箇所とヒント、裏表反転を追加。検証は成功。
- 画像・OCRのPhase 3は完了。通知・バックアップとPhase 5は未完了。Goalはactive。

- Phase 3ではForm同一行の複数ボタン同時発火を修正。全幅／全高マスクのゼロ範囲Sliderクラッシュも修正し、UI再検証で成功。
- Photo UIテスト用のDBだけでなく、画像管理領域も通常データから分離するよう修正した。
- MacがロックされておりCUAによる手動操作は利用できない。XCTestとxcresultの画像で画面・操作検証を継続する。

- Phase 3最終：全体43件成功、追加後の単体／結合36件成功、Release arm64成功。JSON集計2件をdocs/verificationへ保存。主要4画面の画像を確認済み。
- 次はPhase 4の通知・触覚・統計をアプリへ接続し、完全バックアップ・復元を実装する。
