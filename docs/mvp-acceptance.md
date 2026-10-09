# MVP受け入れ検証

仕様の正本はrequirements.md。Phase 0のFSRS-6アダプターと固定依存を維持し、Phase 1〜5を追加した。現時点の全体検証は71件（単体・結合58、UI13）成功。最終typing表示の改善後も関連UI2件を再実行して成功した（全71件に含まれる同じテスト）。Debugテスト用ビルドとRelease arm64ビルドも成功。集計はverification/phase5-test-summary.jsonとphase5-typing-summary.jsonに保存。

## 仕様と証拠の対応

| 対象 | 実装・検証 |
|---|---|
| 基本モデル・永続化・移行 | StudySchema / V2 / V3、PersistenceTests、LibraryRepositoryTests、ClozeRepositoryTests。V1→V3でUUID・FSRS・履歴・下書きを保持 |
| 基本4形式・編集・独立カード | CardGenerationTests、ClozeRepositoryTests、MediaRepositoryTests、StudyRepositoryTests。安定したvariantKey、穴とマスク単位の状態、履歴維持／初期化、削除後履歴保全 |
| mental / typing・4評価・Undo | StudyRepositoryTests、ReviewSchedulerTests、StudyUITests、GeneratedCardUITests。保存失敗rollback、実際の回答時刻、再回答、モード変更、再起動後下書き |
| 3モード・新規枠・目標・期限超過 | ReviewQueueTests、StudyRepositoryTests。全体の共通枠、3:1混在、短期優先、停止除外、目標後の継続、4時・DST・時間帯 |
| 階層・タグ・検索・一括登録 | LibraryRepositoryTests、ImportParserTests、ImportUITests、QualityUITests。循環拒否、スコープ、UTF-8ファイル、引用符内改行、列指定、貼り付け、重複・行エラー・原子的保存 |
| 写真・マスク・OCR | MediaRepositoryTests、GeneratedCardUITests。PhotosPickerの実選択、トリミング、マスク編集・個別学習、Vision英語画像認識、認識結果編集→確定。実機カメラ・日本語精度は未検証 |
| 通知 | NotificationPlannerTests、NotificationServiceTests、OperationsUITests。新規／停止を除外、期限・指定時刻・30日・配信済み・差分、非同期競合、OS予約30件→オフで0件、再起動。実際の配信・タップは未検証 |
| 統計・触覚 | StatisticsTests、StatisticsView、HapticsService。日別ユニーク枚数と回答数、継続、評価内訳、時間、想起確率。off / standard / rich、ハードウェア判定とフォールバック。実機の感触は未検証 |
| 完全バックアップ・復元 | StoredZIPTests、BackupRepositoryTests、OperationsUITests。12モデルと画像、全UUID・FSRS・履歴・下書き、復元後Undo、別ストア検証と原子的切替、再起動 |
| 破損・失敗時保護 | BackupRepositoryTests、QualityRepositoryTests、QualityUITests。CRC・SHA・構造・パス・参照・重複・循環・極端値・失敗save、ネイティブFilesからの壊れたZIP拒否後も既存カードを保持 |
| アクセシビリティ・ダーク | QualityUITests。シーンの最大Dynamic Typeとダーク、要素検出と説明の自動監査、記述式typing→解答比較→保存。問題／解答フォーカス、目標の文字・アクセシビリティ通知、数値によるマスク編集。実際のVoiceOver音声とReduce Motion設定は未検証 |
| 最低規模 | ScaleRepositoryTests、QualityUITests。1000ノート・3000カード・10000履歴のディスクデータ、読み込み・復習＋Undo・バックアップ＋復元。アプリUIでも復習3000枚→学習→Undo→再起動→再開 |
| オフライン構成 | App内にURLSession・WebView・アナリティクス・クラウド／ログイン機能なし。SwiftDataはCloudKit.none、Vision・画像・バックアップはローカル処理。初回SPM取得後の最終ビルド・テストは固定依存で実行。実機の機内モード試験は未検証 |

## 規模試験（iPhone 17 Pro / iOS 26.5 Simulator）

| 処理 | 最終測定 |
|---|---:|
| 1000 / 3000 / 10000の作成・保存 | 0.94秒 |
| StudyStoreの初期読み込み | 0.66秒 |
| セッション開始・評価・Undo | 1.20秒 |
| 書出し・検証・置換復元・再読み込み | 2.99秒 |
| バックアップサイズ | 14,164,004 bytes |

単発のシミュレーター測定で、実機の性能保証や目標値ではない。初期基準の復習＋Undoは1.33秒。対象カードだけの表示生成へ改善した。UIの規模フィクスチャは実際のFSRS遷移とSwiftDataに保存し、表示値を差し替える方式は使っていない。テスト専用引数とデータ作成はDEBUG限定。

## 実機で確認する手順

1. XcodeのTeamを指定してiOS 17以降のiPhoneへ起動。最低OS・実機の性能を確認する。
2. 機内モードにして、4形式の登録・学習・画像表示・OCR・バックアップ／復元を試す。ローカルの写真を選ぶ。
3. 通知をオン／拒否し、指定時刻の実配信、全件復習後の取り消し、通知タップ後のホーム移動と学習再開を確認する。
4. カメラで撮影・トリミングし、日本語OCRを確認・修正して保存する。
5. off / standard / richの触覚を比較。VoiceOverで問題・解答・評価・目標達成を読み上げ、Reduce Motionをオンにして遷移を確認する。

実機・iOS 17ランタイムはこの環境では利用できない。以上をシミュレーター成功から実機成功とみなさない。バックアップ形式の上限・未対応形式・長期通知補充の制約はREADMEに記録した。
