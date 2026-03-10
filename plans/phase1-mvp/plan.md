---
goal: "Phase 1 - コア機能 MVP: Flutter SSH ターミナル + 日本語IME + 接続管理"
verifyCommands:
  - flutter analyze
  - flutter test
  - dart run build_runner build --delete-conflicting-outputs
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 1: コア機能（MVP）

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。

## 目標

SSH接続して日本語を正しく入力できるターミナルアプリの基盤を構築する。

---

## Step 1: プロジェクトセットアップ

1. Flutter プロジェクトを初期化する
   ```bash
   cd /home/takayuki_kawazoe/work/tools/terminal-ssh-app
   flutter create --org com.example --project-name terminal_ssh_app .
   ```
2. 依存パッケージを追加する
   ```bash
   flutter pub add dartssh2 xterm flutter_riverpod drift flutter_secure_storage path_provider connectivity_plus freezed_annotation json_annotation equatable
   flutter pub add --dev drift_dev build_runner flutter_test integration_test mocktail freezed json_serializable
   ```
3. Android の `android/app/build.gradle` で `minSdkVersion 23`, `targetSdkVersion 34` を設定する
4. iOS の `ios/Podfile` で `platform :ios, '13.0'` を設定する
5. `lib/` 配下にアーキテクチャのディレクトリ構成を作成する:
   - `lib/core/ssh/`
   - `lib/core/error/`
   - `lib/core/network/`
   - `lib/core/storage/`
   - `lib/core/theme/`
   - `lib/features/connections/`
   - `lib/features/terminal/`
   - `lib/features/terminal/ime/`
   - `lib/features/file_browser/`
   - `lib/features/tmux/`
   - `lib/widgets/`
6. `flutter analyze` が通ることを確認する

### Codex レビュー

このステップ完了後、以下のコマンドで Codex にレビューを依頼する:
```bash
codex exec --full-auto "プロジェクトの初期セットアップをレビューしてください。(1) pubspec.yamlの依存関係に過不足はないか、(2) ディレクトリ構成がplans/terminal-ssh-app/implementation-plan.mdと整合しているか、(3) Android/iOSのビルド設定は正しいか。問題があれば修正してください。変更対象: pubspec.yaml, android/app/build.gradle, ios/Podfile のみ。"
```

---

## Step 2: SSH 接続基盤の実装

1. `lib/core/ssh/connection_config.dart` を作成する
   - `ConnectionConfig` モデル: host, port, username, authMethod(password/key), label
   - `freezed` で immutable にする（`build_runner` で生成コード作成: `dart run build_runner build`）
2. `lib/core/ssh/ssh_client_service.dart` を作成する
   - dartssh2 の `SSHClient` をラップする
   - `connect(ConnectionConfig)` → `SSHClient` を返す
     - パスワード認証: `SSHClient(..., onPasswordRequest: ...)`
     - 鍵認証: `SSHClient(..., identities: [...])`
     - ホスト鍵検証: `onVerifyHostKey` コールバックで `known_hosts_store` と照合
     - 接続タイムアウト: 15秒（`socket.timeout`）
   - `disconnect()` でクリーンアップ
   - keepalive を30秒間隔で設定する
   - 例外を `AppError` サブクラスに変換する（`SocketException` → `NetworkError`, 認証失敗 → `AuthenticationError` 等）
3. `lib/core/ssh/ssh_channel_manager.dart` を作成する
   - 同一SSH接続から用途別チャネルを管理:
     - `openPtyChannel()` → 対話ターミナル用 (PTY)
     - `executeCommand(String cmd)` → 非対話コマンド用 (exec)
     - `openSftpChannel()` → ファイルブラウザ用 (SFTP subsystem)（Phase 2で使用するが、APIはこのPhaseで定義）
4. `lib/core/ssh/ssh_key_manager.dart` を作成する
   - Ed25519 鍵の生成
   - 秘密鍵の `flutter_secure_storage` への保存/読み出し
   - PEM ファイルからのインポート
