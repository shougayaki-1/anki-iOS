# 軽量化の計測（Issue #152）

## 隔離した再現データ

実データの削除・上書き・復元は行わない。DebugのScheme > Run > Argumentsに、毎回新しいUUIDで次を指定する。

```
-study-test-store <UUID>
-study-performance
-study-test-scale-basic
```

3,000 basicノート/3,000カード/履歴0件、20デッキを作成する。最後の引数を `-study-test-scale` にすると1,000 clozeノート/3,000カード/10,000履歴になる。既存ノートがあるストアは再生成しない。同じUUIDで再起動して永続化を確認できる。時計は起動時刻基準。新しいUUIDでは新しいデータを作るため、初回生成時間を通常の起動時間に含めない。

`UITestStores/<UUID>.store` と `UITestMedia/<UUID>` は通常ストア・メディアと別。ウィジェットは無効、通知はテスト用識別子になる。画像混在はこの隔離ストアにコピーした画像のみ取り込む。元画像は変更しない。

## 採取

実機・iOS・commit・Debug/Release・データ件数・画像総容量・冷間/温間・電源/温度を記録する。初回生成完了後にホームへ戻り終了し、再起動を測る。各操作は同条件で5回程度測定し、各回の値と中央値/最大を残す。順序とキャッシュの有無も記録する。

1. 冷間起動→ホーム、ライブラリ初回→デッキ展開→連続スクロール→検索。
2. basicは新規学習、clozeは復習開始→解答表示→評価→Undo→中断/再開。
3. ホーム復帰、記録タブ初回/再表示、スコープ変更。
4. 別の空の隔離ストアでCSV/画像ZIP/studydeck/APKGを取り込む。入力件数・サイズ・画像の重複率を記録する。

InstrumentsでTime Profiler、Hangs、SwiftUI、Allocationsを採取する。OS Signpostのsubsystem `dev.shoug.AnkiIOS` / category `Performance` でWorkspace、Store、Repository、Library、Statistics、Importの区間を対応づける。固定区間名だけを出し、カード本文やIDはログに含めない。区間は成功/失敗/キャンセルとも終了する。区間の経過時間はフレーム数・メインスレッド停止・CPU時間ではない。スクロールのfps/遅いbody更新、メインスレッドの支配的スタック、プロセスのピークRAMをそれぞれ別に採取する。

Releaseはfixtureとsignpostがコンパイルされない。実機Release比較は別bundle IDのビルドに同一のテストデータをインポートして行う。通常アプリへRelease計測のために書き込まない。DebugとReleaseを同じ列で比較しない。SwiftDataのfetch行数とJSON decode件数は後続PRのDEBUGカウンター/既存ScaleRepositoryTestsの出力を対応づける。SQL発行数と取得行数を混同しない。

記録は「環境、操作、5回の壁時計値、fps/停止、ピークRAM、fetch/decode、支配的スタック、関連Issue」の小さな表と必要なtraceだけでよい。性能の固定しきい値をCIに追加しない。

## 現状と確認範囲

以下は先行PR時点の状態。今回の実機再確認・判定は末尾の「実機再計測」を参照。先行PRではSCW-iPhone（iPhone 15 Pro）が未接続で、実機のfps、Hangs、ピークRAM、上位3件は未採取だった。

2026-10-12、シミュレーター（iPhone 17 Pro / iOS 26.5、Debug）でfixture件数・再生成による既存ID変更なし、Queue cache/評価/Undo/rollback、既存学習/Undo/再起動の計3件が成功。Debug・Releaseビルドも成功。シミュレーターのデータ処理時間やbitmapサイズを実機RAM/fpsの代用にしない。

後続の専用PR：対象カード取得 #157、学習経路 #153、入力保存 #154、統計 #158、通知/Widget #155、画像 #156、インポート #159、ライブラリ #121。これらの既存測定は純粋な処理時間中心で、実機の上位3スタックを確定する証拠ではない。

