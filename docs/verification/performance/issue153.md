# Issue #153 — 評価・Undo・開始の履歴取得

## 対象と変更

変更前に独立したSQLiteストア（1,000穴埋めノート/3,000カード/10,000過去履歴）で開始→評価→Undoを3回測定。全履歴取得2回とキュー投影6回が確認されたため、全履歴走査と重複キューを削減した。

- 新規評価の上限判定は評価対象のQueueCardと当日履歴を使用。兄弟カードのID、グローバル上限、親デッキ上限を維持。
- 当日履歴の保存済み上限スナップショットを優先。旧ログのfallbackは当日参照カード・ノートのみ400 IDずつ取得し、現デッキ祖先へ対応する。
- 開始は検証済みキューの先頭を再利用。カード・履歴を変更していない範囲でのみ共有する。
- counts/学習空状態も当日履歴へ限定。空状態はpresentationに渡したカードDTOを共有。
- 永続モデル・FSRS計算・評価保存/Undoのトランザクションを変更しない。新たな常駐モデルキャッシュは導入しない。

## 測定結果

2026-10-12、iPhone 17 Pro / iOS 26.5 Simulator、Debug。各値は3回の最小〜最大、時間はms。基準/最終とも同じfixture・計測コード。キュー件数と履歴件数はリポジトリAPIの計測で、内部SQL/fault問い合わせ数ではない。

| 項目 | 変更前 | 変更後 |
| --- | ---: | ---: |
| Repository開始 | 464.50〜471.11 | 96.20〜99.08 |
| Store評価＋画面投影 | 578.31〜614.64 | 214.20〜217.68 |
| Store Undo＋画面投影 | 157.23〜158.67 | 112.43〜113.14 |
| 1巡の全履歴取得 | 2回 | 0回 |
| 1巡の履歴取得行数 | 20,002行 | 2行 |
| 1巡のキュー投影 | 6回 | 4回 |
| 1巡のキュー投影時間 | 289.20〜300.33 | 185.98〜188.21 |
| 1巡のFSRS状態decode | 2回 | 2回 |

開始はRepository API、評価/UndoはStore API。時間に描画fps/通知debounce完了は含まれない。通知とWidgetの投影APIは維持し、Store更新経路を変更していない。

関連StudyRepositoryTests 53件・ReviewQueueTests 12件・規模回帰1件、合計66件成功。Debugビルド成功。上限継承/移動/Undo/旧履歴fallback/日境界/兄弟抑制/待機/セッション残数/保存失敗の既存回帰を含む。Releaseでは追加計測カウンターをコンパイルしない。

再現: `xcodebuild test`に`-only-testing:AnkiIOSTests/ScaleRepositoryTests/testReviewHotPathThreeThousandCardsTenThousandLogs`を指定。ログの`REVIEW_HOT_PATH`を確認する。

## 未完了の受け入れ項目

SCW-iPhone（iPhone 15 Pro）はdevicectl上でunavailable。実機3,000枚の前後比較、Instrumentsでのハング/fps・ピークRAM、主要SQL fetch数は未検証。Draft PRとしてIssueは自動クローズしない。純粋な処理時間を実機の画面性能と混同しない。

## 実機再確認（2026-10-12）

C（要修正・Open）。履歴付き新規開始中央値118.70ms、Good評価259.11ms、Undo135.89ms（API、各9標本）。全履歴fetch 0、取得履歴2行、キュー4回、FSRS decode 2。UIのA新規開始483〜513ms、4評価380〜383msのpotential hangが残り、queueCards/scopedQueueCardsの反復が支配的。Undo/保存失敗rollback回帰成功。キュー/スコープ材料の共有を検討し、体感/Release等の確認を残す。

環境はiPhone 15 Pro / iOS 27.0.1 / Xcode 27 / Debug、専用Bundle ID・隔離ストア。実機データ・全標本・未確認条件・再現方法は[共通実機レポート](README.md)と[CSV](device-20261012.csv)を参照。先行Simulatorの値との改善率は算出しない。

## #153 学習開始の重複整列・Note取得削減（2026-10-13）

