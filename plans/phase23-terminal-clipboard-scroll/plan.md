---
goal: "Phase 23 - ターミナルのコピー&ペースト対応 + スクロール操作 + ダウンロード高速化"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 23: ターミナルのコピー&ペースト + スクロール

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題 1: ターミナルの長押しで貼り付け（ペースト）ができない

### 現状

- xterm パッケージは `PasteTextIntent` アクションを内蔵しているが、ハードウェアキーボードの `Ctrl+V`（または `Cmd+V`）でしか発動しない
- モバイルではハードウェアキーボードがないため、クリップボードからの貼り付けが不可能
- `QuickActionBar` にもペーストボタンがない

### 修正方針

xterm の `TerminalController` は `ChangeNotifier` を継承している。長押し時に xterm は自動的に `selectWord()` を呼ぶ。この選択状態の変更を `addListener` で監視し、選択が発生した際にコピー＆ペースト用のフローティングツールバー（`OverlayEntry`）を表示する。

ツールバーには「コピー」と「貼り付け」の両方のボタンを配置する。選択がない状態でも「貼り付け」は使えるようにする。

---

## 問題 2: ターミナルの文字を長押しして選択・コピーできない

### 現状

- xterm パッケージは長押しで `selectWord()` を実行し、選択範囲がハイライト表示される（`selection: Color(0x80FFFFFF)`）
- しかし `CopySelectionTextIntent` は `Ctrl+Shift+C` でしか発動しない
- モバイルでは選択したテキストをコピーする手段がない

### 修正方針

問題 1 と同じフローティングツールバーで解決する。選択テキストがある場合は「コピー」ボタンを表示。コピー処理は `terminal.buffer.getText(selection)` で選択テキストを取得し、`Clipboard.setData()` でクリップボードに書き込む。

コピー後は選択をクリアしてツールバーを非表示にする。

---

## 問題 3: 上下スクロールができない

### 現状分析

xterm パッケージは内部に `Scrollable` ウィジェットを持ち、通常バッファ（bash プロンプト等）ではスクロールバックバッファ（`maxLines: 10000`）を上下にスクロールできる仕組みになっている。

しかし、以下の理由でスクロールが機能しない可能性がある:

1. **代替バッファ（tmux, vim, less 等）**: `isUsingAltBuffer == true` のとき、xterm はスクロールジェスチャーを `mouseInput(wheelUp/wheelDown)` に変換する。アプリがマウスホイールをサポートしていない場合、`simulateScroll: true`（デフォルト、このアプリでも有効）で矢印キーに変換される
2. **タブスワイプとの競合**: `_TerminalTabContent` の親の `GestureDetector(onHorizontalDragEnd)` がジェスチャーアリーナで水平方向のドラッグを消費している。垂直スクロールが間接的に影響を受ける可能性がある

### 修正方針

1. `TerminalView` に `scrollController` を渡して外部からスクロール位置を制御可能にする
2. `QuickActionBar` にスクロール上下ボタン（Page Up / Page Down）を追加する。これにより確実にスクロール操作ができる
3. スクロールコントローラで「一番下に戻る」ボタンも追加する（スクロールバック閲覧後に最新出力に戻るため）

---

## 問題 4: 大きなファイルのダウンロードが非常に遅い

### 根本原因

dartssh2 の `SftpFile.read()` は内部でチャンクサイズと同時リクエスト数がハードコードされている:

```dart
const chunkSize = 16 * 1024;           // 16 KB
const maxBytesOnTheWire = chunkSize * 64; // 1 MB (同時リクエスト上限)
```

16KB チャンクは非常に小さく、各チャンクごとに SSH_FXP_READ → SSH_FXP_DATA のリクエスト/レスポンスが発生する。ネットワークレイテンシが加わると、大きなファイル（数十MB以上）では極端に遅くなる。

例: 100MB のファイルをダウンロードする場合:
- 16KB × 6400 回のリクエスト/レスポンス
- 各リクエストに 1ms のレイテンシがあると、それだけで 6.4 秒のオーバーヘッド

### 修正方針

