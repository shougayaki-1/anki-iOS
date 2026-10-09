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

## 実機受け入れ結果（2026-10-09）

| 項目 | 結果 |
|---|---|
| 端末 | iPhone 15 Pro / iOS 27.0.1（24A446） |
| 確認済み | SETB署名済みDebugアプリのインストール・起動と、通常保存領域にPhase 0／StudyのSwiftDataストアが作成され、再起動後もファイルがあること。UIテストはすべて `-study-test-store` の隔離ストアを使用 |
| 実機UIテスト | 11種類中8種類を現行コードで確認。学習の作成・評価・Undo・再起動・編集／削除、typing下書きの再起動復元、穴埋めプレビュー・学習・Undo、最大Dynamic Typeでのtyping・評価、貼り付け／階層／大容量CSVの取り込み、通知予約・取消を確認。Dynamic Typeは初回失敗後に修正し再実行して成功。FilesのCSVテスト1件はフィクスチャ未表示で未達、写真テスト2件はテスト画像不在で安全にスキップ |
| 通知 | OS通知許可後、アプリ設定ONで予約30件、学習後にOFFで0件、アプリ再起動後もOFFを確認。テスト用ストアの設定はOFF。iOS設定のアプリ通知許可は許可状態のままなので、不要なら「設定 > 通知 > 暗記アプリ」で変更する |
| Dynamic Typeの修正 | アクセシビリティ文字サイズでは、回答方法を明示的なアクションメニューに変更。選択値が「文字入力」になり、入力・解答表示・評価まで実機で通ることを再確認 |
| テスト環境の制約 | ネイティブFiles経由のCSVテストは、iOS 27のファイルピッカーにテスト用CSVが表示されず失敗。個人ファイルが見える状態だったため、選択せず終了。壊れたバックアップの実機テストには未到達 |
| 未確認 | 写真ライブラリでの実選択／カメラ／OCR、日本語OCR、通知の実配信とタップ、機内モード、触覚の実感、VoiceOver音声、Reduce Motionの実操作。テスト名が確認できる写真がなかったため、写真マスクとOCRのテストはどちらも画像を選ばずスキップ |
| その他 | 一部の大容量／アクセシビリティテストで `Invalid frame dimension (negative or non-finite)` の実行時警告が出た。該当テスト自体は成功 |
| 結果バンドル | Study: `/private/tmp/anki-issue3-study-20261009.xcresult`、通知: `/private/tmp/anki-issue3-notifications-20261009.xcresult`、Dynamic Type修正後: `/private/tmp/anki-issue3-accessibility-fix-20261009.xcresult`。Files／写真ピッカーを含む一時結果は、個人ファイル名・写真メタデータが残る可能性があるため、結果記録後に削除 |

通常保存領域でのストアファイル存在は、画面上のデータ作成や内容の復元を確認した証拠ではない。UIテストの機能確認は隔離ストア上の結果であり、既存の通常データを対象にした検証ではない。写真テスト素材を用意し、Dynamic Typeの入力方法とFilesテストフィクスチャの公開方法を整えた後、残りの実機項目を確認する。

## 実機で確認する手順

1. XcodeのTeamを指定してiOS 17以降のiPhoneへ起動。最低OS・実機の性能を確認する。
2. 機内モードにして、4形式の登録・学習・画像表示・OCR・バックアップ／復元を試す。ローカルの写真を選ぶ。
3. 通知をオン／拒否し、指定時刻の実配信、全件復習後の取り消し、通知タップ後のホーム移動と学習再開を確認する。
4. カメラで撮影・トリミングし、日本語OCRを確認・修正して保存する。
5. off / standard / richの触覚を比較。VoiceOverで問題・解答・評価・目標達成を読み上げ、Reduce Motionをオンにして遷移を確認する。

上記の実機確認は部分完了。iOS 17ランタイムは未検証であり、以上をシミュレーター成功から実機成功とみなさない。バックアップ形式の上限・未対応形式・長期通知補充の制約はREADMEに記録した。
