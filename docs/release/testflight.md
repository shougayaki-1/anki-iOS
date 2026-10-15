# 個人用TestFlight内部配布（Issue #228）

対象は本人のiPhone 1台。App Store公開・外部テスト・公開リンクは対象外。
このPRはリポジトリ準備まで。Apple側の登録・署名資産更新・アップロード・招待・実機インストールは本人が行う。mainへのマージも別途判断する。

## 固定する識別情報

| 項目 | 現在値 |
| --- | --- |
| Project / shared Scheme | `AnkiIOS.xcodeproj` / `AnkiIOS` |
| Team | SETB, NPO / `2Y7P9MQJ4W`（READMEの記録。現在の会員資格・権限はApple側で再確認） |
| iOS本体 | `dev.shoug.AnkiIOS` |
| Widget extension | `dev.shoug.AnkiIOS.StudyProgressWidget` |
| App Group（両ターゲット） | `group.dev.shoug.AnkiIOS.widgets` |
| バージョン / ビルド（リポジトリ初期値） | `0.1.0` / `1`（本体・Widget共通） |
| 最低OS / 本体対応 | iOS 17 / iPhone・iPad |
| Archive | Release、arm64、`-O`、dSYMあり |
| 署名 | Debug/ReleaseともAutomatic。Widgetは`SKIP_INSTALL=YES`で本体内に埋め込む |

本体の`App/Resources/AnkiIOS.entitlements`とWidgetの`Widgets/StudyWidget.entitlements`は同じApp Groupのみを宣言。署名時にApp ID・Team ID等が付加される。macOS用のBundle ID・entitlementsはiOS配布に使わない。Personal Teamへの切替、識別子の変更、アプリ削除、証明書・プロファイルの失効は禁止。

## 1. 導入前に本番データを保全（本人）

1. 現在の開発署名版を消さずに開く。設定 → バックアップ・復元で**完全バックアップ `.studybackup`**を出力する。`.studydeck`は完全バックアップの代用にしない。
2. 「このiPhone内／暗記ノート」以外に保存し、さらにMacなど端末外へコピーする。ファイルサイズ・出力日時を確認する。バックアップは暗号化されていないため、個人情報として管理しGitHub・PR・ビルドログへ添付しない。
3. 復元確認は**分離したSimulatorの同じソース版**で行う。本番iPhoneへの置換復元を試験に使わない。Simulatorへバックアップを渡し、復元 → 再起動 → 件数、デッキ階層、画像・音声、履歴、設定を確認する。既存バックアップ検証のチェックサム・内容検証が通ることも確認する。確認できなければ初回上書きを保留する。
4. 更新前バックアップのカードUUID・FSRS（stability/difficulty/reps/lapses/due等）・ReviewLogを比較基準として保持する。画面で確認できない値は、更新直後の完全バックアップ内のJSONと**ローカルで**比較する（manifest・JSON・メディアを含むZIP）。確認前は新規学習を行わない。
5. 可能ならFinderの暗号化端末バックアップも取得。これは完全バックアップの復元確認の代用にはしない。

通常ストアはアプリ内Application Support（`Study/Study.store`や復元先を示す`Study.active.json`等）。Widget用App Groupには集計スナップショット`progress-v1.json`を共有し、SwiftDataストア自体を移動していない。このPRは保存先・スキーマ・FSRS・復元ロジックを変更しない。

同じBundle ID・Teamを維持するのは更新の前提だが、開発署名版からTestFlightへの上書き成功・データ保持は実機確認まで断定しない。既存インストールの`application-identifier`のprefixも配布版と照合する。削除や初期化、別Teamへの変更を求められたら中止し、バックアップを保持したまま原因を調べる。旧版へのダウングレードはスキーマ互換性が不明なため復旧手段として安易に使わない。

## 2. Apple側のチーム・アプリ登録（本人）

1. Xcode → Settings → Apple AccountsとApp Store ConnectでSETBを選ぶ。Developer Program会員資格・契約の未同意がないこと、App Manager等のアプリ作成権限とCertificates, Identifiers & Profilesアクセスを確認。必要ならAccount Holder/Adminに依頼する。
2. DeveloperサイトのIdentifiersで本体・Widgetの**明示的App ID**と上記App Groupの関連付けを確認。既存レコードを優先し、無断で作り直さない。ワイルドカード開発プロファイルの存在だけでは配布可能とは判断しない。
3. App Store Connect → Appsで同じBundle IDの既存アプリを検索。存在すれば利用。なければ「＋ → New App」で次を入力する（本人が登録実行）。

