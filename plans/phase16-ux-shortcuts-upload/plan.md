---
goal: "Phase 16 - ショートカット強化 + ファイルアップロード機能"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 16: ショートカット強化 + ファイルアップロード機能

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

## 概要

3つの機能を追加する：

1. **Ctrl+J をショートカットバーから送信可能にする**
2. **Ctrl+D / Ctrl+C を連続送信しやすい専用ボタンにする**（Ctrl メニューを開かずに直接タップ）
3. **SFTP ファイルアップロード機能**

## 実装手順

### 手順 1: QuickActionBar にショートカットボタンを追加

ファイル: `lib/widgets/quick_action_bar.dart`

現在の QuickActionBar のレイアウト（`Row` 内の `children`）:
```
[Ctrl] [Tab] [Esc] | [↑] [↓] [←] [→] | [/] [-] [|]
```

変更後のレイアウト:
```
[C-c] [C-d] [C-j] [Ctrl] [Tab] [Esc] | [↑] [↓] [←] [→] | [/] [-] [|]
```

#### 変更内容

`build()` メソッドの `Row.children` の先頭（`_ActionButton(label: 'Ctrl', ...)` の前）に以下を追加:

```dart
_ActionButton(
  label: 'C-c',
  onPressed: () => onKeyPressed(TerminalKey.keyC, ctrl: true),
),
_ActionButton(
  label: 'C-d',
  onPressed: () => onKeyPressed(TerminalKey.keyD, ctrl: true),
),
_ActionButton(
  label: 'C-j',
  onPressed: () => onKeyPressed(TerminalKey.keyJ, ctrl: true),
),
const SizedBox(width: 8),
```

また、`_terminalKeyFromChar()` に `'J'` のケースを追加:

```dart
case 'J':
  return TerminalKey.keyJ;
```

さらに、Ctrl メニューのキーリスト `keys` にも `'J'` を追加:

```dart
final keys = ['C', 'D', 'J', 'Z', 'A', 'E', 'L', 'R', 'K', 'U', 'W'];
```

**ポイント**:
- C-c, C-d, C-j は最もよく使うので先頭に配置し、ワンタップで送信可能にする
- Ctrl メニュー内にも残しておく（メニューからもアクセス可能）
- C-c と C-d はプロセス終了やシェル終了に使うため連続タップしやすい位置に

### 手順 2: FileBrowserNotifier にアップロードメソッドを追加

ファイル: `lib/features/file_browser/file_browser_provider.dart`

#### 2a. FileBrowserState にアップロード進捗フィールドを追加

現在の `FileBrowserState` に以下を追加:

```dart
final double? uploadProgress;    // null: アップロードなし, 0.0-1.0: 進行中
final String? uploadCompleteFile; // アップロード完了ファイル名（バナー表示用）
```

`copyWith` にも対応するパラメータを追加:

```dart
double? uploadProgress,
bool clearUploadProgress = false,
String? uploadCompleteFile,
bool clearUploadCompleteFile = false,
```

#### 2b. uploadFile メソッドを追加

`FileBrowserNotifier` に以下のメソッドを追加:

```dart
/// ローカルファイルをリモートの現在のディレクトリにアップロードする。
Future<void> uploadFile(String localPath) async {
  final channelManager = _channelManager;
  if (channelManager == null) return;

  final fileName = localPath.split('/').last;
  final remotePath = '${state.currentPath}/$fileName';

  state = state.copyWith(uploadProgress: 0.0, clearUploadCompleteFile: true);

  try {
    final sftp = await channelManager.openSftpChannel();
    try {
      final localFile = File(localPath);
      final fileSize = await localFile.length();

      final remoteFile = await sftp.open(
        remotePath,
        mode: SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );

      try {
        final inputStream = localFile.openRead();
        int bytesWritten = 0;

        await for (final chunk in inputStream) {
          await remoteFile.writeBytes(Uint8List.fromList(chunk),
              offset: bytesWritten);
          bytesWritten += chunk.length;
          if (fileSize > 0) {
            state = state.copyWith(
                uploadProgress: bytesWritten / fileSize);
          }
        }
      } finally {
        await remoteFile.close();
      }
    } finally {
      sftp.close();
    }

    state = state.copyWith(
      clearUploadProgress: true,
      uploadCompleteFile: fileName,
    );

    // アップロード後に現在ディレクトリをリフレッシュ
    await refresh();
  } catch (e) {
    state = state.copyWith(clearUploadProgress: true);
    rethrow;
  }
}

/// アップロード完了バナーを消す。
void clearUploadNotification() {
  state = state.copyWith(clearUploadCompleteFile: true);
}
```