対象: 最新main `40ac78c`。PR #162/#178の全履歴fetch 0、開始→評価→Undoのカード投影3回、FSRS decode2回を維持する。評価/Undoの保存処理は再実装しない。

### 原因と変更

実際の開始経路は `StudyStore.start → perform → StudyRepository.start(transaction) → queueCards → scopedQueueCards → todayQueueLogs → ReviewQueueBuilder.queue → selectCard/noteItems → save → StudyStore.refreshStudy → homeSnapshot/counts → presentation/noteItems → 状態公開 → showingReview → SwiftUI`。`Store.start`のsignpostは同期Store更新までで、SwiftUI描画完了を含まない。

- `queue`は`counts`で新規カードを整列した後、同じ候補を出題用に再整列していた。復習専用でも両方実行していた。全体新規上限を先に計算し、デッキ祖先上限を適用した必要枚数までのprefixを一度だけ選ぶ。復習専用は新規選択を省く。
- 同日時のカードの比較ごとにUUID文字列を作っていた。文字列を候補ごとに一度作り、従来と同じ日時/UUID順で整列する。
- 新規デッキ上限がない件数計算は整列不要。件数だけ走査する。上限がある場合は従来の祖先上限による選択を維持する。
- キューのNote→deck投影とスコープのNote→tag判定が別々に全Noteをfetchしていた。ID/deck/tagの値型を既存の同期操作内共有に加える。操作終了、新しいtransaction、rollbackで破棄し、管理モデルは保持/actor間転送しない。
- 混合キューの`removeFirst`反復を添字走査へ置換し、3復習ごとの新規挿入順を維持する。

デッキ/タグでDB取得を限定すると、同じ開始操作で更新する全体ホーム件数・通知/Widget・新規利用履歴の材料を別途揃える必要がある。この変更では全カード取得を残し、重複Note取得と整列を削減する。本文/メディアの全件decodeはしないが、SwiftDataの全モデルfetch自体は残る。`propertiesToFetch`を試すとSimulatorのRepository開始中央値が約117→158ms、投影合計が174→304msへ悪化したため採用しない（faultの詳細は未確定）。別Context/非同期開始や永続キャッシュは導入しない。

### 取得・投影の範囲

通常のカード既定回答モードで、Store.startと保存後表示更新を合わせたコード経路。以下はSQLDebugによるSELECT集計ではない。表示する1カードの`noteItems`の限定fetchは別枠で、選択時/表示時の2回を維持する。ordering overrideの候補本文取得も変更しない。

| 材料 | 変更前 | 変更後 |
| --- | ---: | ---: |
| キュー/スコープ用全Note fetch | 2回 | 1回 |
| Aの同Note行取得総数 | 6,000行 | 3,000行 |
| Bの同Note行取得総数 | 2,000行 | 1,000行 |
| 全Card fetch/投影（Store.start） | 1回/3,000枚 | 1回/3,000枚 |
| 新規整列（デッキ上限なし、新規開始） | 4回 | 1回 |
| 新規整列（デッキ上限なし、復習開始） | 4回 | 0回 |
| 開始→評価→Undoの全カード投影 | 3回 | 3回 |
| 同全履歴fetch / FSRS decode | 0回 / 2回 | 0回 / 2回 |

Note/Card行のDebugカウンターと、開始でNote fetch1回・対象2行・投影1回の既存操作内共有テストを追加確認した。限定scopeでも全体投影枚数は減らしていない。

### 最小限の検証とAPI比較

Context7でAppleのFetchDescriptor/ModelContext資料を取得してから実装。全テストは実行していない。新規テストは同日時UUID順・共有祖先上限・bounded prefixの1件のみ。既存共有テストにNote取得回数/最初の表示カードのassertを追加。

- Debug Simulatorビルド、関連24テスト成功。キューの各モード・04:00/DST・上限・停止/当日非表示・兄弟、デッキ/タグ、保存失敗/rollback、Undo、ordering、操作内共有の破棄を確認。
- 専用Bundle ID `dev.shoug.AnkiIOS.Issue153StartAudit`、App Group権限なしの一時コピーでDebug実機ビルド成功。既存性能2件＋データ保全5件、計7件成功。全評価のFSRS結果・履歴、Undo/rollback、上限、日境界、操作内共有を確認。本番Bundle IDのインストール/削除/学習データ更新はしていない。