dartssh2 の `SftpFile.read()` を使わず、低レベル API の `SftpFile._readChunk()` を直接呼ぶこともできないが（プライベート）、代わりに **`readBytes()` を並列でオフセット指定して呼び出す**戦略を取る。

具体的には:
1. `stat()` でファイルサイズを取得
2. **256KB チャンク** に分割（16KB → 256KB で 16 倍高速化）
3. **最大 8 チャンクを並列リクエスト**（パイプライニング）
4. 各チャンクを `readBytes(length: chunkSize, offset: chunkOffset)` で取得
5. 順序を保持してファイルに書き込み

ただし `readBytes` は内部で `read()` を呼ぶため根本的な改善にはならない。

**より効果的なアプローチ**: dartssh2 の `SftpFile` が公開している `_readChunk` 相当の API がないため、**SCP（Secure Copy Protocol）** を使う。`SSHClient.execute('cat "$remotePath"')` でファイル内容を stdout に流し、それを直接ファイルに書き込む。SCP/cat 方式はチャンクの概念がなく、SSH チャネルのウィンドウサイズ（通常 2MB）で自動的にフロー制御される。

```dart
Future<void> downloadFileViaScp(String remotePath, File localFile) async {
  final escaped = remotePath.replaceAll("'", r"'\''");
  final session = await client.execute("cat '$escaped'");
  final sink = localFile.openWrite();
  try {
    int received = 0;
    await for (final chunk in session.stdout) {
      sink.add(chunk);
      received += chunk.length;
      // progress callback
    }
  } finally {
    await sink.close();
  }
}
```

**SCP 方式の利点**:
- SSH チャネルのウィンドウサイズ（通常 2MB）で効率的にフロー制御
- リクエスト/レスポンスのラウンドトリップが発生しない（ストリーミング）
- チャンクサイズに依存しない
- 巨大ファイルでも一定のスループットを維持

**SCP 方式の注意点**:
- バイナリファイルもそのまま stdout に流れるので問題なし
- ファイルサイズの事前取得は `stat()` で行う（進捗表示用）
- エラーハンドリング: `session.exitCode` を確認

---

## 実装手順

### 手順 1: フローティングツールバー用ウィジェットの作成

ファイル: `lib/widgets/terminal_selection_toolbar.dart`（新規作成）

選択テキストのコピーとクリップボードからの貼り付けを行うフローティングツールバー:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

class TerminalSelectionToolbar extends StatelessWidget {
  const TerminalSelectionToolbar({
    super.key,
    required this.terminal,
    required this.controller,
    required this.onPaste,
    required this.onDismiss,
  });

  final Terminal terminal;
  final TerminalController controller;
  final void Function(String text) onPaste;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final hasSelection = controller.selection != null;
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      color: Colors.grey[800],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasSelection)
              _ToolbarButton(
                icon: Icons.copy,
                label: 'コピー',
                onPressed: () => _handleCopy(context),
              ),
            _ToolbarButton(
              icon: Icons.paste,
              label: '貼り付け',
              onPressed: () => _handlePaste(context),
            ),
          ],
        ),
      ),
    );
  }

  void _handleCopy(BuildContext context) {
    final selection = controller.selection;
    if (selection == null) return;
    final text = terminal.buffer.getText(selection);
    Clipboard.setData(ClipboardData(text: text));
    controller.clearSelection();
    onDismiss();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('コピーしました'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  Future<void> _handlePaste(BuildContext context) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      onPaste(data.text!);
    }
    controller.clearSelection();
    onDismiss();
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: Colors.white),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
```

**API 確認済み**:
- `TerminalController` は `ChangeNotifier` を mixin しており、`setSelection()` / `clearSelection()` で `notifyListeners()` が呼ばれる → `addListener` で選択変更を検知可能
- `terminal.buffer.getText(selection)` — 選択テキスト取得の正しい API（`BufferRange?` を受け取る）
- `controller.clearSelection()` — 選択クリアの正しい API
- `terminal.selectAll()` は **存在しない** → 「全選択」ボタンは省略
- `terminal.paste(text)` — bracketed paste mode を正しく処理するペースト用 API。`textInput()` の代わりにこちらを使う

### 手順 2: TerminalView にフローティングツールバーを統合

ファイル: `lib/features/terminal/terminal_screen.dart`

`_TerminalTabContentState` に以下を追加:

#### 2a. 状態変数の追加

```dart
OverlayEntry? _toolbarOverlay;
```

#### 2b. TerminalController のリスナー追加

`initState()` に追加:
```dart
_terminalController.addListener(_onSelectionChanged);
```

`dispose()` に追加（`_terminalController.dispose()` の前）:
```dart
_terminalController.removeListener(_onSelectionChanged);
_hideToolbar();
```

#### 2c. 選択変更時のツールバー表示メソッド

```dart
void _onSelectionChanged() {
  if (_terminalController.selection != null) {
    _showToolbar();
  }
}