**注意**:
- `dart:io` の `File` と `dart:typed_data` の `Uint8List` を import する
- `SftpFileOpenMode` は dartssh2 パッケージから利用可能
- `SshChannelManager.openSftpChannel()` は既存メソッド
- `SftpFile.writeBytes(Uint8List data, {int offset})` は dartssh2 API（`readBytes` の対になるメソッド）
- dartssh2 の `SftpFile` に `writeBytes` がない場合は `write(Stream<Uint8List>)` を使用する。以下のように変更:

```dart
// writeBytes の代わりに write を使う場合
final inputStream = localFile.openRead().map((chunk) => Uint8List.fromList(chunk));
await remoteFile.write(inputStream, onProgress: (bytesWritten) {
  if (fileSize > 0) {
    state = state.copyWith(uploadProgress: bytesWritten / fileSize);
  }
});
```

dartssh2 の SftpFile API を確認し、利用可能なメソッドに合わせること。既存の `downloadFile` メソッドの実装を参考にする。

### 手順 3: FileBrowserScreen にアップロード UI を追加

ファイル: `lib/features/file_browser/file_browser_screen.dart`

#### 3a. ヘッダーにアップロードボタンを追加

現在のヘッダー行（dotfiles トグル、リフレッシュボタン）にアップロードボタンを追加:

```dart
IconButton(
  icon: const Icon(Icons.upload_file, color: Colors.white),
  tooltip: 'Upload file',
  onPressed: () => _pickAndUploadFile(context),
),
```

#### 3b. ファイル選択 & アップロード処理

`_pickAndUploadFile` メソッドを追加:

```dart
Future<void> _pickAndUploadFile(BuildContext context) async {
  final result = await FilePicker.platform.pickFiles();
  if (result == null || result.files.isEmpty) return;
  final file = result.files.first;
  if (file.path == null) return;

  try {
    await ref
        .read(fileBrowserProvider(widget.connectionId).notifier)
        .uploadFile(file.path!);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Upload failed: $e')),
      );
    }
  }
}
```

`file_picker` パッケージは既に `pubspec.yaml` に含まれている（`file_picker: ^8.0.0`）。

#### 3c. アップロード進捗インジケーター

ダウンロード進捗と同様に、アップロード進捗バーをリスト上部に表示:

```dart
if (fileBrowserState.uploadProgress != null)
  Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Uploading... ${(fileBrowserState.uploadProgress! * 100).toStringAsFixed(0)}%',
          style: TextStyle(color: Colors.grey[400], fontSize: 12),
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: fileBrowserState.uploadProgress,
          backgroundColor: Colors.grey[800],
          color: Colors.tealAccent,
        ),
      ],
    ),
  ),
```

#### 3d. アップロード完了バナー

ダウンロードと同様に MaterialBanner を表示:

```dart
if (fileBrowserState.uploadCompleteFile != null)
  MaterialBanner(
    content: Text('アップロード完了: ${fileBrowserState.uploadCompleteFile}'),
    backgroundColor: Colors.green[800],
    actions: [
      TextButton(
        onPressed: () => ref
            .read(fileBrowserProvider(widget.connectionId).notifier)
            .clearUploadNotification(),
        child: const Text('OK'),
      ),
    ],
  ),
```

### 手順 4: テストを追加/更新

#### 4a. QuickActionBar テスト

ファイル: 既存テストファイルがあればそこに追加、なければ `test/widgets/quick_action_bar_test.dart` を作成。

テスト内容:
- C-c ボタンタップで `onKeyPressed(TerminalKey.keyC, ctrl: true)` が呼ばれること
- C-d ボタンタップで `onKeyPressed(TerminalKey.keyD, ctrl: true)` が呼ばれること
- C-j ボタンタップで `onKeyPressed(TerminalKey.keyJ, ctrl: true)` が呼ばれること

#### 4b. FileBrowserProvider アップロードテスト

ファイル: `test/features/file_browser/file_browser_provider_test.dart`（既存）

テスト内容:
- `uploadFile()` が SFTP の open → write → close を正しく呼ぶこと
- アップロード後に `refresh()` が呼ばれること
- エラー時にプログレスがクリアされること

## 実装順序

1. `lib/widgets/quick_action_bar.dart` — C-c, C-d, C-j ボタン追加 + Ctrl メニューに J 追加
2. `lib/features/file_browser/file_browser_provider.dart` — `FileBrowserState` に upload フィールド追加 + `uploadFile()` メソッド追加
3. `lib/features/file_browser/file_browser_screen.dart` — アップロードボタン + 進捗表示 + 完了バナー
4. テスト追加/更新
5. `~/flutter/bin/flutter analyze` でエラーがないことを確認
6. `~/flutter/bin/flutter test` で全テストパスを確認
7. `~/flutter/bin/flutter build apk --debug` でビルド