iPhone 15 Pro / iOS 27.0.1 / Xcode 27.0 / Debug -Onone。永続B相当fixtureは3内部巡の中央値（n=3）。API測定中の温度は連続採取していないため観測値とし、10/12・10/13既存計測からの改善率は算出しない。

| 既存API測定 | 変更前 | 変更後 |
| --- | ---: | ---: |
| Repository新規開始（永続1,000ノート/3,000カード/10,000過去履歴） | 107.82ms | 93.82ms |
| Store Good＋画面モデル更新（同fixture） | 157.31ms | 109.22ms |
| Store Undo＋画面モデル更新（同fixture） | 108.74ms | 78.75ms |
| Store復習開始（in-memory、3,000 basicノート/カード、n=1） | 145.31ms | 115.92ms |

最後の行は問題のfixture A新規開始でもSwiftUI描画でもない。Good/Undoは開始最適化に伴う共有Note取得/キュー整列削減の観測で、保存・Undoアルゴリズムの変更ではない。

参考: 同じSimulator/iOS 26.5 Debugで、Repository新規開始の中央値116.90→101.71ms（各n=3）、in-memory Store復習開始163.50→123.67ms（各n=1）。実機との差を改善率へ換算しない。

### UI停止・残る確認

PR #170の隔離fixtureと起動方式を再利用し、Computer Useは使わずCLI/XCTest/xctraceのみ実施。計測用一時コピーの既存UI測定を開始→Good→Undoに絞り、fixture生成後のプロセス再起動、同ストアのファイルキャッシュ温間で実行した。これは前回のライブラリ/検索を経由した一連のUI操作と測定範囲が違うため、既存A321〜355ms/B252〜279msと直接比較しない。

変更前Aの1採取は温度Nominal。Store.start signpost216.47ms、内包するqueueCards100.70ms。開始時potential hang490.71msを検出し、Main Threadにnotes/cards、freshCards、ReviewView.bodyのサンプルがある。Store同期更新後にも停止が続いており、DB/キューのみが全停止時間を説明するわけではない。CPU inclusive値を合算しない。

変更前A/Bの開始→Good→Undo UI操作は成功。XCTestのボタン操作から表示要素確認までの壁時計はA2,084.68ms/B1,805.40msだが、IPC/idle待機を含むためユーザーの応答時間として扱わない。BのInstrumentsはPID接続に失敗（1回再試行も失敗）。XCTestの実機実行とInstrumentsのオンライン状態は別に確認し、Instrumentsは端末をOffline表示していた。ユーザーの接続/ロック解除確認後も、変更後UI実行でXcodeが端末ロック待ちになったため追加試行を中止した。変更後のUI描画/Hangs/温度・体感は未確認で、250ms以上停止の解消を主張しない。

FSRS計算、UUID、ReviewLog、SwiftDataスキーマ/移行、バックアップ形式、保存/rollback、日境界、兄弟・学習上限は変更しない。通知/Widgetへの全カード状態は維持するが、実OSの通知配信/Widget App Groupは未確認。

残る候補は全Note/Cardの同期fetch/値型投影と、Store更新後のSwiftUI初期表示。次は端末接続が安定した状態で同じ範囲のbefore/afterを採り、追加signpost（Repository.start、queueNotes、Queue.build/counts/freshCards）と既存Store.start/refreshStudyをHangs/CPUに照合する。別Contextでの開始材料取得はrevision・保存成功/rollback・取消・古い結果破棄を設計してから判断する。このPRではその複雑性を追加しない。

生ログ/xcresult/traceは `/private/tmp/issue153-start-device/`、Simulatorログは `/private/tmp/issue153-start-baseline.log`・`issue153-start-after.log`（不採用の部分fetch）・`issue153-start-final.log`。他プロセス情報を含み得るtraceはGitHubへ公開しない。main自動マージ・Issue Closeは行わない。
