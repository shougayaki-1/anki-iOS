# 公式Webサイトの独立と移行

2026-10-22 JST、公式WebサイトをiOSリポジトリから独立した `shougayaki-1/anki-note-web` へ移行した。

- 公式LP：https://anki.shoug.org/
- サポート：https://anki.shoug.org/support
- プライバシー：https://anki.shoug.org/privacy
- 旧ポリシーURL `/privacy.html` は `/privacy` へ301転送。
- App Store登録済みの旧サポートURL `/` からはヘッダー/フッターでサポートへアクセスできる。App Store設定・アプリ内URLを変更する必要はない。
- 新Cloudflare Pages：`anki-note-web`、GitHub Production branch=`main`、preview=all、ビルド不要のルート静的配信。

## 管理先

LP、画像、サポート、ポリシー、SEO、移行・ロールバック手順はWeb専用リポジトリで管理する。iOS側へWebファイルを再コピーしない。

実装・移行PR：https://github.com/shougayaki-1/anki-note-web/pull/1

## 旧ファイルの整理方針

調査したmain `ca96fca9948fd74d9ddfc06a51c332484517cea6` には `docs/app-site/` は追跡されていない。公開用の3ファイル（index.html、privacy.html、style.css）は旧サイト用ブランチ `codex/app-store-site` の `491b37a4a2c288451f203115465aab484ce3f12d` に残っている。

移行直前のソースと配信内容・旧設定はWebリポジトリの `docs/archive/2026-10-22/` に保存した。旧Pages `anki-note-site` と旧ブランチは切り戻し用に保持する。このPRでは旧ブランチ・旧Pages・ファイルの削除を行わない。保持期間終了後に旧Pagesの自動配信停止やブランチ整理を行う場合は、切り戻しの要否と保存済みアーカイブを確認する。

開発者のローカル作業ツリーにある未追跡の `docs/app-site/`、公開申請資料、アプリの未コミット変更は本PRの対象外として維持した。削除やコミットへの混入はしていない。

この変更はWebサイトの管理先を文書化するだけで、Swiftコード・学習データ・FSRS・保存処理・App Store設定・アプリ内URLは変更しない。iOSビルド/テストは実施不要。
