# 既存PRのmain未反映差分・依存関係

検証日: 2026-10-10（日本時間）。`git fetch origin`後のmainは`89a059d`。
統合ブランチ: `codex/integrate-existing-pr-deltas`。mainへのマージ、Issueクローズは行っていない。

## GitHubのマージ先と未反映コミット

| PR | 実際のマージ先 | 未反映の実装・記録コミット | 依存 |
| --- | --- | --- | --- |
| #26 | codex/phase6-issue4-native-identity | ef8315e, c03a34f | #25（main反映済み） |
| #27 | codex/phase6-issue5-review-customization | d2787d1 | #26 |
| #33 | codex/issue28-home-filter | 6d39516 | #32（main反映済み） |
| #34 | codex/issue29-review-home | a9023e5 | #33 |
| #35 | codex/issue30-home-states | 463c6c8 | #34 |

5本ともGitHubではmergedだがmainには未反映。古い依存ブランチ全体を置換せず、上記6コミットをmainから順にcherry-pickした。依存元へのマージコミット自体は取り込んでいない。

## 統合時の競合とレビュー

- `StudyOptions`でhomeScopeとreviewAppearanceが同じ位置に追加されていた。両フィールドを保持。
- LibraryRepositoryTests、QualityRepositoryTests、StudyUITestsの同じ位置に追加されたケースをすべて保持。
- QualityUITestsは#35の監査対象・制約を維持し、#26の特大文字設定テストも保持。設定のコントラストは数値テスト・画面添付で確認する既存方針を継承する。VoiceOver音声の確認とは扱わない。
- Home/MainTabs・StudyStoreは#35の最終内容、LibraryView・ReviewView・SettingsViewは#27側の最終内容と一致することを確認。
- SwiftDataモデル・マイグレーション、FSRS依存の固定revision、ReviewScheduler、バックアップの形式・検証処理にはmainとの差分なし。
- updateSettingsは既存optionsを読み取ってreviewAppearanceを書き戻し、applyHomeScopeも既存optionsを読み取ってhomeScopeだけを更新する。統合後の完全バックアップテストに相互更新・復元後の両設定およびセッションスコープ保全を追加。
- 一括編集は確定前の再検証、単一save・rollback、ノート単位の兄弟カード処理、削除後履歴保持を継承。空の学習開始を既存セッションの削除より前に拒否する#34の制御も保持。

## 検証

今回の統合後の実行結果（以前のPRの結果とは別）:

- iPhone 17 Pro / iOS 26.5 Simulator: 単体・結合78件、77成功・実機通知診断1スキップ・失敗0。結果: `/private/tmp/anki-integration-pr-deltas-unit.xcresult`。
- 設定共存テスト追加後、iPhone SE3 / iOS 26.5 Simulator: BackupRepositoryTests 4件成功。結果: `/private/tmp/anki-integration-pr-deltas-cross-ui.xcresult`。
- 同じ小型Simulatorで一括管理・空/短期待機と切替取消・フィルター変更と下書き再起動・スワイプ4評価/Undo/再起動のUI4件成功、失敗0。
- Release arm64 Simulatorビルド成功。ログ: `/private/tmp/anki-integration-pr-deltas-release.log`。
- `git diff --check`成功。競合解消のレビューで既存両系列のテスト・設定と最終画面実装の保持を確認。
- UI実行中にSwiftUIのInvalid frame dimension警告が記録された。選択ケースはすべて成功したが、警告の発生元は未特定。実機の表示品質保証にはしない。

結果バンドルは一時ファイル。今回、全UIテスト・全アクセシビリティ監査・実機テストは実行していない。

## #3・#4の残件と後続Issue

実機受け入れ記録はdocs/mvp-acceptance.mdとdocs/native-ux-audit.mdにある。2026-10-10の端末一覧ではiPhone 15 Proはunavailable。現在の統合コードの実機結果は取得していない。

- 既知の実機ファイルパス問題#24の修正はmainに存在。履歴消失・採点不整合・復元不具合の今回の実機不存在を保証するには再確認が必要。
- 実通知の配信と当該通知のタップ復帰、OS拒否、全件学習後の当日キャンセルは受け入れ未完了。
- 撮影画像での日本語OCRと修正、機内モードでの主要UI、触覚の実感、VoiceOver音声・フォーカス、OSのReduce Motion、iOS 17実行は未確認。
- #27の一括管理UI、今回のホームの実機性能も未確認。過去の隔離ストアでの実機成功を今回の成功に流用しない。

後続は指定順の#39 → #36 → #37 → #42 → #40 → #41とする。#39は#33〜#35のホーム状態制御、#36・#37はその主操作と整合が必要。#42は#36の設定導線と共通の数値制約を扱う。#41は#40のツリー導線と#27のpreview/applyBulkEditに依存する。各Issueは独立PR、本文はRefsを用いて自動クローズを避ける。main統合は利用者の明示承認後に行う。
