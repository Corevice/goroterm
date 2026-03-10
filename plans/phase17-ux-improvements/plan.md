---
goal: "Phase 17 - UI安定化 + 音量ボタンフォントサイズ + ファイルブラウザCWD + tmuxタブ動作改善"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 17: UI安定化 + 音量ボタンフォントサイズ + ファイルブラウザCWD + tmuxタブ動作改善

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

## 概要

4つの改善を実装する：

1. **UI の安定化**: 大量テキスト入出力時に UI が崩れる問題を修正
2. **音量ボタンでフォントサイズ変更**: Volume Up/Down でフォントサイズを調整 + サイズ範囲を拡大
3. **ファイルブラウザを現在の作業ディレクトリで開く**: ターミナルの CWD を取得してファイルブラウザの初期パスにする
4. **tmux セッション attach 時に新しいタブで開く**: ただし同じセッションが既に開いているタブがあればそのタブに切り替え

## 実装手順

### 手順 1: UI 安定化 — TerminalView の textScaler 計算を改善

ファイル: `lib/features/terminal/terminal_screen.dart`

**問題**: 大量の文字入出力時に UI が崩れやすい。`textScaler: TextScaler.linear(fontSize / 14.0)` で文字サイズを制御しているが、特に大きい/小さいサイズで xterm パッケージのレイアウト計算が不安定になる。

**修正**:
- `TerminalView` を `Expanded` + `ClipRect` で囲み、オーバーフローを防ぐ
- `autoResize: true` は維持するが、表示領域をクリップで制限

変更前（`_TerminalTabContentState.build()` 内）:
```dart
Expanded(
  child: connectionState.terminal != null
      ? TerminalView(
          connectionState.terminal!,
          // ...
        )
      : const Center(
          child: CircularProgressIndicator(),
        ),
),
```

変更後:
```dart
Expanded(
  child: connectionState.terminal != null
      ? ClipRect(
          child: TerminalView(
            connectionState.terminal!,
            // ...
          ),
        )
      : const Center(
          child: CircularProgressIndicator(),
        ),
),
```

### 手順 2: FontSizeNotifier のサイズ範囲を拡大 + 増減メソッド追加

ファイル: `lib/core/theme/theme_provider.dart`

現在の `validSizes` は `[12.0, 14.0, 16.0, 18.0, 20.0, 24.0]` で、音量ボタン操作に対応するために増減メソッドを追加する。

変更後:
```dart
class FontSizeNotifier extends Notifier<double> {
  static const _defaultSize = 14.0;
  static const _minSize = 8.0;
  static const _maxSize = 32.0;
  static const _step = 2.0;

  @override
  double build() => _defaultSize;

  void setFontSize(double size) {
    state = size.clamp(_minSize, _maxSize);
  }

  /// フォントサイズを 1 段階上げる（音量アップ）
  void increase() {
    state = (state + _step).clamp(_minSize, _maxSize);
  }

  /// フォントサイズを 1 段階下げる（音量ダウン）
  void decrease() {
    state = (state - _step).clamp(_minSize, _maxSize);
  }
}
```

**注意**: `validSizes` リストと `assert` は削除する。`setFontSize` は clamp で範囲制限するだけにする。設定画面 (`lib/features/settings/settings_screen.dart`) 側で `validSizes` を参照している場合はそれも更新する。設定画面では Slider ウィジェットに変更するか、ドロップダウンのリストを拡張する。

設定画面を確認し、`FontSizeNotifier.validSizes` を参照している箇所があれば、Slider に変更するか参照を修正する。

### 手順 3: 音量ボタンでフォントサイズを変更

ファイル: `lib/features/terminal/terminal_screen.dart`

`_TerminalScreenState` に `KeyboardListener`（または `RawKeyboardListener` / Flutter 3.x では `KeyboardListener`）を使って音量ボタンのイベントを受け取る。

**方法**: Android の音量ボタンイベントは Flutter の標準的な `KeyEvent` では受け取れないため、`FocusScope` + `KeyboardListener` ではなく、Android のネイティブ側で `onKeyDown` をオーバーライドするか、`HardwareKeyboard` を使用する。

