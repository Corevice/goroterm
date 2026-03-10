---
goal: "Phase 2 - 機能拡張: SFTP ファイルブラウザ + tmux セッション管理"
verifyCommands:
  - flutter analyze
  - flutter test
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 2: ファイルブラウザ & tmux セッション管理

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。

## 前提条件

Phase 1（コア機能 MVP）が完了していること:
- SSH 接続・ターミナル・日本語 IME・接続管理 UI が動作する
- `flutter analyze` と `flutter test` がパスする
- `ssh_channel_manager.dart` が `openPtyChannel()` / `executeCommand()` / `openSftpChannel()` の API を公開済み
- ターミナル画面のドロワー・スワイプジェスチャーが既存操作と競合しないことを確認済み

---

## Step 1: SFTP ファイルブラウザ - 基盤

1. `lib/features/file_browser/file_browser_provider.dart` を作成する（Riverpod AsyncNotifier）
   - `SftpClient` を `ssh_channel_manager.dart` の `openSftpChannel()` から取得する
   - `listDirectory(String path)` を実装:
     - `sftp.listdir(path)` で一覧取得
     - `.` と `..` を除外
     - ディレクトリ優先でソート（取得完了後にソート）
   - 現在のパスを状態として保持する
   - ロード中はキャンセル可能にする:
     - `CancelableOperation.fromFuture(sftp.listdir(path))` でラップ
     - ディレクトリ移動時に前のロードを `cancel()` する
     - キャンセルされた場合は state を更新しない
   - **UI側** (`file_browser_screen.dart`): `ListView.builder` で仮想スクロール（大規模ディレクトリ対策）
2. `lib/features/file_browser/file_item_widget.dart` を作成する
   - ファイルタイプ別アイコン（フォルダ、テキスト、画像、バイナリ等）
   - ファイル名、サイズ（human readable）、権限、更新日時を表示
   - ディレクトリタップで移動、ファイルタップでプレビュー
   - ロングプレスでコンテキストメニュー
3. 隠しファイル（.dotfiles）の表示/非表示トグルを実装する
4. 単体テストを `test/features/file_browser/` に作成する:
   - `file_browser_provider_test.dart`: ソート順、フィルタ、キャンセル

### Codex レビュー

```bash
codex exec --full-auto "lib/features/file_browser/ のSFTPファイルブラウザ基盤コードをレビューしてください。(1) dartssh2のSFTP APIの使い方が正しいか、(2) 大規模ディレクトリでのパフォーマンス対策（CancelableOperation、ListView.builder）が実装されているか、(3) エラーハンドリング（権限エラー、接続切断→AppError変換）が適切か。問題があれば修正してください。変更対象: lib/features/file_browser/**, test/features/file_browser/** のみ。テスト: flutter test test/features/file_browser/"
```

---

## Step 2: SFTP ファイルブラウザ - パスコピー & ターミナル連携

1. `lib/features/file_browser/path_bar_widget.dart` を作成する
   - パンくずリスト形式で現在のパスを表示
   - 各セグメントをタップでそのディレクトリに移動
   - パス全体をタップでクリップボードにコピー（`Clipboard.setData`）
   - コピー成功時にスナックバー表示
2. ファイルアイテムのコンテキストメニューに以下を追加する:
   - 「パスをコピー」: ファイルの絶対パスをクリップボードにコピー
   - 「ターミナルに貼り付け」: パスをシェルエスケープして PTY チャネルに送信
     - `_shellEscapePath()`: シングルクォートで囲み、パス内の `'` を `'\''` にエスケープ
   - 「プレビュー」: テキストファイルを表示（Step 3）
3. クリップボード自動クリアを実装する（デフォルト30秒、設定で変更可能）
4. ウィジェットテストを作成する:
   - `path_bar_widget_test.dart`: パンくずリスト表示、タップ動作
   - シェルエスケープの単体テスト: 空白、クォート、`$`、`;`、`|` 等を含むパス

### Codex レビュー

```bash
codex exec --full-auto "ファイルブラウザのパスコピー・ターミナル連携をレビューしてください。(1) シェルエスケープが安全か（空白、クォート、$、;、|、バックティック等のメタ文字）、(2) クリップボード自動クリアの実装、(3) UIのユーザビリティ。問題があれば修正してください。変更対象: lib/features/file_browser/**, test/features/file_browser/** のみ。テスト: flutter test test/features/file_browser/"
```

---

## Step 3: SFTP ファイルブラウザ - プレビュー & ダウンロード

1. `lib/features/file_browser/file_preview_screen.dart` を作成する
   - テキストファイルのみプレビュー対象（拡張子 or MIME で判定、上限 1MB）
   - `sftp.open()` → `read()` でファイル内容取得
   - シンタックスハイライト対応: `flutter_highlight` パッケージを使用（`flutter pub add flutter_highlight`）
   - 行番号表示
   - 内容をクリップボードにコピー可能
2. ファイルダウンロード機能を実装する
   - `SftpFileWriter` で進捗表示付きダウンロード
   - ダウンロード先: `path_provider` の `getApplicationDocumentsDirectory()`
   - 進捗バーをリスト上にインラインで表示
   - ダウンロード完了後に共有シート（`share_plus`）を表示するオプション
3. ファイルブラウザ画面をターミナル画面のドロワー（右スワイプ）として統合する

