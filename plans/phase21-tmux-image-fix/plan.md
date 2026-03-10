---
goal: "Phase 21 - tmux セッション作成/リネーム赤画面エラー修正 + 画像貼付を SFTP アップロード方式に変更"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 21: tmux エラー修正 + 画像貼付修正

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題 1: tmux セッションの作成・リネームで赤い画面のエラーが出る

### 根本原因分析

`TmuxManagerScreen` は `_tmuxState`（`AsyncValue<TmuxState>`）を `ref.listenManual` で監視し、`_tmuxState.when(loading:, error:, data:)` でウィジェットを切り替えている。

`createSession()` と `renameSession()` は内部で `_safeRefresh()` を呼び、`_safeRefresh()` は `_fetchSessions()` を実行してセッション一覧を取得する。この `_fetchSessions()` 内で `_runCommand()` が呼ばれ、SSH exec チャネルでコマンドを実行する。

赤い画面（`_ErrorView`）が出るのは、`tmuxProvider` の state が `AsyncError` になった場合。以下のシナリオで発生する:

1. **`_execCommand` が `TmuxError` を throw する**: `createSession()` / `renameSession()` 内で `_execCommand()` が呼ばれ、tmux コマンドの exit code が 0 以外だと `TmuxError` を throw する。`createSession()` / `renameSession()` はこのエラーを `catch (_)` で握り潰しているが、**`_execCommand` の throw 前に state が更新されていない**ため問題ない。
2. **`_safeRefresh()` 自体は安全だが、`_initializeState()` が `AsyncLoading` を設定する**: `setChannelManager()` が再度呼ばれた場合（バックグラウンド復帰等）、`_initializeState()` が `state = const AsyncLoading()` を設定する。この瞬間に `_tmuxState.when()` の `loading:` ブランチに入るが、問題はない。
3. **本当の原因**: `TmuxManagerScreen` の `_subscription` が `tmuxProvider(widget.connectionId)` を listen しているが、Drawer 内の `context` が無効になるタイミングがある。特に:
   - Drawer が開いている状態でタブが切り替わると、`activeSession.sessionId` が変わり、`TmuxManagerScreen` の `connectionId` が変わる
   - しかし `endDrawer` に渡される `TmuxManagerScreen` は新しい `connectionId` で再構築されるが、古い `_subscription` がまだ生きている場合がある
   - あるいは、`_createSession` / `_doRename` が呼ばれた後にダイアログの `Navigator.pop()` が発動し、`TmuxManagerScreen` の `context` が無効になった状態で `ref.read()` が呼ばれる

4. **最も可能性の高い原因**: `_showCreateDialog` / `_showRenameDialog` で `Navigator.of(ctx).pop()` した後に `_createSession(name)` / `_doRename(oldName, newName)` が呼ばれる。これらは `async` メソッドで内部で `ref.read()` を使うが、**ダイアログが閉じた後の `mounted` チェックがない**。`_createSession` は `try/catch` でエラーを SnackBar に表示しているが、`widget.connectionId` が既に無効な状態で `tmuxProvider` にアクセスすると例外が発生する可能性がある。

   さらに、`_SessionListView` の `_doRename` は `widget.onRename(oldName, newName)` を呼び、これは `TmuxManagerScreen` から渡された `ref.read(tmuxProvider(...).notifier).renameSession(...)` である。Drawer が閉じるタイミングで `TmuxManagerScreen` が dispose されると、`ref` が無効になる。

### 修正方針

**A. `TmuxManagerScreen._createSession()` に `mounted` チェックを追加**

**B. `TmuxNotifier` の `createSession` / `renameSession` / `killSession` で state を `AsyncError` にしないことを保証**（既に `_safeRefresh` で対応済みだが、`_execCommand` が throw した場合に `catch` で `_safeRefresh` が呼ばれないケースを確認）