| 登録項目 | 入力候補 |
| --- | --- |
| Platforms | iOS（Widgetの別アプリ登録は不要） |
| Name | 暗記ノート（使用不可なら表示名のみ相談し、Bundle IDは変えない） |
| Primary Language | Japanese |
| Bundle ID | `dev.shoug.AnkiIOS`（SETBの明示的App ID） |
| SKU | `anki-ios-personal`（チーム内未使用を確認。任意の内部管理値） |
| User Access | 必要最小限。本人がアクセスできること |

App Store用スクリーンショット・公開用説明・審査提出をこの段階で完成させる必要はない。登録できない場合は権限・契約・App IDを確認し、別Bundle IDに逃がさない。

## 3. バージョンを決め、Release Archiveを作る

App Store Connectの既存ビルド番号とOrganizerのローカル配布履歴を確認し、それらより大きい未使用番号を選ぶ。初期値`1`が未使用とは仮定しない。バージョンは当面`0.1.0`を維持できる。本体・Widgetでバージョンとビルド番号を必ず一致させ、再アップロード時も新しい番号を使う。番号をリセットしない。

### Xcode Organizer

1. 配布対象のコミットを選び、`AnkiIOS.xcodeproj`を開く。SPMはコミット済み`Package.resolved`の固定リビジョンで解決する。
2. 本体とWidgetのGeneral → Version / Buildを両方更新する。Signing & Capabilities → ReleaseでSETB・Automatic・既存App Groupを確認する。
3. Scheme `AnkiIOS` → Edit Scheme → ArchiveがReleaseであることを確認。実行先を**Any iOS Device (arm64)**等の汎用iOSデバイスにする。macOSやSimulatorを選ばない。
4. Product → Archive。Organizerで本体アプリのArchiveになり、Widgetが同梱されることを確認。
5. Validate Appが利用できる場合は本人が実行し、署名・entitlements・バンドル・アイコン・Privacy Reportのエラーを解消する。Validateが配布フロー内にある場合は検証結果を確認して**Uploadの直前で止める**。Archive成功やローカル`codesign`検証と、Appleの配布検証は別。

### CLI（Archiveのみ、アップロードしない）

```sh
# 例の2は、Apple側・ローカル履歴で未使用かつ既存番号より大きい場合のみ使う。
./tools/archive-testflight.sh 2 /private/tmp/anki-testflight-build-2
open /private/tmp/anki-testflight-build-2/AnkiIOS.xcarchive
```

macOSのXcode・コマンドラインツール・既存の有効な署名identity/profilesが必要。スクリプトは新規出力先のみ受け付け、全ログをそこに保存。本体とWidget双方へ`CURRENT_PROJECT_VERSION`を同時適用し、追跡ファイルの初期値は書き換えない。番号は呼出者が台帳で管理する。出力物の既定マーケティングバージョンはプロジェクト設定に従う。

同等の手動コマンド：

```sh
xcodebuild -project AnkiIOS.xcodeproj -scheme AnkiIOS \
  -configuration Release -destination 'generic/platform=iOS' \
  -onlyUsePackageVersionsFromResolvedFile \
  -archivePath /private/tmp/AnkiIOS-build-2.xcarchive \
  -derivedDataPath /private/tmp/AnkiIOS-build-2-derived \
  CURRENT_PROJECT_VERSION=2 archive > /private/tmp/AnkiIOS-build-2.log 2>&1
```

`-allowProvisioningUpdates`を自動付与しない。署名エラーなら本人がXcodeでアカウント・配布権限・App Group付きプロファイルを確認する。無署名Archiveを配布可能と扱わない。スクリプトはexport/upload/installしない。開発署名ArchiveはOrganizerで配布用に再署名されるため、配布時の本体・Widget両方の署名を改めて確認する（Team、App ID、App Group、`get-task-allow=false`、有効な配布プロファイル）。

## 4. 初回アップロードと本人だけの内部テスト（本人）