### Codex レビュー

```bash
codex exec --full-auto "ファイルプレビューとダウンロード機能をレビューしてください。(1) 大きいファイルの読み込み制限（1MB上限）が機能するか、(2) ダウンロードの進捗表示とキャンセル、(3) ドロワーのUI統合が自然か。問題があれば修正してください。変更対象: lib/features/file_browser/**, test/features/file_browser/** のみ。テスト: flutter test test/features/file_browser/"
```

---

## Step 4: tmux セッション管理 - 基盤

1. `lib/core/error/app_error.dart` に `TmuxError` サブクラスを追加する（tmux未インストール、セッション不在等）
2. `lib/features/tmux/tmux_session_model.dart` を作成する
   - `TmuxSession`: name, windowCount, isAttached, createdAt
   - `TmuxAvailability`: available(version) / notInstalled
2. `lib/features/tmux/tmux_provider.dart` を作成する（Riverpod AsyncNotifier）
   - `checkTmuxAvailability()`: `command -v tmux` の終了コードで判定
   - `fetchSessions()`:
     - `execute()` (Exec チャネル) で `tmux list-sessions -F` 実行
     - フィールド区切り: ASCII Unit Separator (`\x1F`)
     - フォーマット: `'#{session_name}\x1F#{session_windows}\x1F#{session_attached}\x1F#{session_created}'`
     - 終了コード != 0 → 空リスト
     - パース: `\n` で行分割 → `\x1F` でフィールド分割 → フィールド数 != 4 はスキップ（デバッグログに記録）
   - `createSession(String name)`: `execute()` で `tmux new-session -d -s <name>`
   - `killSession(String name)`: `execute()` で `tmux kill-session -t <name>`
   - `renameSession(String oldName, String newName)`: `execute()` で `tmux rename-session`
   - `attachSession(String name)`: **PTYチャネル** に `tmux attach -t <name>\n` を書き込み
   - 全てのセッション名は `shellEscape()` でエスケープする
3. 単体テストを `test/features/tmux/` に作成する:
   - `tmux_provider_test.dart`: パース正常系・異常系（フィールド不足、空出力）、コマンド構築

### Codex レビュー

```bash
codex exec --full-auto "lib/features/tmux/ のtmuxセッション管理コードをレビューしてください。(1) tmuxコマンドの構築が正しいか（シェルエスケープ）、(2) パース処理のエッジケース（空出力、異常フォーマット、フィールド数不足、tmux未インストール）、(3) PTY/execチャネルの使い分けが正しいか。問題があれば修正してください。変更対象: lib/features/tmux/**, test/features/tmux/** のみ。テスト: flutter test test/features/tmux/"
```

---

## Step 5: tmux セッション管理 - UI

1. `lib/features/tmux/tmux_manager_screen.dart` を作成する
   - セッション一覧: カード形式（名前、ウィンドウ数、接続状態バッジ、作成日時）
   - 接続状態: attached → 緑バッジ、detached → グレーバッジ
   - セッションタップ → `attachSession()` → ターミナル画面に戻る
   - スワイプで削除（確認ダイアログ付き）
   - リネーム: カード内編集アイコン → ダイアログ
2. FAB で新規セッション作成ダイアログを実装する
   - セッション名入力フィールド
   - バリデーション: 空文字不可、既存セッション名と重複不可
3. 自動リフレッシュを実装する
   - `Timer.periodic(Duration(seconds: 10), ...)` で10秒間隔ポーリング
   - 画面の `dispose()` でタイマーを `cancel()` する（リーク防止）
   - アプリがバックグラウンドの間はタイマーを停止する（`WidgetsBindingObserver.didChangeAppLifecycleState`）
   - `RefreshIndicator` でプルダウン手動リフレッシュ
4. tmux 未インストール時の案内画面を実装する
   - 「tmux がインストールされていません」メッセージ
   - インストールコマンド例: `sudo apt install tmux` / `brew install tmux`
5. tmux 管理画面をターミナル画面のドロワー（左スワイプ）として統合する
6. ウィジェットテストを作成する:
   - `tmux_manager_screen_test.dart`: 一覧表示、作成ダイアログ、削除確認

### Codex レビュー

```bash
codex exec --full-auto "tmuxセッション管理UIをレビューしてください。(1) セッション一覧の表示が正しいか、(2) 作成・削除・リネームのバリデーション、(3) 自動リフレッシュのTimer.periodic管理（dispose時のcancel確認）、(4) ドロワー統合のUI/UX。問題があれば修正してください。変更対象: lib/features/tmux/**, test/features/tmux/** のみ。テスト: flutter test test/features/tmux/"
```

---

## Expected Outcome

- `flutter analyze` がエラーなしで通る
- `flutter test` で全テスト（Phase 1 + Phase 2）がパスする
- ターミナル画面から右スワイプでファイルブラウザが開く
- ファイルパスをコピーしてターミナルに安全に貼り付けられる
- テキストファイルのプレビューが表示される
- ターミナル画面から左スワイプで tmux セッション管理が開く
- tmux セッションの一覧表示・作成・接続・削除・リネームができる
- tmux 未インストール環境で案内が表示される

## 制約

- Phase 1 で実装した機能を壊さないこと
- ファイルアップロードは P2（この Phase では実装しない）
- 全ての既存テストが通り続けること