**C. `_showCreateDialog` / `_showRenameDialog` のダイアログ pop 後の処理に `mounted` ガードを追加**

---

## 問題 2: 画像貼付（base64 heredoc 方式）が動作しない

### 根本原因分析

現在の実装:
```dart
terminal.textInput("base64 -d > '$fileName' << 'TERMINAL_SSH_APP_EOF'\r");
// base64 データをチャンク送信
terminal.textInput(base64Data.substring(i, end));
// ...
terminal.textInput('\r');
terminal.textInput('TERMINAL_SSH_APP_EOF\r');
```

問題点:
1. **heredoc はインタラクティブシェルでの動作が不安定**: PTY 上の bash で heredoc を使うと、シェルが各行をプロンプトで待つ。base64 データが巨大（数千行相当）になると、各行ごとにシェルが `> ` プロンプトを出力し、PTY バッファが溢れるか表示が崩壊する。
2. **改行なしで大量データを送信**: base64 データは改行なしで送信されるため、1行が巨大になる。一部のシェルやターミナルは極めて長い行を正しく処理できない。
3. **ファイル名にシングルクォートが含まれると壊れる**: `$fileName` をシングルクォートで囲んでいるが、ファイル名自体にシングルクォートがあるとコマンドが壊れる。
4. **ユーザーのターミナル画面が大量の base64 テキストで埋まる**: UX として悪い。

### 修正方針: SFTP アップロード方式に変更

PTY への base64 入力は根本的に不安定なため、**既存の SFTP アップロード機能を流用する**方式に変更する。

フロー:
1. ユーザーが画像ボタンを押す
2. `file_picker` で画像を選択
3. **SFTP チャネル経由でリモートにアップロード**（既存の `FileBrowserNotifier.uploadFile()` と同等のロジック）
4. アップロード完了を SnackBar で通知
5. ターミナルには何も入力しない（ファイルはリモートのカレントディレクトリまたはホームに保存される）

これにより:
- PTY バッファの問題が完全に回避される
- SFTP は binary safe なのでファイルの中身が壊れない
- 進捗表示も可能
- 画像以外の任意のファイルにも対応可能（将来拡張）

ただし、アップロード先ディレクトリの決定が必要。CWD 取得（Phase 19 の `getShellCwd()`）を使い、取得できなければホームディレクトリにフォールバックする。

---

## 実装手順

### 手順 1: tmux セッション作成/リネームの mounted ガード追加

ファイル: `lib/features/tmux/tmux_manager_screen.dart`

#### 1a. `_TmuxManagerScreenState._createSession()` に mounted チェック追加

変更前:
```dart
Future<void> _createSession(String name) async {
  try {
    await ref
        .read(tmuxProvider(widget.connectionId).notifier)
        .createSession(name);
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to create session: $e')),
      );
    }
  }
}
```

変更後:
```dart
Future<void> _createSession(String name) async {
  if (!mounted) return;
  try {
    await ref
        .read(tmuxProvider(widget.connectionId).notifier)
        .createSession(name);
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to create session: $e')),
      );
    }
  }
}
```

#### 1b. `_showCreateDialog` の「Create」ボタン処理を改善

ダイアログの pop 後に `_createSession` を呼ぶ流れは問題ない（pop はダイアログを閉じるだけで `TmuxManagerScreen` 自体は残る）。ただし念のため、`_createSession` 内の `mounted` チェックで保護済み。

#### 1c. `_SessionListViewState._doRename` に mounted チェック追加

変更前:
```dart
Future<void> _doRename(String oldName, String newName) async {
  try {
    await widget.onRename(oldName, newName);
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to rename session: $e')),
      );
    }
  }
}
```

変更後:
```dart
Future<void> _doRename(String oldName, String newName) async {
  if (!mounted) return;
  try {
    await widget.onRename(oldName, newName);
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to rename session: $e')),
      );
    }
  }
}
```

#### 1d. `_confirmDelete` にも同様の mounted チェック

