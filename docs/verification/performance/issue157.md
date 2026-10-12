# Issue #157: ID指定カード取得

## 変更

`noteItems(cardIDs:)`はカード・参照ノート・タグを400 ID以下のpredicateで取得する。デッキは参照先から祖先を辿り、各IDは一度だけ取得する。全件指定（nil）は従来の一括取得を維持する。スキーマ・保存処理は変更しない。

現行mainの複数ID呼び出しは`FlaggedCardsView`のみ。画面表示と`dataRevision`更新時にフラグ付きカード全体を要求する。実ユーザーのフラグ件数・呼び出し頻度は未計測。検索変更時には再取得しない。

## 検証（2026-10-12）

iPhone 17 Pro / iOS 26.5 Simulator、Debug、独立した一時SQLiteストア。関連LibraryRepositoryTests 43件、追加ScaleRepositoryTests 1件成功。Debugビルド成功。

以下は各条件1回、別ModelContextでの壁時計時間（ms）。旧側は全カード・全ノート取得後のIDフィルターのみ、新側はID取得に加えてNoteItem生成・FSRS decode・デッキ名投影を含む。完全に同じ処理範囲の比較ではなく、OS/SQLiteキャッシュも制御していない。

| 全カード数 | 選択枚数 | 旧取得のみ | 新表示生成込み |
| ---: | ---: | ---: | ---: |
| 3,000 | 10 | 62.47 | 2.58 |
| 3,000 | 100 | 60.38 | 4.59 |
| 3,000 | 1,000 | 60.01 | 40.86 |
| 10,000 | 10 | 215.14 | 1.13 |
| 10,000 | 100 | 214.43 | 4.84 |
| 10,000 | 1,000 | 212.78 | 41.12 |

fixtureは1ノート1カード、タグなし、1デッキ。コード上のカード/ノートfetch呼び出し数は旧2回（全件）、新2/2/6回（選択10/100/1,000枚）。新側はこれに設定1回・デッキ1回が加わる。実際のSQL文数や内部fault問い合わせ数を測定した値ではない。

3,000カードの回帰fixtureでは穴埋め兄弟、階層パス、降順、本文、FSRS期限、存在しないID、空集合、単一ID優先、全ID指定の一致を確認。全件nilの経路は維持する。

再実行は`xcodebuild test`で`-only-testing:AnkiIOSTests/LibraryRepositoryTests`と`-only-testing:AnkiIOSTests/ScaleRepositoryTests/testSelectedCardFetchScaling`を指定する。測定出力は`ID_FETCH`。

実機のピーク/滞留メモリ、SQLite query plan、実機のフラグ一覧スモークは未検証。これらの受け入れ条件が残るためDraft PRとし、Issueを自動クローズしない。