5. `lib/core/ssh/known_hosts_store.dart` を作成する
   - ホスト鍵の SHA-256 フィンガープリント計算
   - `flutter_secure_storage` への保存
   - 接続時の検証（不一致時は MITM 警告）
6. `lib/core/error/app_error.dart` を作成する
   - `sealed class AppError` と各サブクラス: `AuthenticationError`, `HostKeyError`, `NetworkError`, `PermissionError`
   - `TmuxError` は Phase 2 で追加する（このPhaseではtmux機能は未実装）
7. 単体テストを `test/core/ssh/` に作成する
   - `ssh_client_service_test.dart`: モック接続テスト
   - `ssh_channel_manager_test.dart`: チャネル分離テスト
   - `known_hosts_store_test.dart`: フィンガープリント計算テスト

### Codex レビュー

```bash
codex exec --full-auto "lib/core/ssh/ と lib/core/error/ のSSH接続基盤コードをレビューしてください。(1) dartssh2 APIの使い方が正しいか、(2) チャネル分離（PTY/exec/SFTP）が正しく実装されているか、(3) エラーハンドリング（例外→AppError変換）が適切か、(4) セキュリティ上の問題はないか。問題があれば修正してください。変更対象: lib/core/ssh/**, lib/core/error/**, test/core/ssh/** のみ。テスト: flutter test test/core/ssh/"
```

---

## Step 3: ターミナル画面の基本実装

1. `lib/features/terminal/terminal_screen.dart` を作成する
   - `xterm.dart` の `TerminalView` を配置する
   - 全画面表示、ステータスバーにホスト名を表示
2. `lib/features/terminal/terminal_connection_provider.dart` を作成する（Riverpod）
   - SSH接続ライフサイクル管理: 接続中 / 接続済み / 切断 / 再接続中
   - バックグラウンド復帰時の生存確認
   - keepalive 管理
3. `lib/features/terminal/terminal_input_provider.dart` を作成する
   - `writeToSsh(String text)` → PTYチャネルに書き込み
   - 入力経路の分離: IME入力 / 物理キー入力 / ペースト
4. `lib/features/terminal/terminal_output_provider.dart` を作成する
   - PTYチャネルからの出力を `Terminal` に書き込み
   - スクロールバック上限の設定（デフォルト: 10000行）
5. `lib/widgets/quick_action_bar.dart` を作成する
   - Ctrl, Tab, Esc, 上下左右矢印, `/` のショートカットボタン
   - ターミナル画面の下部に固定表示
6. `lib/core/network/connectivity_monitor.dart` を作成する
   - `connectivity_plus` でネットワーク状態を監視
   - 切断時に「再接続中...」バナー表示、復帰時に自動再接続
7. ターミナル画面でSSHサーバーに接続し、コマンド入力・出力が動作することを確認する

### Codex レビュー

```bash
codex exec --full-auto "lib/features/terminal/ のターミナル実装をレビューしてください。(1) xterm.dartのTerminalViewの使い方（SSHストリーム↔xtermバッファの接続、改行/エンコーディング処理）、(2) Provider分離（connection/input/output）の責務が適切か、(3) ライフサイクル管理（バックグラウンド復帰、再接続）にリークや問題はないか、(4) dispose時にチャネル・ストリーム・タイマーが全て解放されるか。問題があれば修正してください。変更対象: lib/features/terminal/**, lib/widgets/**, lib/core/network/** のみ。テスト: flutter test"
```

---

## Step 4: 日本語 IME 対応

1. `lib/features/terminal/ime/composition_buffer.dart` を作成する
   - composing テキストの保持
   - 前回確定テキストの保持（差分送信用）
   - `extractDelta(previous, current)` で差分計算
2. `lib/features/terminal/ime/ime_input_handler.dart` を作成する
   - `TextEditingValue` の `composing` レンジ検出
   - composing 中: SSHに送信しない、オーバーレイ表示のみ
   - composing 消失時の判定:
     - テキストが空 or 前回と同じ → キャンセル（送信しない）
     - テキストが変化 → 確定（差分のみ送信）
   - ペースト時: IMEを経由せず `_sanitizeForTerminal()` 後に直接送信
   - Enter キー: composing 中は改行を送信しない
