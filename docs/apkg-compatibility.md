# Anki .apkg 対応表（Issue #14・第一段階）

実装前の調査（2026-10-11）。[Anki公式マニュアル](https://docs.ankiweb.net/exporting.html)、[公式package version実装](https://github.com/ankitects/anki/blob/main/rslib/src/import_export/package/meta.rs)、[公式schema11](https://github.com/ankitects/anki/blob/main/rslib/src/storage/schema11.sql)に基づく。Context7でAnki ManualとSQLiteの最新版ドキュメントを取得した。

| 項目 | 第一段階の対応 | 条件・未対応時の案内 |
|---|---|---|
| collection.anki2 / collection.anki21 | 対応 | Legacy1/2、SQLite schema11、メディアはJSONの番号→ファイル名 |
| collection.anki21b・最新package version3 | 未対応 | Zstandard/Protobuf/schema18。Ankiの「古いAnkiバージョンをサポート」を有効にして再書出 |
| ZIP | store/DEFLATE予定 | 暗号化/ZIP64/分割/自己展開/曖昧なパス・重複は拒否。データディスクリプタ・extra fieldは第一段階で未対応 |
| 基本・基本逆方向 | 対応 | 2フィールド、標準のフィールド差替テンプレート、カードordinal一致 |
| 穴埋め | 対応 | Text/Extra相当の2フィールド、標準clozeテンプレート、生成カード一致 |
| 任意カスタムモデル/テンプレート | 未対応 | ノート単位に理由を表示。HTML/JSテンプレートを実行しない |
| 文字装飾 | プレーンテキスト化 | 改行・基本的HTML entityを保持。スタイル・レイアウトは移行しない |
| 画像 | 問題面の1枚 | JPEG/PNG、20MB・4千万画素、参照整合性。解答画像・複数画像・画像付き逆方向は未対応 |
| 音声 | 各面1本 | soundタグ、#69のWAV/M4A/MP3/AAC/CAF制約。音声をローカル保存 |
| SVG/GIF/WebP/動画/LaTeX/画像遮蔽/生成TTS | 未対応 | ノート単位に詳細表示。変換済み画像/音声または基本カードで再書出 |
| スケジュール/FSRS/ReviewLog | 未対応 | 新規学習開始のみ。履歴を取り込めない旨を明示し、互換であるかのように表示しない |
| デッキ階層/タグ | 対応 | `::`の階層を新規取込ルート配下に保持。複数デッキに分かれた同じノートのカードは未対応 |

対応ノートだけをプレビューし、未対応ノートの件数・理由と元カード数との差を表示してから明示確定する。重複は.studydeckと同じ判定で既定スキップ。形式・ZIP・SQLiteが破損している場合はパッケージ全体を拒否して既存データを変更しない。キャンセルで保存しない。共有デッキ交換の原子的追加を再利用する。

SQLiteは自分で作った一時ディレクトリにDBだけを書き、read-only/immutableで開く。trusted_schema OFF、query_only、cell_size_check、mmap無効、実行時間/VMステップ・入力長制限、quick_check、テーブル限定の固定SQLを使う。ビュー・トリガ・仮想テーブルは拒否し、拡張機能・外部SQL・HTML/JSを実行しない。[SQLiteの推奨対策](https://www.sqlite.org/security.html)を参照。


## 実装と検証記録

ZIPは既存StoredZIPの厳密な中央/ローカル記録・パス・CRC検証を再利用し、Anki読取時だけraw DEFLATEを有効にする。展開後50MB/エントリー・200MB合計・1万ファイル、圧縮率は200倍（1MB以下の展開は許容）まで。studybackup/studydeckは従来通り無圧縮のみ。メディアJSONの一意なファイル名と番号・実ファイルの存在も検証する。

SQLiteの入力は50MB以下、各値は5MB以下、固定クエリのみ。実行中は1000 VM命令ごとに20秒・1千万VM命令・キャンセルを確認する。テーブルはcol/notes/cards/revlogだけ。ビュー・トリガ・仮想テーブルを拒否し、拡張モジュールは登録しない。count最適化時のrevlogへの列名/DB名のない読取だけを特別許可する。読み取り用一時DBは処理終了で削除する。

画像は問題面のJPEG/PNG1枚、画像ポリシーで検証・正規化し、音声は各面1本を元バイトで保存する。画像のみで本文が空なら一般的な問題文を補う。音声のみで本文がないノートは未対応とする。Cloze Extraは解説に移し、穴埋め番号と元card ordinalが一致する場合だけ生成する。基本逆方向は元のordinalが0/1の場合だけ生成する。同じノートのカードが複数デッキへ分かれている場合は未対応。

プレビューに元ノート/カード、対応する生成数、学習済みカードと回答履歴の除外、未対応ノートの理由（100件ずつ）を表示する。対応なしの場合は確定できない。重複・名前衝突・原子的追加・バックアップは#16と共通。外部ファイルはデータとしてだけ扱い、サーバ・HTML描画・スクリプト・外部テンプレートは使わない。

テストは合成のLegacy1/2 SQLiteパッケージ（標準基本・逆方向・穴埋め・PNG・問題/解答WAV・カスタム/スクリプト）と、独立したPython sqlite3/zipfile生成のDEFLATEパッケージを使用する。手持ちデッキの個別テンプレート互換性は保証せず、未対応理由を確認する。ZIP/SQLite破損、パストラバーサル、欠損・余計なファイル、未知形式、unsafe schema、保存失敗、重複、完全バックアップへの回帰を検証する。

最終検証: iPhone 17 Pro / iOS 26.5 simulator、全178 unit/integration中177成功・既存実機専用1件スキップ。Filesの.apkg選択、履歴除外と未対応理由の確認、プレビュー取消、対応3ノートの確定、再起動後の新規学習・評価・UndoのUI1件が成功。大きい文字とiPhone SEは依頼に従い省略。実際の手持ち.apkgは提供されていないため、個別テンプレートはプレビューで対応可否を確認する。
