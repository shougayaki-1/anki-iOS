# #121 ライブラリ行と保持範囲

現行mainの#115実装（e661ebe）では、軽量ID/件数の索引、デッキ指定の本文取得、FSRS復元を伴わない一覧、150msの検索debounceが導入済み。#112（6ff2c23）の階層・安定したdeck/note IDと#116のStore更新責務は維持した。これらを再実装せず、追加の整形・描画・保持範囲を変更した。

- 表示文・形式・兄弟枚数・停止状態をLibraryReader actorで準備する。LibraryCardRowは小さなEquatable値だけを保持し、bodyでCardGenerationの整形やDB fetchをしない。詳細・弱点分析のNoteItemは従来どおり必要時に取得する。
- 検索/リビジョン/絞り込みが同じ場合はツリー投影を再利用する。展開状態の変更時に表示行を1回作り、選択状態などのbody再評価で全表示行を再構築しない。最新の要求だけ結果・エラーを反映する。Listと選択/展開/検索/件数の仕様は維持する。
- 本文と表示用DTOのキャッシュは推定8MiB・32デッキまでのLRU、検索文字列は推定2MiB・4,096件まで。過大な単一要求は表示用の戻り値には含めるがactorに保持しない。予算超過やメモリ警告・非アクティブ化で解放する。メタデータのID/件数索引と、現在の画面が必要とする値は予算とは別。文字列/マスク/辞書費用の推定値でありプロセス全体のRAM上限ではない。

[BrowserRowCollection](https://github.com/ankidroid/Anki-Android/blob/main/AnkiDroid/src/main/java/com/ichi2/anki/browser/BrowserRowCollection.kt)、[BrowserMultiColumnAdapter](https://github.com/ankidroid/Anki-Android/blob/main/AnkiDroid/src/main/java/com/ichi2/anki/browser/BrowserMultiColumnAdapter.kt)、[CardBrowserViewModel](https://github.com/ankidroid/Anki-Android/blob/main/AnkiDroid/src/main/java/com/ichi2/anki/browser/CardBrowserViewModel.kt)、[DeckAdapter](https://github.com/ankidroid/Anki-Android/blob/main/AnkiDroid/src/main/java/com/ichi2/anki/widgets/DeckAdapter.kt)を設計の参考として確認した。IDと描画値の分離・差分の考え方を採用し、可視行のbindからバックエンドを呼ぶ方式は使わない。Androidコードのコピーやライセンス依存の追加はない。

## 検証

iPhone17Pro / iOS26.5 Simulator、Debug、隔離したSQLiteストア。現行mainの行整形と同じ処理を繰り返す経路と、準備済み値の参照を同じ入力で比較した。実際のSwiftUIフレーム測定ではない。

| データ | 3,000行×10回の整形 | 準備済み参照 | 保持推定費用 | デッキ10回再訪時の本文decode |
| --- | ---: | ---: | ---: | ---: |
| 3,000ノート/3,000カード | 13.54ms | 5.16ms | 1,291,560B | 0 |
| 1,000穴埋めノート/3,000カード/10,000履歴 | 486.55ms | 5.53ms | 883,120B | 0 |

メタデータ初回取得は約101〜159ms、1デッキ本文は約5ms、初回検索約86〜134ms、再検索約5〜13ms。20デッキ、履歴を持つ条件も確認。これは単発・シミュレーター計測であり実機の表示反応/ハング/ピークRAMを証明しない。

関連5件の単体/結合テストで、隠れた不正本文・FSRSを読まないこと、移動/削除後の反映、反転/穴埋め検索、上限/退避/過大な戻り値/再訪/解放と元データ保持を確認。既存UI2件で開閉・スクロール・検索・再起動後の展開、選択/解除/一括画面の取消を確認した。初回UI失敗は変更前のViewでも再現する再起動後の画面外行と、既存作成ヘルパーの未展開・画面外ツールバーによるもの。テストを実際の表示状態に合わせて修正した。最終Debugビルド成功。

実機未接続。実機3,000ノート/3,000カードの体感、SQL問い合わせ回数、SwiftUI body評価数、メインスレッド停止、FPS、ピークRAMの前後比較は未完了。DEBUGカウンターは本文fetch呼出し・本文decode・表示値準備を数えるもので、CoreData内部のSQL問い合わせ数ではない。Draft PRでIssueを閉じず自動マージしない。PR #149の検索UI、PR #161のLibraryRepository、PR #166の画像表示との統合確認が必要。
