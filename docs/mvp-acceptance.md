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

## 実機受け入れ結果（2026-10-09〜10）

| 項目 | 結果 |
|---|---|
| 端末 | iPhone 15 Pro / iOS 27.0.1（24A446） |
| 確認済み | SETB署名済みDebugアプリのインストール・起動と、通常保存領域にPhase 0／StudyのSwiftDataストアが作成され、再起動後もファイルがあること。UIテストはすべて `-study-test-store` の隔離ストアを使用 |
| 実機UIテスト | 学習の作成・評価・Undo・再起動・編集／削除、typing下書きの再起動復元、穴埋め、最大Dynamic Type・ダークでのtyping・評価、貼り付け／階層／大容量CSV、通知予約・取消が成功。追加で写真マスクの選択・トリミング・学習・再起動後の画像保持、写真OCRの修正→取込→学習、許可された `Lesson4-5_ankicards_full.csv` のFiles選択→取込→再起動→学習→Undo、固有名の完全バックアップ書出→同じファイル選択→復元→再起動が成功 |
| 保存・復元の回帰 | 実機でStudyRepository 7件、MediaRepository 9件、BackupRepository 4件、計20件が修正後すべて成功。全4評価のFSRS・履歴、UUID・下書き・画像・設定の復元一致、失敗時元ストア保持、不正データ拒否、日本語「日本」「東京」のVision認識、外部シンボリックリンク拒否を検証 |
| 通知 | OS通知許可後、アプリ設定ONで予約30件、学習後にOFFで0件、アプリ再起動後もOFFを確認。テスト用ストアの設定はOFF。iOS設定のアプリ通知許可は許可状態のままなので、不要なら「設定 > 通知 > 暗記アプリ」で変更する |
| Dynamic Typeの修正 | アクセシビリティ文字サイズでは、回答方法を明示的なアクションメニューに変更。選択値が「文字入力」になり、入力・解答表示・評価まで実機で通ることを再確認 |
| 修正した実機不具合 | #24: URLのディレクトリ末尾スラッシュ・別名・未作成ファイル配下のリンク判定で復元と画像整理が失敗。存在する祖先の解決＋パスコンポーネント判定に変更し20件で回帰確認。最大文字サイズの回答方法切替も修正済み |
| カメラ | 撮影→写真を使用→Vision実行が成功。初回画像の認識結果には日本語がなかったため、撮影画像での日本語認識と修正は再確認待ち。ローカル日本語画像の実機Visionテストは成功 |
| オフライン | 利用者が機内モードON・Wi-Fi OFFを報告。その状態で保存・画像・日本語OCR・バックアップ結合20件が成功。UI操作テストは自動操作開始のタイムアウトで未実行。機内モードでのFiles選択・画面遷移を成功扱いにしない |
| テスト環境の制約 | Documents内フィクスチャがFilesに表示されないテストは未達。許可された実CSVの選択は成功。OCRやCSVの画面外要素へのテスト操作はスクロールで修正。通知の配信・通知センターからの特定は再実行でも未達。短い実行識別子のタイトルと失敗時の隔離ストアOFF処理を追加 |
| 未確認 | 実通知の配信・タップ復帰、OS通知拒否、全件学習後の当日通知キャンセル、機内モードでの主要UI、撮影画像の日本語認識、触覚の実感、VoiceOver音声、Reduce Motionの実操作。Issue #3は完了にしない |
| その他 | 一部の大容量／アクセシビリティテストで `Invalid frame dimension (negative or non-finite)` の実行時警告が出た。該当テスト自体は成功 |
| 結果バンドル | Study: `/private/tmp/anki-issue3-study-20261009.xcresult`、通知: `/private/tmp/anki-issue3-notifications-20261009.xcresult`、Dynamic Type修正後: `/private/tmp/anki-issue3-accessibility-fix-20261009.xcresult`。Files／写真ピッカーを含む一時結果は、個人ファイル名・写真メタデータが残る可能性があるため、結果記録後に削除 |

通常保存領域は初期化・削除していない。UIテストは隔離ストアを使い、書出した固有名のバックアップだけを同じ隔離ストアへ復元した。個人写真・CSV本文・Filesの一覧はリポジトリやPRに含めない。20件成功のローカル結果は `/private/tmp/anki-issue3-offline-full-20261010.xcresult`（UIランナー開始は失敗）にある。PR #1は既にマージ済みだが、Issue #3の受け入れ判定は残項目の結果が揃うまで保留。

## 実機で確認する手順

1. XcodeのTeamを指定してiOS 17以降のiPhoneへ起動。最低OS・実機の性能を確認する。
2. 機内モードにして、4形式の登録・学習・画像表示・OCR・バックアップ／復元を試す。ローカルの写真を選ぶ。
3. 通知をオン／拒否し、指定時刻の実配信、全件復習後の取り消し、通知タップ後のホーム移動と学習再開を確認する。
4. カメラで撮影・トリミングし、日本語OCRを確認・修正して保存する。
5. off / standard / richの触覚を比較。VoiceOverで問題・解答・評価・目標達成を読み上げ、Reduce Motionをオンにして遷移を確認する。

上記の実機確認は部分完了。iOS 17ランタイムは未検証であり、以上をシミュレーター成功から実機成功とみなさない。バックアップ形式の上限・未対応形式・長期通知補充の制約はREADMEに記録した。

### ロック解除後の再実行（2026-10-10）

- 写真マスク、写真OCR、指定CSVの取り込み・再起動・学習が成功。
- カメラは撮影画面に小さくぼやけた文字が映っており、日本語認識は未達。撮影自体と修正・学習の経路は進む。
- 実通知を特定できず、配信・タップ復帰は未達。以前の通知との取り違えを防ぐ実行固有のタイトルを追加した。
- バックアップの書出しは成功したが、長い固有名の入力が途中で短くなり、完全名を探すテストが失敗した。短い固有名に変更して再検証する。以前の書出し→同一ファイル復元成功を今回の成功と混同しない。
- 今回の画面にWi-Fiアイコンが表示されたため、通信遮断下の成功として扱わない。先の結合20件は利用者の状態報告に基づく記録であり、この実行では機内モード・Wi-Fi OFFの再確認が必要。

### 追加の復元・通知診断

- 短い固有名のバックアップ書出し→同一ファイル復元→再起動後のカード・履歴確認が実機で成功（66.335秒）。
- 通知UI再試験ではHomeボタン操作後もXCUIApplicationがforegroundを報告し、配信通知をUIから特定できなかった。タップ復帰は未達。
- 別のホスト実機診断でOSの通知許可・アラート・通知センターが有効、テスト専用接頭辞の配信済み通知2件を確認した。今回のUI試験固有の通知との対応までは確認していないため、タップ受け入れの成功にはしない。
- 診断後、`review-test-` 接頭辞の予約30件と配信済み2件を削除し、通常接頭辞の予約集合が変わらないことを確認した。通知診断・後片付けテストは明示環境変数がある場合だけ実行する。