Flutter 3.x では `HardwareKeyboard.instance.addHandler()` で音量ボタンを検知できる。

`_TerminalScreenState` に以下を追加:

```dart
@override
void initState() {
  super.initState();
  WidgetsBinding.instance.addObserver(this);
  HardwareKeyboard.instance.addHandler(_handleHardwareKey);
}

@override
void dispose() {
  HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
  WidgetsBinding.instance.removeObserver(this);
  super.dispose();
}

bool _handleHardwareKey(KeyEvent event) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

  if (event.logicalKey == LogicalKeyboardKey.audioVolumeUp) {
    ref.read(fontSizeProvider.notifier).increase();
    return true; // イベントを消費（実際の音量変更を防ぐ）
  }
  if (event.logicalKey == LogicalKeyboardKey.audioVolumeDown) {
    ref.read(fontSizeProvider.notifier).decrease();
    return true;
  }
  return false;
}
```

`import 'package:flutter/services.dart';` を追加する（`LogicalKeyboardKey`, `HardwareKeyboard`, `KeyEvent`, `KeyDownEvent`, `KeyRepeatEvent` 用）。

**注意**: `return true` でイベントを消費すると、音量ボタンを押しても端末の音量は変わらない。ターミナル画面でのみ有効。ターミナル画面を離れたら `removeHandler` で解除される。

**フォントサイズ表示**: サイズ変更時にユーザーに現在のサイズを知らせるため、一時的なオーバーレイ（SnackBar）を表示する。

```dart
bool _handleHardwareKey(KeyEvent event) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

  if (event.logicalKey == LogicalKeyboardKey.audioVolumeUp) {
    ref.read(fontSizeProvider.notifier).increase();
    _showFontSizeIndicator();
    return true;
  }
  if (event.logicalKey == LogicalKeyboardKey.audioVolumeDown) {
    ref.read(fontSizeProvider.notifier).decrease();
    _showFontSizeIndicator();
    return true;
  }
  return false;
}

void _showFontSizeIndicator() {
  final size = ref.read(fontSizeProvider);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('Font size: ${size.toInt()}'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
}
```

### 手順 4: ファイルブラウザを現在の作業ディレクトリで開く

#### 4a. TerminalConnectionState に CWD を追加

ファイル: `lib/features/terminal/terminal_connection_provider.dart`

`TerminalConnectionState` には CWD を直接追加しない。代わりに、ファイルブラウザを開く直前にリモートの CWD を SSH exec で取得する。

#### 4b. FileBrowserNotifier に初期パス設定メソッドを追加

ファイル: `lib/features/file_browser/file_browser_provider.dart`

`FileBrowserNotifier` に初期ディレクトリを SSH exec で取得して設定するメソッドを追加:

```dart
/// リモートの現在の作業ディレクトリを取得して、そのパスに移動する。
/// 取得できない場合はホームディレクトリに移動する。
Future<void> navigateToWorkingDirectory() async {
  final channelManager = _channelManager;
  if (channelManager == null) return;

  try {
    final session = await channelManager.executeCommand('pwd');
    final stdoutChunks = await session.stdout.toList();
    await session.done;
    final output = utf8.decode(
      stdoutChunks.expand((e) => e).toList(),
      allowMalformed: true,
    );
    final cwd = output.trim();
    if (cwd.isNotEmpty && cwd.startsWith('/')) {
      await navigateTo(cwd);
      return;
    }
  } catch (_) {
    // CWD 取得失敗時はフォールバック
  }

  // フォールバック: ホームディレクトリ
  try {
    final session = await channelManager.executeCommand('echo \$HOME');
    final stdoutChunks = await session.stdout.toList();
    await session.done;
    final output = utf8.decode(
      stdoutChunks.expand((e) => e).toList(),
      allowMalformed: true,
    );
    final home = output.trim();
    if (home.isNotEmpty && home.startsWith('/')) {
      await navigateTo(home);
      return;
    }
  } catch (_) {}

  // 最終フォールバック: ルート
  await navigateTo('/');
}
```

