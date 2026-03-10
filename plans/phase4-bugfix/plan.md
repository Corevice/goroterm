---
goal: "Phase 4 - バグ修正 & SSH鍵認証UI: sqlite3クラッシュ修正・接続フロー修正・鍵認証UI実装"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 4: バグ修正 & SSH鍵認証UI

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

## 背景

Phase 1〜3 で実装したアプリを Android 実機でテストしたところ、以下の問題が発覚した:

1. **起動時クラッシュ**: `Failed to load dynamic library 'libsqlite3.so'` — `sqlite3_flutter_libs` パッケージが未導入のため、Android でネイティブ SQLite ライブラリが見つからない
2. **接続が開始されない**: `TerminalScreen` が `connect()` を呼んでいないため、接続一覧からタップしても永久にスピナーが回り続ける
3. **SSH鍵認証が使えない**: バックエンド（`SshClientService`, `SshKeyManager`, `SecureStorageService`）は鍵認証に対応済みだが、UIに秘密鍵を入力する手段がない

スクリーンショット: `tmp/20260308/Screenshot_20260308-200827.png`

---

## Step 1: sqlite3_flutter_libs の追加（起動クラッシュ修正）

drift の `NativeDatabase` は Android 上でネイティブの `libsqlite3.so` を必要とするが、`sqlite3_flutter_libs` パッケージが `pubspec.yaml` に含まれていない。

1. `pubspec.yaml` の `dependencies` に `sqlite3_flutter_libs: ^0.5.0` を追加する
2. `~/flutter/bin/flutter pub get` を実行する
3. `lib/main.dart` のデータベース初期化部分を確認し、必要に応じて import を追加する（`sqlite3_flutter_libs` は自動的にネイティブライブラリを含めるため、通常はコード変更不要）
4. `android/app/build.gradle` の `minSdk` が `24` であることを確認する（`flutter_secure_storage` の要件。既に Phase 4 開始前に対応済みだが、`23` に戻っていないか確認）
5. `~/flutter/bin/flutter build apk --debug` でビルドが通ることを確認する

### Codex レビュー

```bash
codex exec --full-auto "sqlite3_flutter_libs が pubspec.yaml に正しく追加されているか、Android ビルドが通るか確認してください。~/flutter/bin/flutter pub get && ~/flutter/bin/flutter analyze を実行し、問題があれば修正してください。変更対象: pubspec.yaml, android/app/build.gradle のみ。"
```

---

## Step 2: TerminalScreen の接続フロー修正

`TerminalScreen` に遷移しても `TerminalConnectionNotifier.connect()` が呼ばれないため、接続が開始されない。

1. `lib/features/terminal/terminal_screen.dart` を修正する
   - `initState` 内で `WidgetsBinding.instance.addPostFrameCallback` を使い、初回描画後に接続処理を開始する
   - 接続処理の流れ:
     1. `connectionRepositoryProvider` から `widget.connectionId`（int に変換）で `Connection` を取得
     2. `Connection` から `ConnectionConfig` を構築
     3. `secureStorageProvider` から認証情報をロード:
        - `authMethod == 'password'` の場合: `loadPassword(connectionId)` でパスワード取得
        - `authMethod == 'key'` の場合: `loadPrivateKey(connectionId)` で PEM 取得
     4. パスワード認証の場合、パスワードが未保存ならダイアログで入力を求める
     5. `terminalConnectionProvider(connectionId).notifier` の `connect()` を呼ぶ
2. パスワード入力ダイアログを `lib/features/terminal/password_dialog.dart` に作成する
   - `showDialog` で `TextField`（obscureText: true）を表示
   - 「接続」「キャンセル」ボタン
   - キャンセル時は前画面に戻る
3. 鍵認証のパスフレーズ入力ダイアログも同ファイルに作成する
   - 暗号化された鍵の場合のみ表示（`SshKeyManager.isEncrypted(pem)` で判定）
4. エラー時のハンドリング:
   - 接続失敗時に `SnackBar` でエラーメッセージを表示
   - 認証エラー時は「パスワードが正しくありません」等のメッセージ
5. 既存のテスト `test/features/terminal/` が壊れないことを確認する

### Codex レビュー

