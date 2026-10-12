# Issue #158 — 統計材料と履歴集計の再利用

## 仕様

StatisticsReaderのactor内だけに、永続モデルを含まない履歴DTO・FSRS予測入力・デッキ親IDを保持する。版数がない直接呼び出しはキャッシュを使わない。StudyStoreは変更を反映するrefreshStudyの冒頭で統計版数を進め、保存成功後の表示取得失敗でも古い材料を再利用しない。復元は従来どおりreaderを作り直す。

履歴集計は最大4条件。キーはデータ版数（材料と共有）・Calendar（タイムゾーン等を含む）・学習日開始時刻・学習日・デッキ/タグ条件。未来日時の履歴に時刻が追いついた場合と時計の巻き戻しでは再集計する。タグの順番と重複は正規化する。

想起確率・期限超過件数はキャッシュせず、毎回の正確なnowで更新する。FSRSのCard値型をアダプター内部に封じた読み取り専用PredictionStateでJSONの再decodeを避ける。FSRS計算式・評価・履歴定義は変更しない。

保持予算は推定コスト合計16MiB。履歴DTO256B＋タグID、予測入力512B＋元payloadサイズ＋タグID、デッキ64B、集計1条件64KiBとして保守的に計上する。これは実RAMの厳密な上限ではない。予算超過時は保持せず、履歴はLRUで4条件以内に収める。材料取得から60秒で解放し、background移行時にも解放する。最新generationのみ画面反映する既存制御は維持。

## 検証（2026-10-12）

iPhone 17 Pro / iOS 26.5 Simulator、Debug、独立in-memoryストア。1,000穴埋めノート・3,000カード・10,000履歴、3回。coldは同じ最終実装の版数変更後の読込で、旧mainの独立測定ではない。時間は壁時計ms、実機fps/CPU使用率ではない。

| 操作 | 最小〜最大 | 材料fetch API | FSRS snapshot/内部Card decode | 履歴再集計 |
| --- | ---: | ---: | ---: | ---: |
| cold | 405.37〜419.39 | 5 | 3,000組 | 1 |
| 初めての別条件 | 190.01〜192.74 | 0 | 0 | 1 |
| 同条件へ60秒後の時刻で再訪 | 10.50〜10.95 | 0 | 0 | 0 |

材料fetch数はコードのNote/Card/Deck/ReviewLog/ExtraPreferences呼び出し数で、SQLite内部fault件数の実測ではない。最終fixtureの推定保持コスト5,034,136B。再訪でも現在時刻のカード予測は更新する。

Debugビルド成功、関連18テスト成功（最終関連17件＋未来履歴等の追加1件）。FSRS準備値と従来snapshot予測の一致、全期間bucketの日時・枚数・回答・評価・時間、保持率、期限超過、連続日数、帰属不明履歴、親デッキ/タグ、Undo、時刻/日境界/タイムゾーン、版数、保存後表示失敗、4条件上限、保持不可、期限切れ、取消を確認。全テストは実行していない。

再現: ScaleRepositoryTests/testStatisticsMaterialCacheThreeThousandCardsTenThousandLogs。ログ`STATISTICS_CACHE`を参照。履歴定義はStatisticsTests、予測一致はReviewSchedulerTests、無効化等はStudyRepositoryTestsのStatistics名テスト。

## 残件

実機がunavailableのため、記録タブ目視・実機の前後CPU/ピーク/終了後RAM・画面ハングは未検証。DTOの推定コストを実機RAM測定として扱わない。Draft PRとしてIssueを自動クローズしない。

## 実機再確認（2026-10-12）

B（未完了・Open）。3,000カード/10,000履歴のAPI各9標本：初回中央値380.13ms、別スコープ131.01ms、同条件再訪13.89ms。revisionごと材料1 read/3,000 decode、再訪で再取得なし。評価/Undo/失敗後・学習日境界・時計逆行/取消の既存無効化回帰が成功。記録タブのUI表示3巡成功だが、評価後/04:00境界の条件を揃えたCPU/RAM/時間と表示目視は未確認。

環境はiPhone 15 Pro / iOS 27.0.1 / Xcode 27 / Debug、専用Bundle ID・隔離ストア。実機データ・全標本・未確認条件・再現方法は[共通実機レポート](README.md)と[CSV](device-20261012.csv)を参照。先行Simulatorの値との改善率は算出しない。