参考：[Apple: Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)、[OSSignposter](https://developer.apple.com/documentation/os/ossignposter)。

## 実機再計測（2026-10-12、22:21〜、JST）

### 環境・安全性・条件

- main/origin/main = `6a097b8`、作業前の変更なし、Open PRなし。#161〜#169と#149はマージ済み。#154もPR #163で実装済みだが、今回の指定どおり参考測定のみ・Closeしない。
- SCW-iPhone / **iPhone 15 Pro、iOS 27.0.1 (24A446)**、有線、paired、Developer Mode Enabled。通常sandboxでのCoreDevice初期化タイムアウトはアクセス制限に起因し、権限付き照会ではconnected。端末未接続やアプリ不具合とは区別する。
- Xcode/Instruments **27.0 (27A266a)**。Simulator iPhone 17 Pro / iOS 26.5も利用可能だが、今回の値は実機。Debug `-Onone` / arm64e / deployment target 17.0。Release値・改善率は採取していない。
- mainを一時ディレクトリへ`git archive`し、app/widget/testのBundle IDを`dev.shoug.AnkiIOS.PerformanceAudit`系列へ分離。専用App Groupはアカウント/署名不足でビルド不可だったため、一時コピーのapp/widget entitlementsを空にし、共有グループの参照文字列も専用名にした。署名済みappのapplication-identifierとApp Group権限なしを確認。本番Bundle IDの削除・インストール・起動・データ書込は行わない。これをWidget実OS検証とは扱わない。
- A=3,000 basicノート/3,000カード/履歴0、B=1,000 clozeノート/3,000カード/10,000履歴、20デッキ。既存`UITestFixtures.populateScale`とScaleRepositoryTestsを再利用。UUID別`UITestStores`/`UITestMedia`、Repositoryはin-memoryまたはUUID別一時SQLite/Media。fixture再生成時のUUID/履歴不変も既存テストで確認。
- UIはA/B各3回。生成後に同じストアでプロセスを終了・再起動した「プロセス冷間、ファイル/SQLiteキャッシュ温間」。OS再起動やキャッシュ排出は行っていない。各巡のストアは新しいUUIDで、自動スナップショットが必要になり得る条件を含む。電源は有線、温度・低電力モードは未記録。
- APIは既存10測定テストを3回実行。学習/統計は各テスト内3巡なので各9標本。時刻・データ形状・ストア種別は各既存テストに従う。UIのBは復習開始、学習APIは履歴付き新規開始であり、同じ処理として比較しない。

### 主なAPI値

中央値（最小〜最大）、ms。画像bitmap/推定キャッシュ量・CPUサンプル・UI描画時間・実RAMを混同しない。全標本は[device-20261012.csv](device-20261012.csv)。

| 処理 | 実機Debug、ms | 標本数 |
| --- | ---: | ---: |
| 履歴付きRepository新規開始 | 118.70 (114.59〜122.87) | 9 |
| Store Good評価＋投影 | 259.11 (253.66〜266.02) | 9 |
| Store Undo＋投影 | 135.89 (134.04〜142.36) | 9 |
| 開始→評価→Undo内のキュー投影合計 | 225.35 (221.68〜228.62) | 9 |
| 統計材料初回・revision変更 | 380.13 (370.71〜386.50) | 9 |
| 統計別スコープ | 131.01 (129.60〜132.94) | 9 |
| 統計同条件再訪 | 13.89 (13.22〜14.49) | 9 |

学習1巡は全履歴fetch **0回**、当日履歴取得 **2行**、キュー投影 **4回**、FSRS decode **2回**。材料キャッシュはrevisionごと1 read / 3,000 decode、同条件再訪で再read/decodeなし。別条件の履歴集計は1回追加。保存成功後・Undo・学習日境界・時刻逆行・取消の無効化は関連既存テストが成功。

### 実機Hangsと優先ボトルネック

Time Profiler + Hangs、約443秒。fixture生成のプロセスとXCTest Runnerを除外。Aの3巡目に別Allocations接続がkperfロック競合したため、**A2のHangs/CPUは前後比較や代表的最大値から除外**（約3秒の外れ値も採用しない）。A0/A1とB0/B1/B2の計28区間が250ms以上のpotential hangとして検出された。操作対応はXCTest activity時刻との照合で、signpost単独の確定ではない。

| 優先 | 再現操作・停止区間 | 支配的スタック・振り分け |
| --- | --- | --- |
| 1 | A新規開始483〜513ms、4評価380〜383ms。B復習開始344〜355ms | `StudyStore.start/grade → refreshStudy → queueCards/scopedQueueCards`。全Note/Card取得、タグ/設定/キュー再走査。FSRS decodeだけの問題ではない。#153（#152横断）。同一操作のキュー/スコープ投影共有を先に検討し、上限・兄弟・保存/Undo整合を保持。 |
| 2 | Aホーム復帰392〜398ms、B259〜265ms | `refreshHome → queueCards → notes/cards`。変更のないタブ復帰でも全件投影。#155。必要な時刻・revision・失効条件を区別して再利用する方向を検討。 |
| 3 | B起動後407〜414ms、全履歴収集を伴う | `automaticSnapshotIfDue → createSnapshot → BackupService.export → BackupData.capture → logs()`。10,000履歴・カードをMainActorで収集。#155（関連#127）。バックアップを無効化せず、一貫した読み取り材料の取得を分離する方針を検討。 |

検索でもB 272〜279ms（A 273〜312ms）のpotential hangを再現。#121へ振り分けるが、一覧差分/body/アクセシビリティ処理の内訳は未確定。汎用SwiftUI/UIKitスタックだけで行再生成が原因とは断定しない。Libraryの同デッキ10回再訪は本文decode 0。

初回CPU採取の`Points of Interest`はcategory `PointsOfInterest`のみで、既存category `Performance`を採取できなかった。次回は**`--instrument os_signpost`**を付ける（独立スクロール採取には追加済み）。CPUのサンプル重みはCPU処理時間の推定、potential hangは応答しなかった壁時計区間、API時間は別プロセスの処理時間。inclusiveスタック時間は重複するため足し合わせない。これらを同じ改善率へ換算しない。

### ライブラリの全件スクロールとUIの範囲

`testPerformanceBaselineOperations`はA/B各3回、起動・初回一覧・デッキ開閉・6ジェスチャー・検索/解除・学習開始・4評価/Undo・記録表示・ホーム再訪を成功。最初の6ジェスチャーは1デッキの展開行を対象とする。

別の`testPerformanceAllCardsScroll`でAの検索`Scale`による3,000カード全体を対象に8ジェスチャー×3巡が成功。最初の実行は折り畳まれた検索欄を探して失敗し、テスト側で検索欄を表示するよう修正後に成功。機能不具合とは扱わない。

Allocations + Core Animation FPS + os_signpostをCPU採取と重ならない86秒で採取。FPS推定は86標本、非ゼロ73標本の中央値49、14〜60。残りは静止区間を含む。1秒窓・自動操作の待機・Allocationsの負荷を含み、常時スクロールの最低fpsや120Hzからの落ち込みとは断定しない。SwiftUI body更新数・フレームごとのdrop数は未採取。Allocations/VMの数値はCLIのexport対象に出ず、プロセスRAMとして未集計。トレースの保存成功とRAM測定完了を区別する。

UI_AUDITの秒数はXCTest待機/IPC/ジェスチャーを含む**自動操作の所要時間**。ホーム起動A中央値3,400ms/B3,456ms、一覧A2,760ms/B2,685msだが、実際の描画完了時間や体感遅延として使わない。スクロール動画の目視、触覚/音声の感覚確認は未実施。

### 選択IDの実SQL（#157）

SQLDebugは時間測定と別の1実行。タグなし/1ノート1カード/1デッキ。旧経路の全件取得と新経路は処理範囲が異なるため改善率は出さない。

| 全体 | 選択 | 新NoteItem生成ms（3回） | 実SELECT総数 / Card+Note SELECT | Card行 / Note行 |
| ---: | ---: | ---: | ---: | ---: |
| 3000 | 10 | 1.08 (1.03〜1.12) | 4 / 2 | 10 / 10 |
| 3000 | 100 | 5.37 (5.33〜5.43) | 4 / 2 | 100 / 100 |
| 3000 | 1000 | 48.88 (48.33〜48.96) | 8 / 6 | 1000 / 1000 |
| 10000 | 10 | 1.25 (1.15〜1.29) | 4 / 2 | 10 / 10 |
| 10000 | 100 | 5.86 (5.78〜5.94) | 4 / 2 | 100 / 100 |
| 10000 | 1000 | 50.55 (49.79〜50.60) | 8 / 6 | 1000 / 1000 |

10/100件は`WHERE ZID IN (...)`、1,000件は400件単位の`IN carray(?)`×3（CardとNoteそれぞれ）。余分な2 SELECTは設定とデッキ。新経路のCard/Note無条件全件SELECTは0。実行計画・フラグ画面での実ユーザー頻度・選択時のピークRAMは未検証。

### インポートと画像（#159/#156）

APIのプレビュー/確定/Storeホーム生成。UI描画完了・ファイルピッカー読取全体は含まれない。10ms間隔の`phys_footprint`採取は実機プロセスのサンプリング値で、真のピークを保証しない。絶対RAMは直前のテスト/キャッシュによって変動し、形式間で削減率を計算しない。

| fixture | プレビューms | 確定ms | ホーム生成ms | 確定時sampled peak MiB | 確定直後MiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| CSV 3,000行 | 64.97 (63.74〜65.15) | 739.59 (736.78〜745.33) | 171.73 (168.82〜172.82) | 75.53 (54.92〜75.78) | 59.03 (54.92〜70.02) |
| 画像ZIP 200行・重複画像1枚 | 136.93 (132.67〜137.02) | 230.30 (228.00〜238.81) | 183.94 (180.33〜184.29) | 80.60 (65.85〜84.02) | 79.58 (65.22〜79.86) |
| studydeck 3,000ノート | 144.43 (143.01〜146.67) | 541.87 (537.23〜546.93) | 171.97 (167.67〜172.49) | 67.72 (61.41〜73.33) | 63.16 (47.38〜68.44) |
| 現行APKG 1,900ノート | 451.45 (445.00〜471.50) | 387.58 (377.20〜388.60) | 117.46 (116.26〜117.57) | 65.80 (40.10〜107.78) | 63.22 (37.46〜87.80) |

画像は同じ4,000×3,000 JPEGを別ファイル20個として連続decode。全解像度 366.72 (359.76〜518.27)ms、表示用 280.48 (256.43〜358.11)ms（各3回）。bitmap 24,000,000B→1,769,472B、保持推定24,772,608B（24MiB上限内）、clear後キャッシュ費用0。これは画像連続閲覧のプロセスピーク/終了後RAMではない。独立写真100枚、細字/マスクの目視、メディア付き大容量APKG、取込UI停止・テンポラリ最大使用量・容量不足/途中終了は残件。CSV確定が約740msでMainActor同期処理に残ることは懸念だが、このAPI測定だけで取込画面の実際のhangを測ったとは扱わない。

### Widget/通知・入力

Widgetの値投影は3,000カード/10要求で、同一入力の追加write 0、通知mockの追加plan/add 0。通知の許可・pending・delivered・時計変化を毎回確認する既存回帰も成功。Widget実App Groupへの公開は今回署名構成では未検証。

OS通知UIは許可ダイアログへの自動応答が失敗し、30件予約の期待・配信確認が失敗。通知のコード不具合と断定せず、**実予約・配信未確認**とする。専用アプリの`review-test-`通知だけを既存診断で読み取り・片付けた。OS許可状態0（notDetermined）、testPending 0、testDelivered 0、診断/片付けテスト成功。本番の通知設定は変更しない。

#154参考：現mainはdebounce実装済み。in-memoryで100文字、入力中save 0、停止後save 1、入力ループ 0.40 (0.40〜1.73)ms（600msの待機と実保存は除外）。日本語IME/画面fps/触覚を測った値ではなく、Closeしない。

### 判定と残る手動実機確認

| Issue | 判定 | 判断・残件 |
| --- | --- | --- |
| #121 | C 要修正・Open | 検索のpotential hang再現。再訪decode 0は確認。SwiftUI内訳・行再生成数・実RAM・選択/編集の実機目視が残る。 |
| #152 | C 要修正・Open | 実機主要操作と上位3原因を確認したが、反復するmain-thread停止が残る。Release/体感/RAMの条件を揃えた再測定が必要。 |
| #153 | C 要修正・Open | 全履歴fetch 0とUndo/rollbackを確認した一方、新規開始/評価の反復する停止が残る。キュー/スコープの再利用が修正候補。 |
| #155 | C 要修正・Open | Widget/通知重複抑止は確認。ホーム全件投影と自動backup収集が停止を生む。Widget/OS通知は未確認。 |
| #156 | B 未完了・Open | 20 decode/容量/無効化は確認。連続閲覧のプロセスRAMと細字/マスク品質の目視が不足。 |
| #157 | B 未完了・Open | 6条件の時間/実SQL/整合性は確認。ピークRAM・query plan・フラグ一覧の利用パターンが不足。 |
| #158 | B 未完了・Open | 初回/再訪/条件と無効化は確認。実機で評価後/学習日境界の時間・CPU/RAMと記録画面の目視が不足。 |
| #159 | B 未完了・Open | 4形式×3回の時間/RAM、失敗原子性を確認。大容量独立メディア・取込UI停止・容量不足/取消/テンポラリが不足。 |
| #154 | 参考のみ・Open | 指定どおりClose対象外。IME変換・選択・短時間連続入力は手動。 |

CloseしたIssueは0。Draft PRは測定ヘルパー/資料のみで、性能改善コード・スキーマは変更しない。mainへマージしない。

手動確認は本番アプリにfixtureを入れず、計測専用アプリで次を行う。

1. A/Bで起動→一覧→開閉→検索/解除→ホーム→学習→4評価/Undoを3巡。引っかかった操作、入力から見た目が変わるまでの遅延、電源/温度/低電力を記録。新規評価後Undoで同じ問題と期限・履歴数へ戻ることを確認。触覚と音声は「感じる/聞こえる/二重発火なし」を手動記録。
2. 20〜100枚の**独立した**大型写真/細字/PNG透過/EXIF回転/マスクを表示→再訪→ホーム。Instrumentsでpeak/end phys_footprint・主スレッド停止を記録し、細字可読性、マスク位置と隠し領域、前カード画像の混入なしを目視。
3. 計測専用アプリの通知許可を手動で許可し、既存`testActualDueNotificationDeliveryAndTapReturnsHome`を再実行。30件予約→バックグラウンド配信→テスト識別子をタップ→ホーム→取消0件を記録。Focus/要約/バナー設定も併記。Widgetは専用App Groupの署名後にホーム件数・期限・手動更新を確認。
4. 記録の初回/同条件/条件変更/評価後/04:00境界を揃え、表示回答数・ユニーク枚数・条件の反映、API時間・CPU・RAMを記録。#154は日本語IME変換/文字選択/中断/背景移行を確認して欠落・古い入力復活なしを記録。
5. 別の空の隔離ストアで独立画像ZIP/メディア付きAPKG等をプレビュー→確定→ホーム。time/RAM/main停止/temp最大bytesを記録。取消、保存失敗、容量不足は**専用環境のみ**で既存ID/FSRS/履歴/原本が維持されることを確認。

### 再現・成果物

- 追跡するソースは測定対象main `6a097b8`。一時コピーのBundle ID/app group文字列を専用名へ置換し、app/widget entitlementsを空にしてDebug `build-for-testing`。これは共有機能を確認できない計測構成なので本番へ流用しない。
- 生成された`.xctestrun`の`AnkiIOSUITests.EnvironmentVariables.ANKI_PERFORMANCE_AUDIT`を`1`にする。`test-without-building -only-testing:AnkiIOSUITests/QualityUITests/testPerformanceBaselineOperations`、同`testPerformanceAllCardsScroll`を明示指定。通常実行では2件ともskip。全件スクロールは準備完了ログから15秒のattach時間を設け、CPUとAllocationsを別に採る。
- APIはScaleRepositoryTestsのReviewHotPath/SelectedCardFetch/StatisticsMaterialCache/LibraryProjectionScaleComparisons/ImportBufferScaleMeasurements/AnkiImportBufferMeasurements、MediaRepositoryTestsのTwentyLargeImageDisplay、WidgetSnapshotTests/NotificationServiceTestsのThreeThousandCards、StudyRepositoryTestsのTypedDraftDebouncesを選択して`-test-iterations 3 -parallel-testing-enabled NO`。6件のScale全体や全テストを繰り返す指示ではない。
- 実SQLはSelectedCardFetchScalingだけ別実行でtest host引数へ`-com.apple.CoreData.SQLDebug 1`を追加。SQLDebug有効時の時間を通常値に混ぜない。
- Debug実機ビルド成功。測定10件×3実行=30成功、データ保全/無効化/原子性の関連14件成功、主要UI1件成功（A/B各3巡）、全件スクロール1件成功（3巡、ヘルパー失敗後再実行）、SQL確認1件成功、通知診断/片付け1件成功。通知UI1件は失敗。全テスト・Releaseビルドは今回実行していない。
- 生ログ、xcresult、traceはローカル`/private/tmp/anki-performance-20261012/`。`device-baseline.trace`と`device-scroll-memory.trace`を保持。他プロセス情報や個人情報を含み得るためGitHubへuploadしない。PRにはこの資料・CSVの計測値だけを掲載。CSVのA2は`instruments_interference`として保持し、評価から除外。

### #121 検索結果公開後の行更新（2026-10-13）

`LibraryTreeRowView.equatable()`でデッキ名・件数・開閉、カード本文・フラグ、選択状態、代表カード/兄弟ID、階層が同じ行のbody評価を省く。操作は現在のBindingを参照する。Listの安定ID・1要素1行、Actorの投影/展開、本文キャッシュ制限は維持し、保存形式・学習履歴は変更しない。

隔離fixtureの`-study-performance`で、既存の`Library.projection` / `Library.rows` / `Library.contents`に加え、`Library.preparePublish`（options取得・選択ID整理）、`Library.publish`（状態公開）、`Library.listBody` / `Library.rowBody`（View値の構築）を採取できる。body区間は描画完了時間やFPSではない。Time Profiler/Hangs/SwiftUIと同じプロセス・時刻で照合する。通常起動・Releaseでは追加計測を無効にする既存ガードを使用。

関連テストは更新判定1件、Actorの検索/階層・編集反映2件、既存UIの階層/検索/再起動・選択/取消2件に限定。3,000件実機の停止解消、SwiftUI実描画/FPS、同条件RAM前後比較は別に判断し、未確認の受け入れ条件が残る間は#121をOpenに保つ。

変更後のiPhone 15 Pro / iOS 27.0.1 / Debug -Ononeを専用Bundle ID `dev.shoug.AnkiIOS.Issue121Audit`・UUID別fixtureで確認。関連単体3件、3,000 basicノート/カードの検索と8ジェスチャー×3巡は成功。計測接続の初回PID照合が失敗したため、インストール先とPIDを照合してUI計測のみ1回再試行し成功。本番アプリ・学習データは変更していない。測定用コピーのみApp Group entitlementを空にしており、Widget検証ではない。

対象アプリへ検索前にattachした60秒のTime Profiler + os_signpostでは温度はNominal。検索のActor区間は74.86ms（本文取得66.11msを内包）、投影3.20ms、可視行展開0.66ms、公開準備1.40ms、状態公開0.05ms。検索・スクロールを含む採取範囲で行body127回（合計8.08ms、最大0.79ms）、List body6回（合計1.28ms）。330.70msのpotential hangが1回残るが、開始12.462秒・終了12.793秒で、Actor検索開始13.830秒・状態公開13.910秒より前。停止中のMain ThreadサンプルはUIKitのkeyboard focus/input view経路を含み、List更新の停止とは判定できない。入力開始時のキーボード準備が候補という推論に留める。公開後の250ms以上停止はこの1採取では検出されなかったが、既存の複数回測定と同条件の前後比較ではなく、停止解消・改善率を確定しない。RAM/FPSは未測定。生trace・ログ・xcresultは`/private/tmp/anki-issue121-device/`に保持しGitHubへ掲載しない。