変更前:
```dart
if (confirmed == true && mounted) {
  try {
    await widget.onDelete(name);
  } catch (e) {
```

これは既に `mounted` チェック済みなので変更不要。

### 手順 2: TmuxNotifier の state 安全性を強化

ファイル: `lib/features/tmux/tmux_provider.dart`

`createSession`, `renameSession`, `killSession` は既に `try/catch` で `_safeRefresh()` を呼んでいるが、`_execCommand` が throw した場合にも state が `AsyncError` にならないことを確認する。

現状のコード:
```dart
Future<void> createSession(String name) async {
  if (_isOperating) return;
  _isOperating = true;
  try {
    final channelManager = _channelManager;
    if (channelManager == null) return;
    final escaped = shellEscape(name);
    await _execCommand(channelManager, 'tmux new-session -d -s $escaped');
    await _safeRefresh();
  } catch (_) {
    // エラーは握り潰す（_safeRefresh で前回データが維持される）
  } finally {
    _isOperating = false;
  }
}
```

`_execCommand` が throw → `catch (_)` で握り潰し → `_safeRefresh` は呼ばれない → state は変わらない → OK。

ただし `_safeRefresh()` 自体が throw する場合も確認:
```dart
Future<void> _safeRefresh() async {
  try {
    // ...
  } catch (_) {
    // refresh 失敗は無視（既存データを維持）
  }
}
```

これも安全。**state が `AsyncError` になる経路はない**。

つまり赤い画面の原因は `TmuxNotifier` 側ではなく、**`TmuxManagerScreen` の widget ツリーで発生する Flutter の例外**（dispose 後の `ref.read()` 等）がキャッチされずに Flutter のエラー画面として表示される可能性。

#### 追加修正: `_initializeState` の `AsyncLoading` を条件付きに

`_initializeState` で `state = const AsyncLoading()` を設定すると、Drawer が開いている状態で一瞬 loading 表示になる。前回データがある場合は `AsyncLoading` にしない（既にコードにはその条件があるが `prev == null` のときのみ loading にする）。

現状のコード（既に条件付き）:
```dart
final prev = state.valueOrNull;
if (prev == null) {
  state = const AsyncLoading();
}
```

これは正しい。変更不要。

### 手順 3: 画像貼付を SFTP アップロード方式に変更

ファイル: `lib/features/terminal/terminal_screen.dart`

`_pasteImage()` を全面的に書き換え。PTY への base64 入力をやめ、SFTP 経由でファイルをアップロードする。

変更前:
```dart
Future<void> _pasteImage() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.image,
  );
  if (result == null || result.files.isEmpty) return;
  final file = result.files.first;
  if (file.path == null) return;

  final localFile = File(file.path!);
  final fileSize = await localFile.length();

  if (fileSize > 5 * 1024 * 1024) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Image too large (max 5MB)')),
      );
    }
    return;
  }

  final bytes = await localFile.readAsBytes();
  final base64Data = base64Encode(bytes);
  final fileName = file.name;

  final terminal =
      ref.read(terminalConnectionProvider(widget.sessionId)).terminal;
  if (terminal == null) return;

  // heredoc でバイナリを base64 デコードしてファイル作成
  terminal.textInput("base64 -d > '$fileName' << 'TERMINAL_SSH_APP_EOF'\r");
  // base64 データを分割送信
  const chunkSize = 4096;
  for (var i = 0; i < base64Data.length; i += chunkSize) {
    final end = (i + chunkSize).clamp(0, base64Data.length);
    terminal.textInput(base64Data.substring(i, end));
    if (end < base64Data.length) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
  terminal.textInput('\r');
  terminal.textInput('TERMINAL_SSH_APP_EOF\r');

  if (mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Pasting image: $fileName')),
    );
  }
}
```