1. バックアップ・署名・番号の確認後、Organizer → Distribute App → **TestFlight Internal Only**を選択。Xcodeの版によってはApp Store Connect設定内の「TestFlight internal testing only」に相当する。外部テスト・App Store公開向けを選択しない。
2. 対象アプリ・SETB・バージョン／ビルド・署名・内部限定を最終確認し、**本人の判断でUploadを実行**。自動バージョン管理が番号を書き換える場合は、最終番号とWidget一致を確認し台帳へ記録。手動採番と混在させない。
3. App Store Connect → 対象アプリ → TestFlight → iOSで処理完了を待つ。Missing Complianceや署名・Privacy Manifestエラーは内容を確認して対応する。必要な申告を事実確認せず埋めない。
4. 内部テストグループ（例`Personal Internal`）を作成。初回は自動配布をオフにし、本人のApple Accountだけを選択する。内部テスターは対象アプリにアクセスできるApp Store Connectユーザーで、対応ロールが必要。Managed Apple Accountはテストに使えない。
5. **Internal**表示のビルドを手動でグループへ追加し、本人だけを招待する。Xcode Cloudビルドは内部グループへの自動配布の扱いが異なるため、Cloud設定時にpost-actionと割当を確認する。外部グループ・公開リンクは作成しない。
6. iPhoneにTestFlightを用意し本人のアカウントで受諾。初回は自動アップデートをオフにして導入タイミングを管理し、手順1の保全完了後に既存アプリへ上書きする。アプリのアンインストールはしない。
7. 起動直後にバックアップを出力して更新前と比較。カードUUID・FSRS・due・ReviewLog・件数・メディア・設定、再起動後の永続化を確認。その後カード1枚の学習 → 保存 → Undo → 再起動の限定スモークを行う。
8. 既存Widgetの表示更新とタップによる`ankistudy`遷移、通知許可と予約・実配信・タップ遷移を確認。ローカル通知なのでAPNs entitlement/キーの追加は不要だが、更新後の通知継続は実機確認が必要。
9. 成功してからTestFlightの自動アップデートを有効化。ビルドはアップロードから最大90日で失効する。60日程度を目安に次の配布を計画し、期限前に必ず新ビルドを導入する。失効はデータ削除を意味しないが起動できなくなるため、常に端末外バックアップを保持する。

### 入力文案と申告確認

- Beta App Description案：端末内でデッキ・カードを管理し、FSRSによる復習、学習記録、Widget、通知、完全バックアップを利用する個人用暗記アプリです。開発者本人の内部テスト専用です。
- What to Test案：開発版からの上書き後のデッキ・カードUUID・学習履歴・FSRS状態の保持、学習保存とUndo、再起動後の保持、Widget更新と遷移、ローカル通知、画像・音声と完全バックアップの復元を確認してください。
- Feedback Email等が要求されたら本人が管理する連絡先をApple側に入力する。実アドレス・Apple Account・パスワード・2FA・APIキーをGitへ記録しない。
- プライバシー：端末内保存の設計。カメラ・写真・マイクの用途説明、依存SDK・診断・外部通信を含め実際の収集を再確認してApple側の質問に回答する。バックアップのユーザーによる外部保存とアプリによるデータ収集を区別する。
- `PrivacyInfo.xcprivacy`を本体Resourcesに追加。UserDefaultsはショートカットのアプリ内ナビゲーション（CA92.1）、ファイル更新日時は内部画像キャッシュ・一時バックアップ清掃（C617.1）、systemUptimeは統計計算の経過時間（35F9.1）。追跡・収集なしの現状を宣言。WidgetにもApp Group内スナップショットのサイズ等メタデータ読出し用C617.1を収録。UserDefaults・uptimeの宣言は本体のみ。依存ライブラリ含む最終判定はOrganizerのPrivacy ReportとApple検証で確認する。
- 輸出コンプライアンス：CryptoKitのSHA256/SHA1はバックアップ・メディア・インポートの整合性検証。ZIPバックアップは非暗号化。OSや依存ライブラリも含めて暗号利用の質問を確認する。これだけで免除可否を断定せず、本人がAppleの質問に回答する。`ITSAppUsesNonExemptEncryption`はこのPRでは未設定のままとし、根拠なくfalseを固定しない。

## 5. 初回成功後のXcode Cloud運用案

