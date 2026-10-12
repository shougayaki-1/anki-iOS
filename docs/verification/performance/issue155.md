# Issue #155 — Widget/通知の重複更新

## 更新責務

ホームの必要な件数・セッション・設定は従来どおり同期読み込みする。非表示統計は従来の遅延読込を維持。Widgetは値型スナップショットからdetached taskで投影し、通知は既存200ms debounceの後に調整する。本変更ではキューの常駐キャッシュやFSRS計算を追加しない（#153の経路改善とは独立）。

| トリガー | Widget | 通知 |
| --- | --- | --- |
| 起動/内容編集/設定/評価/Undo/移動/インポート/復元 | 全入力を比較して必要時だけ投影 | debounce後にOS状態を確認、計画入力が同じなら計画だけ再利用 |
| ホーム再訪/日跨ぎ/foreground | 入力・学習日・時刻有効範囲を確認 | 日付/通知時刻/時刻逆行/タイムゾーン/許可/配信済みで再計画 |
| 手動Widget更新 | 強制投影・書込み | Widget更新のために統計/ライブラリrevisionや通知を再調整しない |

WidgetキーはカードDTO（UUIDをキーにした比較）・当日ログDTO・投影設定・Calendar・ホーム集計と次更新時刻。集計値が同じでも将来のdue変更を見落とさない。実行中の同じ要求は合流し、完了通知を共有する。最新generation以外は書き込まない。書込済み結果はgeneratedAt〜expiresAtの範囲だけ再利用し、失敗時は再試行可能にキーを破棄する。比較キー保持はカード10,000・当日ログ50,000以下、重複UUIDのない入力に限定。超過時は抑止せず投影する。

通知計画のキーは学習済み・非停止カードのdue/hiddenUntil、設定、Calendar、最新の許可、配信済みID。予約済み通知は毎回OSから読み差分調整し、OS側で削除された予約も補う。不要なremove([])を呼ばない。候補除外が変わる通知時刻/日付境界で失効し、時計の逆行も再計画する。保持は10,000カード・1,000配信済みID以内。最新generationと直列add制御は維持する。

## 検証（2026-10-12）

iPhone 17 Pro / iOS26.5 Simulator、Debug。関連テスト18件、追加比較2件成功、Debugビルド成功。通知OFF・拒否・明示許可、実行中OFF、OS予約削除、配信済み、時計逆行、タイムゾーン、Widget合流/全完了通知/将来due変更/手動強制、日境界/DST/失敗/学習DB不変を確認。

3,000カード・10要求の単発比較：

| 経路 | 壁時計時間 | 再実行 |
| --- | ---: | --- |
| Widget強制投影（旧Storeのforce=true方針相当） | 244.53ms | 投影/書込み10回 |
| 同内容Widget再訪 | 11.89ms | 追加投影/書込み0回 |
| 通知Plannerのみ10回 | 86.11ms | 再計画10回 |
| OS状態を読むService再利用10回 | 10.34ms | 再計画/追加予約0回 |

Widget比較は同じ最終コードのforce有無であり旧main独立ビルドの測定ではない。通知centerはfake、カードは60日後due（全候補走査）のfixture。実OS通信/配送は含まれない。Widget待機には5msポーリングを含む。キャッシュの物理RAM上限を計測したものではない。

既存3,000ノート/カードの実装後測定はStore初期化193.57ms・学習開始628.65ms・評価415.59ms・Undo232.98ms（独立in-memory、Widgetなし/通知OFF、#153未取り込み）。これは初回描画や冷間プロセス起動の改善比較ではない。同期DB取得のボトルネックは#153/横断#152で別扱いする。

再現はWidgetSnapshotTests/testThreeThousandCardsDuplicateWidgetProjectionMeasurement、NotificationServiceTests/testThreeThousandCardsPlanningReuseMeasurement、StudyRepositoryTests/testThreeThousandBasicCardsReviewRefreshMeasurement。ログ`WIDGET_DUPLICATES`/`NOTIFICATION_DUPLICATES`。

## 未確認

実機はdevicectl上でunavailable。冷間起動/ホーム再訪/foreground/手動Widgetの実機前後時間、fetch件数・ハング・ピークRAM・実OS再予約回数は未検証。全条件が完了したとは扱わず、Draft PR・Issue自動クローズなし。