変更後:
```dart
Future<void> _pasteImage() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.image,
  );
  if (result == null || result.files.isEmpty) return;
  final file = result.files.first;
  if (file.path == null) return;

  final localFile = File(file.path!);
  final fileSize = await localFile.length();

  // 10MB 制限（SFTP なら base64 より大きいファイルも扱える）
  if (fileSize > 10 * 1024 * 1024) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File too large (max 10MB)')),
      );
    }
    return;
  }

  final connectionState =
      ref.read(terminalConnectionProvider(widget.sessionId));
  final channelManager = connectionState.channelManager;
  if (channelManager == null) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('SSH not connected')),
      );
    }
    return;
  }

  final fileName = file.name;

  if (mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Uploading: $fileName')),
    );
  }

  try {
    // アップロード先を決定: PTY の CWD → ホームディレクトリ → /tmp
    String uploadDir;
    try {
      final cwd = await channelManager.getShellCwd();
      if (cwd != null && cwd.isNotEmpty) {
        uploadDir = cwd;
      } else {
        // SFTP でホームディレクトリを取得
        final sftp = await channelManager.openSftpChannel();
        uploadDir = await sftp.absolute('.');
      }
    } catch (_) {
      uploadDir = '/tmp';
    }

    final remotePath = '$uploadDir/$fileName';

    // SFTP でアップロード
    final sftp = await channelManager.openSftpChannel();
    final remoteFile = await sftp.open(
      remotePath,
      mode: SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate,
    );
    try {
      final inputStream =
          localFile.openRead().map((chunk) => Uint8List.fromList(chunk));
      await remoteFile.write(inputStream).done;
    } finally {
      await remoteFile.close();
    }

    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Uploaded: $remotePath')),
        );
    }
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
    }
  }
}
```

**注意**: `dart:convert` の import は base64 用だったが、SFTP 方式では不要になる可能性がある。ただし他の箇所で使っていれば残す。import が不要になったら削除する。`dartssh2` の `SftpFileOpenMode` が import されていることを確認（`file_browser_provider.dart` で使っているが `terminal_screen.dart` では新規かもしれない）。

必要な import 追加（`terminal_screen.dart` の先頭に）:
```dart
import 'package:dartssh2/dartssh2.dart';
import 'dart:typed_data';
```

既に `dart:io` と `package:file_picker/file_picker.dart` は import 済み。
`dart:convert` は `base64Encode` が不要になれば削除。他で使っていないか確認して、不要なら削除すること。

### 手順 4: QuickActionBar のボタンラベルを更新

ファイル: `lib/widgets/quick_action_bar.dart`

画像ボタンのアイコンはそのままで問題ないが、ツールチップを追加してユーザーが機能を理解しやすくする。

`_ActionButton` にはツールチップ機能がないが、現状のシンプルな実装で十分（`Icons.image` アイコンで明示的）。変更不要。

### 手順 5: テスト確認・修正

既存テストへの影響:
- `_createSession` の `mounted` チェック追加: テスト影響なし
- `_doRename` の `mounted` チェック追加: テスト影響なし
- `_pasteImage` の SFTP 方式変更: `_pasteImage` のテストはないはず（UI の async 操作のため）
- `dart:convert` import 削除の場合: 他で使われていないことを確認
- `dartssh2` import 追加: analyze で確認

## 実装順序

1. `lib/features/tmux/tmux_manager_screen.dart`:
   - `_createSession()` に `mounted` チェック追加
   - `_doRename()` に `mounted` チェック追加
2. `lib/features/terminal/terminal_screen.dart`:
   - `_pasteImage()` を SFTP アップロード方式に全面書き換え
   - 必要な import 追加（`dartssh2`, `dart:typed_data`）
   - 不要な import 削除（`dart:convert` が他で使われていなければ）
3. テスト確認・修正
4. `~/flutter/bin/flutter analyze`
5. `~/flutter/bin/flutter test`
6. `~/flutter/bin/flutter build apk --debug`
