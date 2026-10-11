# Mac対応と方式決定（Issue #20）

## 決定

Mac Catalystを採用する。最低macOS 14、Mac用UI idiom（device family 6）、Apple Silicon / Intelの両方をビルド対象とする。iOS/iPadOSの最低バージョンは17のまま。Macのbundle IDは`dev.shoug.AnkiMac`、iOSは既存IDを保持する。

ネイティブmacOS SwiftUIも検討したが、既存のUIKit画像処理・PhotosPicker・Vision OCR・通知・App Intentsを再実装せず、SwiftData、FSRS、履歴、バックアップの同じコードを使えるCatalystを選んだ。固定リビジョンのSwift-FSRSを含むCatalystビルドと共通テストで依存関係を確認した。カメラ撮影はMacでは表示せず、写真選択または画像ファイル選択に置き換える。

実装前にContext7でAppleのUIKit / SwiftUIドキュメントを確認した。

- [Mac用UI idiom](https://developer.apple.com/documentation/uikit/choosing-a-user-interface-idiom-for-your-mac-app)
- [SwiftUI commands](https://developer.apple.com/documentation/swiftui/scene/commands(content:))

## 操作とウィンドウ

iPad対応PR #86を土台に、階層デッキのサイドバー、学習・編集の読みやすい最大幅、キーボード操作をMacにも適用する。⌘1〜4で画面移動、⌘Nで追加、編集の⌘Sで保存、Escで閉じる。学習中は⌘Returnで解答、⌘1〜4で評価、⌘Zで直前の評価を取り消す。

「学習」メニューから復習・新規学習・記録へ移動する。⌘ShiftNまたはファイルメニューから同じ学習ウィンドウを開ける。全ウィンドウで一つの保存領域・StudyStore・学習セッションを共有し、画面と学習状態を共有する。独立した並列学習は行わない。別ウィンドウの非アクティブ化だけでは学習を中断せず、最後のアクティブウィンドウが非アクティブになった場合に中断する。重複評価は既存の状態検証で拒否する。

## ファイルと互換性

Mac App Sandboxを有効にし、ユーザーが選んだファイルへの読み書きだけを許可する。ファイル権限の永続ブックマークは保存しない。画像はPNG/JPEG・20 MB以内、一括入力はUTF-8 CSV/TSV/TXT・10 MB以内。ファイル選択と単一ファイルのドロップで読み込み、非ローカルURL、シンボリックリンク、ディレクトリ、上限超過を拒否する。入力済みテキストへのドロップは置き換え確認を経て、既存のプレビュー・確定処理に進む。

iPhoneとMac間の移動は設定画面の`.studybackup`書き出し・検証・復元を使う。自動同期はない。現在のベースはSwiftData V4、バックアップmanifest / payloadのschemaVersionは1。ノート・カード・履歴・FSRS状態・PNG/JPEG画像を同じ論理形式で保存する。appVersionは情報用で、形式のバージョンを検証する。未対応の形式は復元前に拒否し、現在のデータを保持する。生のSwiftDataストアファイルを端末間でコピーしない。

音声添付PR #82（manifest 2）やデッキ交換PR #83は別系列で、このPRには含まれない。manifest 2は現在のreaderでは拒否されるため、これらの統合時に両プラットフォームで互換性を再検証する。

## 検証と残件

- Macの単体・結合テスト170件：169成功、既存の実機専用1件スキップ。
- iPhone 17 Pro / iOS 26.5 Simulatorでも同じ170件：169成功、1件スキップ。
- Mac Release arm64 / x86_64ビルド成功。Mac用UI family 6を生成物で確認。
- macOS 26 / Apple Siliconの分離したテスト保存領域で実際のUIを確認：サイドバー、ノート編集・ボタン保存、⌘1/⌘2、画像マスク、⌘Return、⌘4、⌘Z、中断、⌘ShiftNで2ウィンドウ。
- Mac UI自動テストはコンパイルできたが、署名なし・ad-hoc署名ともXCTest runnerが接続前に停止／ハングした。自動UI成功とは扱わない。⌘S保存はこの手動確認では確証を得られず、未確認とする。

Draftの解除前に、配布用署名・公証、macOS 14 / Intel上の実行、VoiceOverの実音声、暗い外観・ウィンドウサイズの実画面、Finderドロップ、MacとiPhoneで同一バックアップファイルの往復、写真・OCR、通知の実配信を確認する。大きな文字とiPhone SEの検証はユーザー指定で省略する。