`dart:convert` の import が必要（既に import されているか確認する。されていなければ追加）。

#### 4c. ファイルブラウザ Drawer を開くときに CWD を設定

ファイル: `lib/features/terminal/terminal_screen.dart`

`Scaffold` の `onDrawerChanged` コールバックを追加して、ファイルブラウザ Drawer が開かれたときに CWD に移動する:

```dart
onDrawerChanged: (isOpened) {
  if (isOpened) {
    ref
        .read(fileBrowserProvider(activeSession.sessionId).notifier)
        .navigateToWorkingDirectory();
  }
},
```

**注意**: `navigateToWorkingDirectory()` は exec チャネルで `pwd` を実行するが、これはターミナル内で開いているシェルの CWD ではなく、新しい exec セッションの CWD（通常はホームディレクトリ）を返す。

ターミナル内のシェルの CWD を取得するには、PTY セッション経由で特殊なエスケープシーケンスを使うか、`/proc/self/cwd` のような OS 固有の方法が必要。ただし、SSH exec の `pwd` は新しいログインシェルの CWD を返すため、実質的にはホームディレクトリになる。

**より正確な方法**: ターミナルの PTY セッションの PID を取得して `/proc/<pid>/cwd` を readlink する。しかしこれは Linux サーバー限定で、macOS では動作しない。

**現実的なアプローチ**: 最初の Drawer 表示時にホームディレクトリに移動する。ユーザーが手動でナビゲートしたパスはセッション中保持される（`FileBrowserNotifier` の state は keepAlive されているため）。最初だけ `/` ではなくホームディレクトリを初期パスにする。

修正方針: `FileBrowserNotifier.build()` で初期パスをホームディレクトリにする。

```dart
@override
Future<FileBrowserState> build(String arg) async {
  ref.keepAlive();
  // channelManager が設定されたらホームディレクトリに移動
  if (_channelManager != null) {
    try {
      final session = await _channelManager!.executeCommand('echo \$HOME');
      final stdoutChunks = await session.stdout.toList();
      await session.done;
      final output = utf8.decode(
        stdoutChunks.expand((e) => e).toList(),
        allowMalformed: true,
      );
      final home = output.trim();
      if (home.isNotEmpty && home.startsWith('/')) {
        final items = await _listDirectory(_channelManager!, home);
        return FileBrowserState(currentPath: home, items: items);
      }
    } catch (_) {}
  }
  return const FileBrowserState();
}
```

ただし、`FileBrowserNotifier` が `FamilyAsyncNotifier` ではなく `FamilyNotifier` の場合は `build()` の戻り値型が異なる。現在の実装を確認して合わせること。

### 手順 5: tmux セッション attach 時に新しいタブで開く

#### 5a. TmuxManagerScreen の onAttach コールバックを変更

現在の `onAttach` は `attachSession(name)` を呼び、端末に `tmux attach -t <name>\r` を直接書き込む。

新しい動作:
1. 既に同じ tmux セッションが開いている（attach 済み）タブがあれば、そのタブに切り替え
2. なければ、**同じ SSH 接続**で新しいタブを開き、そのタブで `tmux attach -t <name>` を実行

#### 5b. SessionManagerNotifier にヘルパーを追加

ファイル: `lib/features/terminal/session_manager.dart`

`TerminalSession` に tmux セッション名を保持するフィールドを追加:

```dart
class TerminalSession {
  const TerminalSession({
    required this.sessionId,
    required this.connectionId,
    required this.label,
    this.tmuxSessionName,
  });

  final String sessionId;
  final int connectionId;
  final String label;
  final String? tmuxSessionName; // attach 中の tmux セッション名
}
```

`SessionManagerNotifier` にヘルパーメソッドを追加:

```dart
/// 指定された tmux セッションが既に開いているタブを探す。
/// 同じ connectionId で同じ tmuxSessionName のセッションを返す。
String? findSessionByTmux(int connectionId, String tmuxSessionName) {
  for (final session in state.sessions) {
    if (session.connectionId == connectionId &&
        session.tmuxSessionName == tmuxSessionName) {
      return session.sessionId;
    }
  }
  return null;
}

/// tmux セッション用の新しいタブを追加。
String addTmuxSession({
  required int connectionId,
  required String label,
  required String tmuxSessionName,
}) {
  _sessionCounter++;
  final sessionId = 'session_${connectionId}_$_sessionCounter';
  final session = TerminalSession(
    sessionId: sessionId,
    connectionId: connectionId,
    label: 'tmux: $tmuxSessionName',
    tmuxSessionName: tmuxSessionName,
  );
  final updated = [...state.sessions, session];
  state = state.copyWith(sessions: updated, activeSessionId: sessionId);
  SshForegroundService.ensureRunning(sessionCount: updated.length);
  return sessionId;
}
```

#### 5c. TmuxManagerScreen から tmux attach 時の動作を変更

ファイル: `lib/features/tmux/tmux_manager_screen.dart`

現在の `onAttach` コールバック:
```dart
onAttach: (name) => ref
    .read(tmuxProvider(widget.connectionId).notifier)
    .attachSession(name),
```

これを変更。`TmuxManagerScreen` は Drawer 内にあるため、`SessionManagerNotifier` にアクセスして、tmux セッション用の新しいタブを開くか既存タブに切り替える必要がある。

ただし `TmuxManagerScreen` の `widget.connectionId` は sessionId（`TerminalSession.sessionId`）であり、DB の `connectionId`（int）ではない。`TerminalSession` から `connectionId`（int）を取得する必要がある。

`TerminalScreen` から `TmuxManagerScreen` に `onAttachTmuxSession` コールバックを渡す方法が最も clean:

**TerminalScreen 側**（`endDrawer` の部分）:

```dart
endDrawer: Drawer(
  width: MediaQuery.of(context).size.width * 0.85,
  backgroundColor: Colors.grey[900],
  child: SafeArea(
    child: TmuxManagerScreen(
      connectionId: activeSession.sessionId,
      onAttachSession: (tmuxSessionName) {
        // Drawer を閉じる
        Navigator.of(context).pop();
        _attachTmuxSession(
          activeSession.connectionId,
          tmuxSessionName,
        );
      },
    ),
  ),
),
```

`_attachTmuxSession` メソッドを `_TerminalScreenState` に追加:

```dart
void _attachTmuxSession(int connectionId, String tmuxSessionName) {
  final manager = ref.read(sessionManagerProvider.notifier);
  final managerState = ref.read(sessionManagerProvider);

  // 既に同じ tmux セッションが開いているか確認
  final existingSessionId = manager.findSessionByTmux(
    connectionId,
    tmuxSessionName,
  );

  if (existingSessionId != null) {
    // 既存タブに切り替え
    manager.setActiveSession(existingSessionId);
  } else {
    // 新しいタブで開く
    final sessionId = manager.addTmuxSession(
      connectionId: connectionId,
      label: tmuxSessionName,
      tmuxSessionName: tmuxSessionName,
    );
    // 新しいタブの接続完了後に tmux attach コマンドを送信
    // _TerminalTabContent が接続完了したら自動的に tmux attach を実行する必要がある
    // → TerminalSession に tmuxSessionName が設定されている場合、
    //   接続完了後に自動的に tmux attach を実行するロジックを _TerminalTabContent に追加
  }
}
```

#### 5d. _TerminalTabContent で tmux セッション自動 attach

ファイル: `lib/features/terminal/terminal_screen.dart`

`_TerminalTabContent` が tmux セッション名を持つ場合、SSH 接続完了後に自動的に `tmux attach -t <name>` を送信する。

`_TerminalTabContent` に `tmuxSessionName` パラメータを追加:

```dart
class _TerminalTabContent extends ConsumerStatefulWidget {
  const _TerminalTabContent({
    super.key,
    required this.sessionId,
    required this.connectionId,
    required this.isActive,
    this.tmuxSessionName,
  });

  final String sessionId;
  final int connectionId;
  final bool isActive;
  final String? tmuxSessionName;
  // ...
}
```

`_TerminalTabContentState` の `_startConnection()` の最後（接続成功後）で tmux attach を送信:

```dart
await ref
    .read(terminalConnectionProvider(widget.sessionId).notifier)
    .connect(
      config: config,
      password: password,
      privateKeyPem: privateKeyPem,
      passphrase: passphrase,
    );

// tmux セッション名が指定されている場合、接続後に自動 attach
if (widget.tmuxSessionName != null && mounted) {
  // 少し待ってからコマンドを送信（シェルのプロンプトが出るまで待つ）
  await Future.delayed(const Duration(milliseconds: 500));
  final terminal = ref.read(terminalConnectionProvider(widget.sessionId)).terminal;
  if (terminal != null) {
    final escaped = widget.tmuxSessionName!.replaceAll("'", r"'\''");
    terminal.textInput("tmux attach -t '$escaped'\r");
  }
}
```

`IndexedStack` の `_TerminalTabContent` 生成部分で `tmuxSessionName` を渡す:

```dart
children: sessions
    .map((s) => _TerminalTabContent(
          key: ValueKey(s.sessionId),
          sessionId: s.sessionId,
          connectionId: s.connectionId,
          isActive: s.sessionId == activeSession.sessionId,
          tmuxSessionName: s.tmuxSessionName,
        ))
    .toList(),
```

#### 5e. TmuxManagerScreen に onAttachSession コールバックを追加

ファイル: `lib/features/tmux/tmux_manager_screen.dart`

`TmuxManagerScreen` に `onAttachSession` コールバックを追加:

```dart
class TmuxManagerScreen extends ConsumerStatefulWidget {
  const TmuxManagerScreen({
    super.key,
    required this.connectionId,
    this.onAttachSession,
  });

  final String connectionId;
  final void Function(String tmuxSessionName)? onAttachSession;
  // ...
}
```

`_SessionListView` の `onAttach` を変更:

```dart
onAttach: (name) {
  if (widget.onAttachSession != null) {
    widget.onAttachSession!(name);
  } else {
    // フォールバック: 現在のターミナルに直接 attach
    ref
        .read(tmuxProvider(widget.connectionId).notifier)
        .attachSession(name);
    Navigator.of(context).pop();
  }
},
```

ただし `TmuxManagerScreen` は `ConsumerStatefulWidget` なので、`_TmuxManagerScreenState` の `build()` で `widget.onAttachSession` を `_SessionListView` に渡す必要がある。`_SessionListView` の `onAttach` の型も `void Function(String name)` のままでよい。

## テストへの影響

- `FontSizeNotifier` のテスト: `validSizes` リストの削除 + `increase()`/`decrease()` メソッドのテスト追加
- `SessionManagerNotifier` のテスト: `TerminalSession.tmuxSessionName` フィールド追加 + `findSessionByTmux()`, `addTmuxSession()` のテスト追加
- `TmuxManagerScreen` のテスト: `onAttachSession` コールバックのテスト
- `QuickActionBar` の既存テストがある場合は影響なし

## 実装順序

1. `lib/core/theme/theme_provider.dart` — `FontSizeNotifier` のサイズ範囲拡大 + `increase()`/`decrease()` 追加
2. `lib/features/settings/settings_screen.dart` — 設定画面のフォントサイズ選択を更新（`validSizes` 参照がある場合）
3. `lib/features/terminal/terminal_screen.dart` — 音量ボタンハンドラ追加 + `ClipRect` 追加 + `onDrawerChanged` 追加 + tmux attach 新タブロジック
4. `lib/features/file_browser/file_browser_provider.dart` — `navigateToWorkingDirectory()` 追加 or `build()` でホームディレクトリ初期化
5. `lib/features/terminal/session_manager.dart` — `TerminalSession.tmuxSessionName` + `findSessionByTmux()` + `addTmuxSession()`
6. `lib/features/tmux/tmux_manager_screen.dart` — `onAttachSession` コールバック追加
7. テスト追加/更新
8. `~/flutter/bin/flutter analyze` でエラーがないことを確認
9. `~/flutter/bin/flutter test` で全テストパスを確認
10. `~/flutter/bin/flutter build apk --debug` でビルド