まず初回の上書きとデータ保持を確認してから導入する。新しいGitHub Actions署名基盤を作る必要はない。

1. Xcode → Product → Xcode Cloud → Create Workflow等からSETBの本体アプリを選択。GitHub接続は本人が承認し、アクセスを`shougayaki-1/anki-iOS`の必要範囲に限定する。現在のリポジトリ公開設定も本人が確認する。
2. 共有Scheme `AnkiIOS`、iOS、Release Archive、対応する安定版Xcodeを選択。コミット済みSPM固定revisionの取得を確認。初期は配布しないビルドを試し、Cloudの署名・App Group・本体＋Widgetの埋込みを確認する。
3. 開始条件は**本人が配布対象を選んで更新する専用`testflight`ブランチ**（作成・更新は別途本人判断）を推奨。mainの全マージや全PRを配布トリガーにしない。必要なら手動起動のみの条件とする。
4. Cloudの次回ビルド番号を既存アップロードの最大値より大きく設定する（Admin/App Managerが設定）。以後Cloudを番号の管理元とし、ローカルで緊急配布する場合もCloudと衝突しない番号を予約する。本体とWidgetの実際の番号一致を確認。
5. Archive配布先を内部テスト専用にし、TestFlight internal testing post-actionを本人だけのグループへ設定する。外部テスト・App Review配布は設定しない。Cloudビルドの割当と本人への通知／利用可能状態を実際に1回確認する。
6. 使用可能な計算時間・料金・課金権限をSETB側で確認し、対象ブランチと実行回数を制限する。秘密鍵やApp Store Connect認証情報をGitHub Secretsへ転記する構成は採用しない。Cloud管理署名でも他の証明書を無断失効させない。

継続運用：PR → レビュー → 本人がmainへマージ → 配布対象コミットを専用ブランチへ選ぶ → Cloud Archive／内部配布 → iPhoneのTestFlightで更新。初期設定後はブラウザ/GitHubとiPhoneで運用でき、毎回Xcodeを開く必要はない。失敗時はCloudログで原因を確認し、既存アプリを残す。60日ごとの配布確認と90日期限対策はCloudでも必要。

## 検証記録（2026-10-15）

- 起点：最新取得したmain `2e640db`、Xcode 27.0（27A266a）。署名付きiOS Release Archive成功。本体＋Widgetのstrict署名検証、Team/App ID/App Group、`0.1.0 (1)`一致、最低iOS 17、両dSYMを確認。埋込み開発プロファイルは両方2027-10-11 UTCまで有効、`get-task-allow=true`。配布用再署名の検証とは別。
- ログとArchiveは`/private/tmp/anki-228-signed.log`、`/private/tmp/anki-228-signed.xcarchive`（一時ファイル、Gitへ追加しない）。既存のSwift警告あり。無関係なコードは修正しない。
- 最終版：両Manifestを含む署名付きRelease Archive `0.1.0 (2)`成功。本体／Widgetのstrict署名、識別子、App Group、有効プロファイル、バージョン一致、Manifest実体一致、両dSYMを確認。`/private/tmp/anki-228-verified.xcarchive`・`/private/tmp/anki-228-verified.log`。番号2はローカル検証のみで、Apple側の未使用確認・予約はしていない。
- Archiveスクリプトの実行成功、引数不正の拒否、bash構文、plist/project構文、差分の空白チェックが成功。通常／Darkアイコンは1024×1024、アルファなし。データ処理は変更しないため単体／UIテストは実行しない。
- **未検証**：Appleの配布用再署名とValidate、現在の契約／権限、登録、輸出申告、アップロード、本人の招待、実機上書き／データ保持、Widget・通知の実機動作、実データの復元、Cloud接続／配布。Apple側操作や実機データ操作は実施していない。Issue全体の完了は本人によるこれらの確認後。

## Apple公式資料（2026-10-15確認）

- [アプリ登録](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app)
- [Archiveからの配布](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)
- [内部テスターとCloud配布の制限](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers)
- [TestFlightと90日期限](https://testflight.apple.com/)
- [Required reason API](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- [輸出コンプライアンス](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)
- [CloudでのTestFlight配布](https://developer.apple.com/documentation/xcode/distributing-your-xcode-cloud-builds-through-testflight)
- [Cloudビルド番号](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds)