void _showToolbar() {
  _hideToolbar();
  final overlay = Overlay.of(context);
  _toolbarOverlay = OverlayEntry(
    builder: (context) {
      // IgnorePointer で全画面を透過させ、ツールバー部分のみタッチ可能にする
      // → xterm のジェスチャーをブロックしない
      return Positioned(
        top: MediaQuery.of(context).padding.top + kToolbarHeight + 8,
        left: 0,
        right: 0,
        child: IgnorePointer(
          ignoring: false,
          child: Center(
            child: TerminalSelectionToolbar(
              terminal: ref.read(
                terminalConnectionProvider(widget.sessionId),
              ).terminal!,
              controller: _terminalController,
              onPaste: (text) {
                ref.read(
                  terminalConnectionProvider(widget.sessionId),
                ).terminal?.paste(text);
              },
              onDismiss: _hideToolbar,
            ),
          ),
        ),
      );
    },
  );
  overlay.insert(_toolbarOverlay!);
}

void _hideToolbar() {
  _toolbarOverlay?.remove();
  _toolbarOverlay = null;
}
```

#### 2d. タップ時にツールバーを非表示にする

`TerminalView` の `onTapUp` パラメータを設定:

変更前:
```dart
TerminalView(
  connectionState.terminal!,
  controller: _terminalController,
  focusNode: _focusNode,
  autofocus: true,
  autoResize: true,
  deleteDetection: true,
  textScaler: TextScaler.linear(fontSize / 14.0),
  theme: const TerminalTheme(
```

変更後:
```dart
TerminalView(
  connectionState.terminal!,
  controller: _terminalController,
  focusNode: _focusNode,
  autofocus: true,
  autoResize: true,
  deleteDetection: true,
  textScaler: TextScaler.linear(fontSize / 14.0),
  onTapUp: (_, __) {
    // タップで選択がクリアされたらツールバーも非表示
    if (_terminalController.selection == null) {
      _hideToolbar();
    }
  },
  theme: const TerminalTheme(
```

### 手順 3: QuickActionBar に貼り付けボタンとスクロールボタンを追加

ファイル: `lib/widgets/quick_action_bar.dart`

#### 3a. コンストラクタにコールバック追加

変更前:
```dart
class QuickActionBar extends StatelessWidget {
  const QuickActionBar({
    super.key,
    required this.onKeyPressed,
    required this.onTextInput,
    this.onImagePaste,
  });

  final void Function(TerminalKey key, {bool ctrl}) onKeyPressed;
  final void Function(String text) onTextInput;
  final VoidCallback? onImagePaste;
```

変更後:
```dart
class QuickActionBar extends StatelessWidget {
  const QuickActionBar({
    super.key,
    required this.onKeyPressed,
    required this.onTextInput,
    this.onImagePaste,
    this.onClipboardPaste,
    this.onScrollToTop,
    this.onScrollToBottom,
  });

  final void Function(TerminalKey key, {bool ctrl}) onKeyPressed;
  final void Function(String text) onTextInput;
  final VoidCallback? onImagePaste;
  final VoidCallback? onClipboardPaste;
  final VoidCallback? onScrollToTop;
  final VoidCallback? onScrollToBottom;
```

#### 3b. ボタン追加

矢印ボタンの後、画像ボタンの前にスクロールボタンを追加。画像ボタンの後にペーストボタンを追加:

```dart
const SizedBox(width: 8),
_ActionButton(
  icon: Icons.vertical_align_top,
  onPressed: onScrollToTop ?? () {},
),
_ActionButton(
  icon: Icons.vertical_align_bottom,
  onPressed: onScrollToBottom ?? () {},
),
const SizedBox(width: 8),
if (onImagePaste != null) ...[
  _ActionButton(
    icon: Icons.image,
    onPressed: onImagePaste!,
  ),
],
if (onClipboardPaste != null) ...[
  _ActionButton(
    icon: Icons.content_paste,
    onPressed: onClipboardPaste!,
  ),
],
```

### 手順 4: スクロールコントローラの統合

ファイル: `lib/features/terminal/terminal_screen.dart`

#### 4a. ScrollController の追加

`_TerminalTabContentState` に追加:

```dart
final ScrollController _scrollController = ScrollController();
```

`dispose()` に追加:
```dart
_scrollController.dispose();
```

#### 4b. TerminalView に scrollController を渡す

変更前:
```dart
TerminalView(
  connectionState.terminal!,
  controller: _terminalController,
```

変更後:
```dart
TerminalView(
  connectionState.terminal!,
  controller: _terminalController,
  scrollController: _scrollController,
```

#### 4c. QuickActionBar にスクロールコールバックを渡す

変更前:
```dart
QuickActionBar(
  onKeyPressed: ...
  onTextInput: ...
  onImagePaste: ...
),
```

変更後:
```dart
QuickActionBar(
  onKeyPressed: ...
  onTextInput: ...
  onImagePaste: ...
  onClipboardPaste: () async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      connectionState.terminal?.paste(data.text!);
    }
  },
  onScrollToTop: () {
    // 通常バッファ: ScrollController でスクロールバック先頭へ
    // 代替バッファ（tmux等）: ScrollController は機能しないため
    // 効果がない場合がある（tmux では Ctrl+B [ でスクロールモードに入る）
    if (_scrollController.hasClients &&
        _scrollController.position.maxScrollExtent > 0) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  },
  onScrollToBottom: () {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  },
),
```

`import 'package:flutter/services.dart'` が必要（`Clipboard` 用）。

### 手順 5: ファイルダウンロードの高速化（SCP 方式）

ファイル: `lib/features/file_browser/file_browser_provider.dart`

現在の `downloadFile` メソッドは `SftpFile.read()` を使っているが、dartssh2 内部のチャンクサイズが 16KB にハードコードされており非常に遅い。`SSHClient.execute('cat ...')` による SCP 方式に変更する。

#### 5a. SshChannelManager に高速ダウンロードメソッドを追加

ファイル: `lib/core/ssh/ssh_channel_manager.dart`

```dart
/// 高速ファイルダウンロード: cat コマンドの stdout をストリーミングで取得。
/// SFTP の 16KB チャンク制限を回避し、SSH チャネルのウィンドウサイズ（通常 2MB）で
/// 効率的にデータを転送する。
Future<Stream<List<int>>> readFileViaExec(String remotePath) async {
  final escaped = remotePath.replaceAll("'", r"'\''");
  final session = await client.execute("cat '$escaped'");
  return session.stdout;
}
```

#### 5b. downloadFile メソッドの変更

変更前:
```dart
final remoteFile = await sftp.open(remotePath, mode: SftpFileOpenMode.read);
try {
  final stat = await remoteFile.stat();
  final totalBytes = stat.size ?? 0;
  int received = 0;

  final sink = tempFile.openWrite();
  try {
    await for (final chunk in remoteFile.read(
      onProgress: (n) {
        received = n;
        if (totalBytes > 0) {
          final progress = received / totalBytes;
          state = AsyncData(cur.copyWith(downloadProgress: progress));
        }
      },
    )) {
      sink.add(chunk);
    }
  } finally {
    await sink.close();
  }
} finally {
  await remoteFile.close();
}
```

変更後:
```dart
// ファイルサイズを SFTP で取得（進捗表示用）
final sftp = _sftp ?? (throw NetworkError('SFTP not initialized'));
final stat = await sftp.stat(remotePath);
final totalBytes = stat.size ?? 0;

// cat コマンドで高速ダウンロード（SFTP の 16KB チャンク制限を回避）
final channelManager = _channelManager ??
    (throw NetworkError('Channel manager not initialized'));
final stdout = await channelManager.readFileViaExec(remotePath);

int received = 0;
final sink = tempFile.openWrite();
try {
  await for (final chunk in stdout) {
    sink.add(chunk);
    received += chunk.length;
    if (totalBytes > 0) {
      final progress = received / totalBytes;
      state = AsyncData(cur.copyWith(downloadProgress: progress));
    }
  }
} finally {
  await sink.close();
}
```

**注意**: `FileBrowserNotifier` は既に `_channelManager` フィールド（`SshChannelManager?`）を `setChannelManager()` で受け取っている（line 88 付近）。`readFileViaExec()` はこの既存フィールドを通じて呼び出す。`_channelManager` が null の場合は `NetworkError` を投げる（既存パターンと同じ）。

**バイナリ安全性**: SSH exec チャネルは 8-bit clean であり、dartssh2 の `session.stdout` は `Stream<Uint8List>` として生バイトを返す。`String` への変換さえしなければバイナリデータの破損はない。

#### 5c. 進捗更新の頻度制限

大きなファイルでは進捗更新が頻繁すぎる（チャンクごと）ため、UI スレッドの負荷を減らす:

```dart
int received = 0;
int lastProgressUpdate = 0;
final sink = tempFile.openWrite();
try {
  await for (final chunk in stdout) {
    // バイナリデータをそのまま書き込み（String 変換しないこと！）
    sink.add(chunk);
    received += chunk.length;
    // 64KB ごとに進捗更新（UI 負荷を軽減）
    if (totalBytes > 0 && received - lastProgressUpdate >= 65536) {
      lastProgressUpdate = received;
      final progress = received / totalBytes;
      state = AsyncData(cur.copyWith(downloadProgress: progress));
    }
  }
  // 最終進捗
  if (totalBytes > 0) {
    state = AsyncData(cur.copyWith(downloadProgress: 1.0));
  }
} finally {
  await sink.close();
}

// 整合性チェック: 受信バイト数とファイルサイズを比較
if (totalBytes > 0 && received != totalBytes) {
  throw NetworkError(
    'Download incomplete: received $received of $totalBytes bytes',
  );
}
```

---

## テストへの影響

- `TerminalSelectionToolbar`: 新規ウィジェット。新しいテストファイル `test/widgets/terminal_selection_toolbar_test.dart` の作成を検討
- `QuickActionBar`: 新パラメータ追加（全て optional）。既存テストに影響なし。新ボタンのテスト追加が必要な可能性あり
- `TerminalView` の `onTapUp` / `scrollController` 追加: テストの TerminalView モック/設定に影響する可能性あり
- `OverlayEntry` 使用: テスト環境で `Overlay` が必要になる場合がある
- `downloadFile` の SCP 方式変更: `SshChannelManager.readFileViaExec` の新メソッド + `downloadFile` の呼び出し変更。既存の `file_browser_provider_test.dart` のダウンロードテストが影響を受ける可能性

## 実装順序

1. `lib/widgets/terminal_selection_toolbar.dart`:
   - 新規作成: フローティングツールバーウィジェット
2. `lib/widgets/quick_action_bar.dart`:
   - `onClipboardPaste`, `onScrollToTop`, `onScrollToBottom` パラメータ追加
   - スクロールボタンとペーストボタン追加
3. `lib/features/terminal/terminal_screen.dart`:
   - `ScrollController` 追加、`TerminalView` に渡す
   - `TerminalController` リスナーでフローティングツールバー表示
   - `onTapUp` でツールバー非表示
   - `QuickActionBar` にスクロール・ペーストコールバック接続
4. `lib/core/ssh/ssh_channel_manager.dart`:
   - `readFileViaExec()` メソッド追加
5. `lib/features/file_browser/file_browser_provider.dart`:
   - `downloadFile()` を SCP 方式に変更
   - 進捗更新の頻度制限（64KB ごと）
6. テスト確認・修正
7. `~/flutter/bin/flutter analyze`
8. `~/flutter/bin/flutter test`
9. `~/flutter/bin/flutter build apk --debug`
