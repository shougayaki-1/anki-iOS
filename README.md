# anki-iOS

個人用のiPhoneネイティブ暗記アプリ。現在はPhase 0（開発環境・ライブラリ検証）を実装済みです。

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
4. 「検証して保存」を押す。仮想日時で `good → good → again → good` を実行し、UUID、遷移、回答4回・忘却1回、次回日時を保存・表示する。
5. アプリを終了して再起動し、同じUUID・保存件数・状態・次回日時が表示されることを確認する。「検証して保存」を再度押すと別の検証レコードが追加される。

実機では、iOS 17以降のiPhoneを接続し、Xcodeの **Signing & Capabilities → Team** に自分のApple IDのチームを指定する。Bundle Identifierが重複する場合は自分のものに変更する。iPhoneでDeveloper Modeを有効にし、必要な信頼設定を済ませて、その端末を選択して⌘R。通知・カメラ・写真の権限はPhase 0では不要。

### 依存関係とFSRSの採用理由

- Apple SwiftUI / SwiftData（システム標準）。保存領域は端末内、CloudKitは明示的に無効。
- [open-spaced-repetition/swift-fsrs](https://github.com/open-spaced-repetition/swift-fsrs) のコミット **`4fbaf20184d62f82a9f44f343337c61a2c5483e9`** をSPMで固定。プロジェクトのrevision指定と `AnkiIOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` をコミット対象にしている。
- `v5.0.0`のソースでは `FSRSParameters.init` がinternalで、外部モジュールから初期化できない。さらにFSRS-6の21パラメータ定数がないため採用しなかった（このタグはソース確認のみ）。採用コミットは公開初期化子・FSRS-6・短期学習ステップに対応し、実際のiOSビルドとテストを通過。
- アダプターで `FSRSDefaults.defaultWv6` の21パラメータを明示指定し、保持率90%、短期学習オン、fuzzオフ。省略時のFSRS-5デフォルトを使用しない。学習ステップはライブラリ既定の1分・10分、再学習は10分。
- 現在日時を引数で渡し、想起確率はその日時から計算する。全Card状態（`learningSteps`等を含む）をバージョン付きCodableとして保存する。FSRSの内部型をUI・永続化層へ公開しない。

実装前にcontext7から [SwiftUI](https://developer.apple.com/documentation/swiftui) と [SwiftData](https://developer.apple.com/documentation/swiftdata) の最新資料を取得した。swift-fsrsはcontext7未収録のため、公式リポジトリのREADME・公開APIを直接確認した。

### 自動テスト・ビルド

Xcodeでは⌘Uで全6テストを実行する。CLIでも次の手順で再現できる。シミュレーター名・OSは `xcodebuild -showdestinations -project AnkiIOS.xcodeproj -scheme AnkiIOS` の一覧に合わせて変更する。

```sh
xcodebuild -resolvePackageDependencies -project AnkiIOS.xcodeproj -scheme AnkiIOS

xcodebuild test \
  -project AnkiIOS.xcodeproj -scheme AnkiIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath build/DerivedData \
  -resultBundlePath build/Phase0.xcresult \
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

検証用データは本番のNote/Card/ReviewLogとは別のモデル。Phase 1で基本モデルと学習UIを追加する際は、既存ストアを黙って削除せず、VersionedSchemaの更新と必要な移行計画を用意する。現在はPhase 0のみを実装し、カード登録・学習キュー・Undo・通知・バックアップ等は後続Phaseの対象。
