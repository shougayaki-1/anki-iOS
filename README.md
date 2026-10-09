# anki-iOS

個人用のiPhoneネイティブ暗記アプリ。Phase 1〜5のMVPを実装し、利用可能なシミュレーターで検証済みです。

SwiftUI / SwiftData / FSRS-6 をベースに、ローカルファーストな間隔反復学習と、Apple純正アプリに近い操作感・触覚フィードバックを目指します。

## 設計資料

- **[実装要件定義書 v1.0](docs/requirements.md)** — 機能要件、データ構造、FSRS、通知・バックアップ、Phase 0〜5、受け入れテスト、Codex向け実装指示

## 確定した要件

- 4形式：一問一答、記述式、穴埋め、画像マスク
- 頭の中で回答／文字入力を選択し、4段階で自己評価
- 手入力、CSV/TSV/TXT、文章貼り付け、写真・スクリーンショットから登録
- 階層型デッキと独立したタグ
- 「復習」「新しく覚える」「まとめて学習」の3モード
- FSRS-6で復習予定を管理。復習枚数は無制限、日次目標は任意
- 復習が必要な日のみ、ローカル通知でリマインド
- サーバー・アカウント不要。端末内に保存し、バックアップ／復元に対応

## 開発

機能実装時は **[docs/requirements.md](docs/requirements.md)** を仕様の正本として扱ってください。

### 起動手順

1. Xcodeで `AnkiIOS.xcodeproj` を開く。検証環境はXcode 26.5 / Swift 6.3.2。Deployment TargetはiOS 17.0、iPhone専用。
2. Swift Package Managerの依存解決を待つ（初回のみネット接続が必要）。追加ツールやプロジェクト生成処理は不要。
3. Scheme `AnkiIOS` とiPhoneシミュレーターを選び、Run（⌘R）。
4. ライブラリの＋から形式を選び、問題と解答を入力して保存する。画像・穴埋めの操作は各Phaseの説明を参照。
5. ホームで「新しく覚える」または「まとめて学習」を選び、答え表示→4段階評価で学習する。期限到来後は「復習する」。Undoと中断／再開を利用でき、再起動後も履歴・予定・下書きを保持する。

DebugビルドのPhase 0診断は設定→「Phase 0検証」→「検証して保存」。仮想日時で `good → good → again → good` を実行し、UUID・回答4回・忘却1回・次回日時を記録する。再起動で同じ値を確認でき、再度保存すると別レコードを追加する。

実機では、iOS 17以降のiPhoneを接続し、Xcodeの **Signing & Capabilities → Team** に自分のApple IDのチームを指定する。Bundle Identifierが重複する場合は自分のものに変更する。iPhoneでDeveloper Modeを有効にし、必要な信頼設定を済ませて、その端末を選択して⌘R。通常起動では通知・カメラ権限を要求しない。通知をオンにするとき、カメラを使うときに要求する。写真はシステムの選択画面から取り込む。

### 依存関係とFSRSの採用理由