```bash
codex exec --full-auto "lib/features/terminal/terminal_screen.dart の接続フロー修正をレビューしてください。(1) postFrameCallback での接続開始が正しく実装されているか、(2) パスワード/鍵の読み込みロジックに漏れはないか、(3) エラーハンドリングが適切か、(4) dispose 時にリソースが正しく解放されるか。問題があれば修正してください。変更対象: lib/features/terminal/**, lib/features/connections/** のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 3: SSH鍵認証 UI の実装（接続編集画面）

`ConnectionEditScreen` で認証方式「SSH Key」を選択した際に、秘密鍵を入力・保存できるようにする。

1. `lib/features/connections/connection_edit_screen.dart` を修正する
   - 認証方式が `key` の場合、以下の UI を表示:
     - **秘密鍵入力フィールド**: 複数行 `TextFormField`（maxLines: 8, monospace フォント）
       - ヒントテキスト: `"-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----"`
       - バリデーション: `BEGIN` と `END` のマーカーが含まれているか
     - **ファイルから読み込みボタン**: 「ファイルから読み込む」ボタン
       - ファイル内容を `TextFormField` に設定する
       - ファイル選択は `file_picker` パッケージを使用（Step 4 で追加）
       - ファイルピッカーが利用できない場合はボタンを非表示にする
     - **パスフレーズフィールド**（任意）: `TextFormField`（obscureText: true）
       - ヒントテキスト: `"パスフレーズ（暗号化鍵の場合）"`
   - プレースホルダーテキスト `"SSH key management will be available in the terminal connection flow."` を削除する
2. `_save()` メソッドを修正する
   - `authMethod == 'key'` の場合、入力された PEM を `secureStorage.savePrivateKey(connectionId, pem)` で保存する
   - パスフレーズがある場合は `secureStorage.savePassphrase(connectionId, passphrase)` で保存する（`SecureStorageService` に `savePassphrase` / `loadPassphrase` メソッドを追加する必要あり）
3. `lib/core/storage/secure_storage.dart` に追加する
   - `savePassphrase(int connectionId, String passphrase)` — キー: `conn_pp_{id}`
   - `loadPassphrase(int connectionId)` → `Future<String?>`
   - `deletePassphrase(int connectionId)`
4. 編集画面で既存の鍵をロードする
   - `_loadConnection()` 内で `secureStorage.loadPrivateKey(connectionId)` を呼び、`TextFormField` に設定する
   - パスフレーズも同様にロードする
5. 接続削除時に関連する秘密鍵・パスフレーズもセキュアストレージから削除する
   - `ConnectionProvider.deleteConnection()` 内で `secureStorage.deletePrivateKey(id)` と `secureStorage.deletePassphrase(id)` を呼ぶ

### Codex レビュー

```bash
codex exec --full-auto "SSH鍵認証UIの実装をレビューしてください。(1) 秘密鍵PEMの入力・保存・読み込みが正しく動作するか、(2) パスフレーズの保存が安全か（flutter_secure_storage使用）、(3) PEMバリデーションが適切か、(4) 接続削除時に鍵データが削除されるか。問題があれば修正してください。変更対象: lib/features/connections/**, lib/core/storage/secure_storage.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 4: file_picker パッケージの追加（任意）

秘密鍵ファイルを端末のファイルシステムから選択できるようにする。PEM テキストの手動貼り付けだけでも機能するため、このステップは任意。

1. `pubspec.yaml` に `file_picker: ^8.0.0` を追加する
2. `~/flutter/bin/flutter pub get` を実行する
3. `connection_edit_screen.dart` の「ファイルから読み込む」ボタンの実装:
   - `FilePicker.platform.pickFiles(type: FileType.any)` でファイルを選択
   - 選択されたファイルの内容を読み取り、PEM フィールドに設定
   - エラーハンドリング: ファイルが読めない場合は `SnackBar` でメッセージ表示
4. Android の権限設定:
   - `android/app/src/main/AndroidManifest.xml` に `READ_EXTERNAL_STORAGE` パーミッションが必要か確認（API 33+ では不要）
5. `~/flutter/bin/flutter analyze` と `~/flutter/bin/flutter test` が通ることを確認する

### Codex レビュー

```bash
codex exec --full-auto "file_picker の統合をレビューしてください。(1) ファイル選択→PEM読み込みのフローが正しいか、(2) Android/iOS の権限設定に問題はないか、(3) ファイルが選択されなかった場合のハンドリングが適切か。問題があれば修正してください。変更対象: pubspec.yaml, lib/features/connections/connection_edit_screen.dart, android/app/src/main/AndroidManifest.xml のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 5: 結合テスト & 動作確認

全ての修正を統合し、アプリが正常に動作することを確認する。

1. `~/flutter/bin/flutter analyze` がエラーなしで通ることを確認する
2. `~/flutter/bin/flutter test` で全テストがパスすることを確認する
3. `~/flutter/bin/flutter build apk --debug` でビルドが成功することを確認する
4. 以下のテストケースを `test/` に追加する:
   - `test/core/storage/secure_storage_test.dart`: パスフレーズの保存・読み込み・削除
   - `test/features/connections/connection_edit_screen_test.dart`: 鍵認証フォームの表示・バリデーション
   - `test/features/terminal/terminal_screen_test.dart`: 接続開始フローのテスト（モック使用）
5. 手動テストシナリオ（APK を Android 実機にインストールして確認）:
   - アプリが起動し、接続一覧画面が表示される（sqlite3 エラーなし）
   - パスワード認証で SSH 接続ができる
   - SSH鍵認証で接続ができる（PEM 貼り付け）
   - 接続情報の保存・編集・削除ができる

### Codex レビュー

```bash
codex exec --full-auto "Phase 4 の全修正を統合レビューしてください。(1) ~/flutter/bin/flutter analyze がクリーンか、(2) ~/flutter/bin/flutter test で全テストがパスするか、(3) 新規テストのカバレッジが十分か。問題があれば修正してください。変更対象: lib/**, test/** のみ。"
```

---

## Expected Outcome

- アプリが Android 実機で起動し、`libsqlite3.so` エラーが発生しない
- 接続一覧からタップして SSH 接続が開始される
- パスワード認証・SSH鍵認証の両方で接続できる
- 秘密鍵の PEM をテキスト貼り付けまたはファイル選択で入力できる
- 暗号化された鍵のパスフレーズを入力できる
- 全ての既存テストが引き続きパスする
- `flutter analyze` がエラーなしで通る

## 制約

- 既存の Phase 1〜3 の機能（SFTP、tmux、テーマ設定等）を壊さないこと
- Flutter SDK は `~/flutter/bin/flutter` をフルパスで使用すること（PATH にない）
- `android/app/build.gradle` の `minSdk` は `24`、`compileSdk` は `36` を維持すること
- セキュリティ: 秘密鍵とパスフレーズは必ず `flutter_secure_storage` に保存し、drift DB には保存しないこと
