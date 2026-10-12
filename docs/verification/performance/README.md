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

実機SCW-iPhone（iPhone 15 Pro）は未接続。実機のfps、Hangs、ピークRAM、ボトルネック上位3件は未採取で、受け入れ条件は未完了。

2026-10-12、シミュレーター（iPhone 17 Pro / iOS 26.5、Debug）でfixture件数・再生成による既存ID変更なし、Queue cache/評価/Undo/rollback、既存学習/Undo/再起動の計3件が成功。Debug・Releaseビルドも成功。シミュレーターのデータ処理時間やbitmapサイズを実機RAM/fpsの代用にしない。

後続の専用PR：対象カード取得 #157、学習経路 #153、入力保存 #154、統計 #158、通知/Widget #155、画像 #156、インポート #159、ライブラリ #121。これらの既存測定は純粋な処理時間中心で、実機の上位3スタックを確定する証拠ではない。

参考：[Apple: Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)、[OSSignposter](https://developer.apple.com/documentation/os/ossignposter)。