- Apple SwiftUI / SwiftData（システム標準）。保存領域は端末内、CloudKitは明示的に無効。
- [open-spaced-repetition/swift-fsrs](https://github.com/open-spaced-repetition/swift-fsrs) のコミット **`4fbaf20184d62f82a9f44f343337c61a2c5483e9`** をSPMで固定。プロジェクトのrevision指定と `AnkiIOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` をコミット対象にしている。
- `v5.0.0`のソースでは `FSRSParameters.init` がinternalで、外部モジュールから初期化できない。さらにFSRS-6の21パラメータ定数がないため採用しなかった（このタグはソース確認のみ）。採用コミットは公開初期化子・FSRS-6・短期学習ステップに対応し、実際のiOSビルドとテストを通過。
- アダプターで `FSRSDefaults.defaultWv6` の21パラメータを明示指定し、保持率90%、短期学習オン、fuzzオフ。省略時のFSRS-5デフォルトを使用しない。学習ステップはライブラリ既定の1分・10分、再学習は10分。
- 現在日時を引数で渡し、想起確率はその日時から計算する。全Card状態（`learningSteps`等を含む）をバージョン付きCodableとして保存する。FSRSの内部型をUI・永続化層へ公開しない。

実装前にcontext7から [SwiftUI](https://developer.apple.com/documentation/swiftui) と [SwiftData](https://developer.apple.com/documentation/swiftdata) の最新資料を取得した。swift-fsrsはcontext7未収録のため、公式リポジトリのREADME・公開APIを直接確認した。

### 自動テスト・ビルド

Xcodeでは⌘Uで全テストを実行する。CLIでも次の手順で再現できる。シミュレーター名・OSは `xcodebuild -showdestinations -project AnkiIOS.xcodeproj -scheme AnkiIOS` の一覧に合わせて変更する。

```sh
xcodebuild -resolvePackageDependencies -project AnkiIOS.xcodeproj -scheme AnkiIOS

xcodebuild test \
  -project AnkiIOS.xcodeproj -scheme AnkiIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath build/DerivedData \
  -resultBundlePath build/MVP.xcresult \
  CODE_SIGNING_ALLOWED=NO

xcodebuild build \
  -project AnkiIOS.xcodeproj -scheme AnkiIOS -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DeviceDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

再実行時は `-resultBundlePath` を新しい名前にする（既存のxcresultには上書きできない）。最後のコマンドは署名なしの実機向けビルド確認。実機へインストールする際はXcodeの署名設定を使用する。

### 検証結果（2026-10-08、日本時間）

環境：Xcode 26.5（17F42）、Swift 6.3.2、iPhone 17 Pro / iOS 26.5 Simulator（arm64）、Deployment Target iOS 17.0。

| 検証 | 結果 |
|---|---|
| SPMの固定リビジョン解決 | 成功、上記コミットと一致 |
| SwiftUIアプリ・FSRSのSimulatorビルドと起動 | 成功 |
| FSRS-6判定、21パラメータ、初回goodの安定性2.3065 | 成功 |
| 初回good → learning（10分後）、2回目good → review | 成功 |
| 次の期限にagain → relearning（10分後）→ goodでreview復帰 | 成功、回答4回・忘却1回 |
| 4段階評価、短期again（1分後）、実回答日時、想起確率、保持率範囲 | 成功 |
| 全状態・遷移のCodable往復と、その後のレビュー継続 | 成功 |
| SwiftDataディスク保存 → コンテナを作り直して読み込み | 成功、UUID・全状態・4件の遷移・due一致、5回目レビュー可 |
| UI操作で保存 → プロセス終了 → 再起動 | 成功、UUID・件数・遷移・次回日時一致 |
| 自動テスト合計 | **6件成功、失敗0、スキップ0** |
| 実機向けarm64 Releaseビルド（署名なし） | **BUILD SUCCEEDED** |

UIテストの再起動後スクリーンショットも確認済み。UIテストは実行ごとに専用ディスクストアを作成し、通常の検証データに干渉しない。テスト結果はXcodeのReport Navigatorから確認でき、再起動後の画像は `Phase0-after-relaunch` 添付に保存される。

この作業時の結果バンドルは `/private/tmp/anki-phase0-tests-v2.xcresult`、ログは `/private/tmp/anki-phase0-tests-v2.log` と `/private/tmp/anki-phase0-device-build.log`（一時ファイルのため永続保管は保証しない）。

初回ビルドでDebugが両アーキテクチャを要求し、arm64のみ生成されたFSRSモジュールをx86_64から参照するエラーが発生した。Xcodeの標準的なDebug設定に合わせ `ONLY_ACTIVE_ARCH=YES` を設定し、再実行で全テストが成功した。上流コードへの変更や互換ラッパーは不要だった。

**未検証**：署名した実機での起動、iOS 17ランタイム上の実行（この環境にインストールされたランタイムはiOS 26.2 / 26.5）。iOS 17を最低対象とするコンパイルは通過しているが、実機・最低OSでの動作確認を置き換えるものではない。

### Phase 0の構成と次工程

- `App/AppEntry`：SwiftUIの入口、保存領域初期化、失敗時の再試行。
- `App/Features/Home`：標準NavigationStack・Listによる検証画面、保存失敗の表示と再試行。
- `App/Domain/Services/ReviewScheduler`：FSRSアダプター、バージョン付き全状態、仮想日時の検証シナリオ。
- `App/Persistence`：SwiftDataのVersionedSchema v1.0.0と検証用 `Phase0Probe`。状態と遷移を一度の明示saveで保存し、失敗時はrollbackする。
- `Tests/UnitTests` / `IntegrationTests` / `UIAutomation`：スケジューラー、ディスク永続化、プロセス再起動のテスト。

検証用データは本番のNote/Card/ReviewLogとは別のモデル。Phase 1で基本モデルと学習UIを追加する際は、既存ストアを黙って削除せず、VersionedSchemaの更新と必要な移行計画を用意する。Phase 0コード・ストアはそのまま維持し、Phase 1以降の通常データは独立したストアに保存する。


## Phase 1 — 基本のカードと復習

ホーム・ライブラリ・記録・設定の4タブを追加。一問一答・記述式を作成・編集・削除し、頭の中で回答／文字入力から4段階評価で学習できる。

1. ライブラリの＋でデッキ・形式・回答方法・問題・解答を入力して保存する。デッキ追加も可能。
2. ホームで「復習する」「新しく覚える」「まとめて学習」を選ぶ。混在は復習3：新規1、短期学習期限を優先。
3. 「答えを表示」してAgain / Hard / Good / Easyを選択。Hardは思い出せたが難しかった場合に使う。
4. 直前の評価はUndoで取り消せる。「中断」後、ホームから再開できる。入力下書きは未確定の間のみ保存し、評価ログへ回答文章を保存しない。
5. ライブラリのカード詳細で次回復習・回答回数・停止状態を確認できる。学習済み内容の編集時は復習予定の維持／未学習へのリセットを選択する。いずれも過去の履歴を保全。

### 永続化・処理の保証

- `StudySchema` v1.0.0にDeck / Note / StudyCard / StudyReviewLog / SessionDraft / StudyPreferencesを定義。Noteはバージョン付きCodable payload、Cardは `noteID + variantKey` の一意キーを持つ。穴埋め・画像追加時も同じ安定キーと全FSRS状態を利用できる。
- Phase 0のストアとは別にApplication Supportの `Study/Study.store` を使用し、検証データを削除しない。将来のスキーマ変更は移行計画と保存済みストアでのテストを追加する。
- FSRS依存とPhase 0のアダプターは変更していない。保持率変更は次回回答から適用。
- 評価時はCard全状態、ReviewLog、SessionDraftを一度の明示saveで保存。失敗時はrollbackして画面を進めない。UIは値のスナップショットを利用し、rollbackで無効化されるモデル参照を保持しない。
- Undoは直前のログのbefore状態・due・更新日時を戻し、そのログを削除する。別の評価や状態変更がある場合は安全性を確認して拒否する。
- 午前4時の日境界、新規枠、ユニークカード数による日次目標、期限超過、短期学習、混在比率をUIから独立した `ReviewQueueBuilder` で計算。日時とカレンダーを注入できる。
- 新規枠は全デッキ・全モード共通、目標達成後も復習を継続できる。カード削除時にも履歴を残し、当日の新規使用枠を維持する。
- 未確定回答は採点せず、再起動時は保存済み下書きから再開。バックグラウンド滞在時間を回答時間に加算しない。

### Phase 1検証結果（2026-10-08、日本時間）

- iPhone 17 Pro / iOS 26.5 Simulator：**20件成功、失敗0、スキップ0**（既存Phase 0の6件＋Phase 1の14件）。[保存したテスト集計](docs/verification/phase1-test-summary.json)。
- 追加の単体・結合テスト17件全体はiOS 26.2 Simulatorでも成功。
- FSRS全4評価、原子的保存、保存失敗とUndo失敗のrollback、全状態のUndo・再回答、ID・履歴を維持する編集、停止、新規枠のモード／デッキ共通化、4時境界、期限超過、DST・時間帯、目標後の継続、ディスク再起動・未採点下書き復元を検証。
- UI：作成→学習→Undo→再評価→再起動→予定維持の編集→削除、および文字入力→強制終了→下書き復元→回答方式変更→採点→記録確認が成功。ライブラリ・解答・復元後入力画面のスクリーンショットを確認済み。
- Debug Simulator / Release arm64 iOS（署名なし）：両方 **BUILD SUCCEEDED**。
- 結果バンドル `/private/tmp/anki-phase1-tests-v2.xcresult`、最終ビルドログ `/private/tmp/anki-phase1-debug-final.log`、`/private/tmp/anki-phase1-release-final.log`。一時ファイルのため永続保管は保証しない。

実機・iOS 17ランタイムでの動作、触覚の感触、性能規模試験は未検証。階層・タグ・一括登録・穴埋め・画像・通知・完全バックアップ・詳細統計は後続Phaseで実装する。全体の進捗は [implementation-progress.md](docs/implementation-progress.md) に記録する。


## Phase 2 — デッキ管理と一括登録

- ライブラリの「デッキ管理」から親子デッキを作成・改名・移動できる。自分や子孫を親にする循環は拒否。削除時は子孫ノートを別デッキへ移動／ノートとカードも削除を選び、過去の回答履歴を保持する。
- カード編集でカンマ区切りのタグを指定。タグはデッキから独立し、表記を正規化して共有する。問題・解答・デッキ階層・タグを検索できる。
- ホームでデッキ（子孫を含む）とタグ（選択したすべてを含む）を絞り込む。新規上限と日次目標は全体で共通。セッションに学習対象を保存し、再開時もその範囲を利用する。
- ライブラリの一括登録からUTF-8 CSV / TSV / TXTファイル、Q:/A:・タブ区切りの貼り付けを取り込む。ファイル上限10MB。ヘッダー有無と問題・解答の列を選び、プレビューで各行を編集・除外してから確定する。通常文章は編集用テキストとして扱い、問いを自動生成しない。
- 同一デッキの形式・正規化した問題と解答から重複候補を判定。初期はスキップ。別ノート追加／更新は明示選択し、更新の未学習リセットも明示操作とする。手入力でも重複確認を表示する。
- 保存成功・スキップ・行エラーを表示し、ImportBatchに結果を保存。保存失敗時はNote/Card/Tag/Batchのすべてをrollbackする。
- 同じNoteの兄弟Cardは同日出題を抑制し、短期学習・再学習だけ例外にする。設定で変更可能。抑制によるFSRS状態・dueの変更はしない。

### 移行と検証

`StudySchema` v1モデルは変更せず、v2にTag / ImportBatch / SessionScope / ExtraPreferencesを追加。SchemaMigrationPlanの軽量移行を実装し、実際のv1ディスクストアからUUID・FSRS・ReviewLog・SessionDraftを維持するテストが成功。

2026-10-08、日本時間：iPhone 17 Pro / iOS 26.5 Simulatorで**全30件成功、失敗0、スキップ0**。[集計](docs/verification/phase2-test-summary.json)。CSVの引用符内カンマ・改行・エスケープ、列マッピング、欠落値、パース拒否、貼り付け、階層・循環・移動、タグ共有、スコープ、兄弟制御、重複と履歴保全、失敗時の原子性、v1移行を検証。UIで親子デッキ作成→親スコープで学習、貼り付け→プレビュー→成功2／重複スキップ1／エラー1→学習を確認。結果画面を視覚確認済み。Debug Simulator・Release arm64（署名なし）のビルド成功。

結果：`/private/tmp/anki-phase2-tests-v2.xcresult`、Releaseログ：`/private/tmp/anki-phase2-release-final.log`。実機と最低OSは未検証。Phase 2時点ではファイル選択UIは未自動化だったが、Phase 5で標準Filesを経由するCSV取込も検証済み。穴埋め・画像・OCRはPhase 3で追加済み。

## Phase 3 — 穴埋め・画像・OCR

- カード編集の形式を「穴埋め」にして `{{c1::東京}}` などを入力する。同じ番号は1枚にまとまり、任意のヒントは `{{c1::東京::都市名}}` と書ける。既存番号を維持する限り、文章の順序変更でもCard IDとFSRS状態を保つ。
- 一問一答では裏表反転カードも追加できる。「出題プレビュー」で生成カードと解答を確認し、保存して次の入力へ進むこともできる。入力下書きは再起動後に復元し、保存確定と同じトランザクションで取り除く。
- 写真を選択または撮影し、「画像マスク」で範囲をドラッグして追加する。中央への追加、マスク選択・移動、位置・幅・高さの数値調整、削除、個別解答を利用できる。全マスクを隠す／対象だけ隠すを選び、各マスクを独立して復習する。マスクUUIDを維持した位置変更は履歴を保つ。
- 画像は向きを正規化したJPEGとしてApplication Support/Study/Mediaへ保存。入力上限20MB・40メガピクセル。トリミングではマスク座標を新しい画像に合わせて変換する。画像を読み込めないカードは評価せず、編集から写真を再選択する。
- ライブラリの文字認識ボタンから写真を選び、Visionで端末内OCRを実行。対応する日本語・英語を選択し、認識結果を編集して一括登録プレビューへ進む。編集画面でも画像の文字を問題文に追加できる。AIによる問題生成は行わない。
- SwiftData V3にMediaAsset / EditorDraftを追加し、V1→V2→V3の軽量移行を実装。既存モデル宣言は維持する。確定失敗時は下書き・画像参照を保護し、参照のない管理画像を清掃できる。

2026-10-09、日本時間：iPhone 17 Pro / iOS 26.5 Simulatorで全43件同時成功（単体／結合35＋UI8、失敗0）。さらに画像の破損参照保護・編集下書き削除の1件を追加し、最終単体／結合36件を再実行してすべて成功した（検証したテストは合計44件）。[全体集計](docs/verification/phase3-test-summary.json)、[最終単体／結合集計](docs/verification/phase3-unit-summary.json)。

Visionのローカル文字画像認識、独立マスク状態、座標の拡大縮小、トリミング、画像保存失敗、孤立ファイル清掃、下書き保全、V2→V3移行を検証。UIでは穴埋めの下書き→再起動→プレビュー→学習→Undo→編集、PhotosPicker→マスク追加→全画像トリミング→学習→再起動→履歴維持編集、OCR→認識結果修正→一括プレビュー→確定→学習が成功。主要4画面の画像を視覚確認済み。

Form内の複数ボタン同時発火と、全幅・全高マスクのゼロ範囲SliderクラッシュをUI検証で発見して修正。テスト用DB・画像管理領域は通常データから分離する。最終Debug（テスト用）・Release arm64（署名なし）ビルド成功。結果は `/private/tmp/anki-phase3-all-v6.xcresult`、`/private/tmp/anki-phase3-unit-v7.xcresult`、Releaseログ `/private/tmp/anki-phase3-release-v7.log`。実機カメラ・日本語OCR精度・iOS 17実行は未検証。

写真UIテストにはシミュレーターの写真ライブラリに画像が必要。空の場合は `xcrun simctl addmedia booted <画像のパス>` でローカル画像を追加してから実行する。今回の検証ではTOKYO CAPITALと描いた画像を追加し、PhotosPickerの実際の選択画面を使用した。

## Phase 4 — 通知・統計・触覚・完全バックアップ

設定で復習通知をオンにしたときだけ通知権限を要求する。初期設定はオフ。新規・停止カードを除き、各日の指定時刻までに期限が来るカードがある日だけ、今後30日分を1日1通予約する。学習・Undo・編集・起動・foreground復帰で差分更新し、配信済みの日は再通知しない。拒否時は設定アプリへの案内を表示する。予約件数はOSから取得した件数を表示する。30日以上起動しない場合の補充やiOSの配信時刻は保証できない。

記録タブは、4時境界の過去30日ユニーク学習枚数・回答数、継続日数、4評価の内訳、回答時間、現在の平均想起確率を表示する。設定で触覚をオフ／標準／豊かから選ぶ。答え表示・評価・Undo・目標達成にUIKitのフィードバックを使い、対応実機の目標達成にはCore Hapticsを使う。Reduce Motionを有効にすると学習中のアニメーションを抑制する。

設定→バックアップ・復元から、標準のファイル書き出し／選択画面を使う。`.studybackup`の実体はZIPで、manifest・JSON・画像を含む。デッキ階層・タグ・4形式のノート／カード・UUID・全FSRS状態・全回答履歴・インポート結果・設定・学習／編集下書きを保存する。復元は内容検証→新しいSwiftDataストアと画像領域への保存→再読み込み比較→保存先ポインターの原子的切替の順で行う。置換は明示確認が必要。失敗時に元の保存先を変更しない。再起動でも切り替え先を開く。既存モデルやFSRS依存は変更していない。

ZIPは[PKWAREの形式仕様](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)に沿った無圧縮UTF-8ファイルの限定プロファイル。CRC32とSHA-256、パス、中央ディレクトリとローカルレコード、UUIDと参照、FSRSとdue、画像形式と寸法を検証する。上限は合計200MB・1万ファイル・1エントリー50MB（画像20MB）。暗号化・ZIP64・再圧縮したZIPは拒否する。ファイル内容を外部送信しない。古いDBは自動削除しないため、繰り返し復元すると保存容量が増える。現在データの画像清掃は参照のない管理画像だけを対象にする。

2026-10-09、日本時間：iPhone 17 Pro / iOS 26.5 Simulatorで**全63件成功、失敗0・スキップ0**（単体／結合53＋UI10）。[集計](docs/verification/phase4-test-summary.json)。完全復元・復元後Undo、原子的保存の失敗保護、不正バックアップ拒否、通知の日付・DST・時間帯・差分・非同期競合を検証した。標準ファイルUIで書出し→選択→置換復元→再起動と、通知のOS予約30件→オフで0件→再起動が成功。復元後・予約画面の画像を確認済み。Debugテスト用ビルド、Release arm64（署名なし）とも成功。結果 `/private/tmp/anki-phase4-all-v3.xcresult`、Releaseログ `/private/tmp/anki-phase4-release-v1.log`。実機の触覚感触・通知の実配信・カメラ・iOS 17は未検証。Phase 5の最終結果は以下に記録。

## Phase 5 — 品質仕上げ（完了）

学習時の表示生成を対象カードに限定。保存失敗と、保存成功後の画面更新失敗を別に扱い、保存済み評価を未確定と誤表示しない。削除したデッキの新規入力下書きは残ったデッキに切り替えて編集でき、削除ノートの編集下書きは除去する。復元が中断して残った管理画像を清掃できる。バックアップの極端な日時・数値・セッション時間も切替前に拒否する。

最大Dynamic Typeでは回答方式を標準メニューで選択し、問題・解答の読み上げフォーカスを更新する。学習中にも目標進捗と達成を文字で表示し、達成をアクセシビリティ通知する。画像マスクは、ドラッグ以外に中央追加と位置／寸法の標準Sliderから編集できる。

利用時は、ライブラリで登録・編集・管理、一括登録でCSV等と貼り付け、文字認識で写真からOCR、ホームで学習、記録で統計、設定で通知・触覚・バックアップを操作する。バックアップは検証成功後にファイルUIへ渡す。アプリ削除前に、本アプリの保存領域以外にもファイルを保管する。アプリ削除では同じアプリ内のDocumentsも削除される。


### 最終検証結果（2026-10-09、日本時間）

- iPhone 17 Pro / iOS 26.5 Simulatorで**全71件成功、失敗0・スキップ0**（単体／結合58＋UI13、Phase 0の6件を含む）。[全体集計](docs/verification/phase5-test-summary.json)。
- 最後にtypingの解答比較で入力欄の重複表示を除去し、関連UI2件を再実行して成功。[再検証集計](docs/verification/phase5-typing-summary.json)。再起動後の入力下書き・回答方式変更、ダーク／最大Dynamic Typeの比較・採点を検証し、最終画面を視覚確認した。追加2件は全71件に含まれる同じテスト。
- 最終Debug Simulator（UIテスト用）とRelease arm64 iOS（署名なし）のビルド成功。全体結果 `/private/tmp/anki-phase5-all-v3.xcresult`、最終UI結果 `/private/tmp/anki-phase5-typing-final.xcresult`、Releaseログ `/private/tmp/anki-phase5-release-final2.log`。これらは一時ファイルで永続保管は保証しない。JSON集計と再現可能なテストはリポジトリに保存。
- 1000ノート・3000カード・10000履歴の規模試験：初期読み込み0.66秒、学習開始・評価・Undo 1.20秒、完全バックアップ・検証・復元・再読み込み2.99秒。単発のシミュレーター測定で、実機の性能保証ではない。
- 標準FilesからCSV取込、破損バックアップ拒否後のデータ保持、3000枚のホーム→学習→Undo→再起動→再開、最大Dynamic Type・ダーク・アクセシビリティ要素検出／説明の監査も成功。

実機・iOS 17ランタイム、実際の通知配信／タップ、カメラ、日本語OCR精度、触覚の感触、VoiceOver音声、実際のReduce Motion設定、実機の機内モードは未検証。実装と検証の対応・実機での確認手順は [MVP受け入れ検証](docs/mvp-acceptance.md)、Phase別の記録は [実装進捗](docs/implementation-progress.md)、追加・変更ファイルは [一覧](docs/verification/mvp-changed-files.txt) にまとめた。