3. `TerminalView` にカスタム IME オーバーレイを追加する
   - 未確定文字はターミナルバッファに**書き込まない**（表示層のみ）
   - `Overlay` ウィジェットでカーソル位置に表示
   - 確定時にオーバーレイを除去
4. xterm.dart 標準の IME 処理で不足する場合、カスタム `TextInputClient` を実装する準備をする
5. 単体テストを `test/features/terminal/ime/` に作成する:
   - `composition_buffer_test.dart`: 差分計算、キャンセル検出
   - `ime_input_handler_test.dart`: 各入力パターン（変換確定、キャンセル、連続入力、ペースト、Enter）

### Codex レビュー

```bash
codex exec --full-auto "lib/features/terminal/ime/ の日本語IME処理コードをレビューしてください。(1) composing状態の検出が正しいか、(2) 差分送信で重複が起きないか、(3) キャンセル時の誤送信が防止されているか、(4) ペースト経路が正しいか、(5) 表示層とバッファの分離が守られているか。問題があれば修正してください。変更対象: lib/features/terminal/ime/**, test/features/terminal/ime/** のみ。テスト: flutter test test/features/terminal/ime/"
```

---

## Step 5: 接続管理 UI

1. `lib/core/storage/database.dart` を作成する
   - drift でテーブル定義: `connections` (id, label, host, port, username, authMethod, createdAt)
   - `dart run build_runner build --delete-conflicting-outputs` で生成コードを作成
   - マイグレーション方針: `schemaVersion` を使い、バージョンごとに `onUpgrade` で ALTER 実行
2. `lib/core/storage/secure_storage.dart` を作成する
   - `flutter_secure_storage` のラッパー
3. `lib/core/storage/connection_repository.dart` を作成する
   - CRUD 操作 (add, update, delete, getAll, getById)
4. `lib/features/connections/connection_provider.dart` を作成する（Riverpod）
   - 接続一覧の状態管理
5. `lib/features/connections/connection_list_screen.dart` を作成する
   - 接続一覧の `ListView`
   - タップで接続 → ターミナル画面に遷移
   - ロングプレスでコンテキストメニュー（編集/削除）
   - FAB で新規追加
6. `lib/features/connections/connection_edit_screen.dart` を作成する
   - ホスト / ポート / ユーザー名 / 認証方式のフォーム
   - パスワード or SSH鍵の選択
   - ホスト鍵フィンガープリント表示・承認 UI
7. `lib/app.dart` にルーティングを設定する
   - `/` → 接続一覧
   - `/terminal/:connectionId` → ターミナル画面
   - `/connection/edit/:id?` → 接続編集
8. `lib/core/theme/terminal_theme.dart` にダーク/ライトテーマを定義する

### Codex レビュー

```bash
codex exec --full-auto "lib/features/connections/ と lib/core/storage/ の接続管理コードをレビューしてください。(1) drift DB設計が妥当か（マイグレーション方針含む）、(2) 機密情報（パスワード、秘密鍵）がDBではなくflutter_secure_storageに保存されているか、(3) UIのバリデーションが適切か、(4) ルーティングが正しいか。問題があれば修正してください。変更対象: lib/features/connections/**, lib/core/storage/**, lib/app.dart のみ。テスト: flutter test"
```

---

## Expected Outcome

- `flutter analyze` がエラーなしで通る
- `flutter test` で全テストがパスする
- アプリを起動し、SSH サーバーに接続してターミナル操作ができる
- 日本語IME入力で変換前の文字がSSHに送信されない
- 接続情報を保存・編集・削除できる
- ショートカットバーから Ctrl+C 等の特殊キーを送信できる

## 制約

- この Phase では SFTP ファイルブラウザと tmux セッション管理は実装しない（Phase 2 で対応）
- 外部 API への依存は持たない（SSH 接続のみ）
- 全ての既存テストが通り続けること
