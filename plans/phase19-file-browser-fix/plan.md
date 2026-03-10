---
goal: "Phase 19 - ファイルブラウザ修正 + タブUX改善 + バックグラウンド接続強化 + 矢印順序 + 画像貼付"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 19: 総合 UX 改善

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題 1: ファイル一覧を開いて別アプリに移動すると画面が真っ暗になる

### 根本原因分析

ファイルブラウザ（左 Drawer）を開いた状態でアプリをバックグラウンドに移行すると:

1. バックグラウンドで SSH 接続が切断される（または Phase 18 の自動再接続が発動する）
2. 再接続時に `_channelManagerSubscription` のコールバックで `setChannelManager(null)` → `setChannelManager(newManager)` が呼ばれる
3. `setChannelManager(null)` で `state = AsyncError(NetworkError(...))` になる
4. 再接続がまだ完了していない状態でユーザーが復帰した場合、`AsyncError` 状態のエラー画面が表示される（黒背景に赤いエラーアイコン = 「真っ暗」に見える）

### 修正方針

バックグラウンド移行時に Drawer を自動的に閉じる。復帰時にはクリーンなターミナル画面が表示される。

---

## 問題 2: 今開いているタブのカレントディレクトリでファイル一覧が開かない

### 根本原因分析

現在の `navigateToInitialDirectory()` は `sftp.absolute('.')` を実行するが、SFTP セッションの `.` は常に SSH ログインユーザーの**ホームディレクトリ**を指す。ターミナルで `cd /var/log` などしていても、SFTP チャネルは独立しているためホームディレクトリに戻る。

### 技術的アプローチ

`/proc` ファイルシステムを利用して PTY シェルの CWD を取得する（Linux best-effort、macOS/BSD では動作せずホームにフォールバック）。

**制限事項**: 複数の SSH セッションが同時に存在する場合、正確に「このタブの」CWD を特定することは困難。最も新しいシェルプロセスの CWD を使う。

---

## 問題 3: タブを左右スワイプで切り替えたい

### 根本原因

現在 `body` は `IndexedStack` で実装されており、スワイプジェスチャーに対応していない。タブの切り替えは AppBar 下部の `_TabStrip` をタップするしかない。

### 修正方針

`body` の `IndexedStack` を `GestureDetector` で包み、velocity ベースの水平スワイプでタブを切り替える。

---

## 問題 4: タブが 1 つだけのときタブ名が表示されない

### 根本原因

`appBar.bottom` は `sessions.length > 1` の条件で `_TabStrip` を表示しているため、タブが 1 つの場合はタブ名が見えない。

---

## 問題 5: tmux リストから新セッションを開くとカーソルが元のタブに残る

### 根本原因

`_TerminalTabContent.didUpdateWidget` で `widget.isActive && !oldWidget.isActive` のときに `_focusNode.requestFocus()` を呼んでいるが、古いタブの `FocusNode` がまだフォーカスを保持しているため競合する。

---

## 問題 6: カーソル矢印キーの順序を ↑←→↓ にしたい

### 根本原因

`lib/widgets/quick_action_bar.dart` で矢印ボタンの順序が ↑↓←→ になっている。

---

## 問題 7: 複数タブ時にバックグラウンドで全接続がすぐ切れる

### 根本原因分析

dartssh2 の `keepAliveInterval: Duration(seconds: 10)` が問題。Android がバックグラウンドでメインイソレートの Dart タイマーを throttle すると、keepalive パケットの送信が遅延し、サーバーが接続を切る。複数タブは各々独立した SSH 接続を持つため、全接続が同時に死ぬ。

### 修正方針

- SSH keepAliveInterval を 10秒 → 30秒に（サーバーのタイムアウト範囲内で余裕を持たせる）
- フォアグラウンドサービスの repeat 間隔を 30秒 → 15秒に（メインイソレートをより頻繁に起こす）
- keepalive 受信時の処理を `checkConnection()`（重い probe）→ 軽量 `lightHealthCheck()`（isConnected フラグのみ）に変更

---

## 問題 8: スマホから画像ファイルをターミナルに貼りたい

### 技術的アプローチ

画像を base64 エンコードしてターミナルに heredoc で入力する。リモート側で `base64 -d` でデコードされファイルが作成される。5MB 制限・チャンク分割送信で PTY バッファ溢れを防止。

---

## Codex レビュー結果（反映済み）

Codex (gpt-5.3-codex) によるレビューで以下が指摘された（問題 1, 2 について）:

1. **`inactive` での過剰発火**: Drawer を閉じるトリガーは `paused` のみに限定すべき → 修正済み
2. **`Navigator.pop()` の安全性**: `isDrawerOpen` ガードに加えて `mounted` チェックも必要 → 修正済み
3. **CWD 取得の stale result**: 結果を適用する前に `_channelManager` が変わっていないかチェックすべき → 修正済み
4. **`/proc` は Linux best-effort**: macOS/BSD では動作しない → 明記済み
5. **全体評価**: 上記の調整を加えれば新たなバグなく修正可能

---

## 実装手順

### 手順 1: バックグラウンド移行時に Drawer を閉じる（問題 1）

ファイル: `lib/features/terminal/terminal_screen.dart`

`_TerminalScreenState` に `GlobalKey<ScaffoldState>` を追加し、`didChangeAppLifecycleState` でバックグラウンド移行時に Drawer を閉じる。

フィールド追加:
```dart
final _scaffoldKey = GlobalKey<ScaffoldState>();
```

`Scaffold` に key を設定:
```dart
return Scaffold(
  key: _scaffoldKey,
  backgroundColor: Colors.black,
  // ... 以下既存コード
```

`didChangeAppLifecycleState` を拡張（既存の `resumed` 処理の前に追加）:
```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.paused) {
    // バックグラウンド移行時に Drawer を閉じて黒画面を防止
    // inactive ではなく paused のみ（inactive はアプリスイッチャー等でも発火する）
    if (!mounted) return;
    final scaffoldState = _scaffoldKey.currentState;
    if (scaffoldState != null) {
      if (scaffoldState.isDrawerOpen || scaffoldState.isEndDrawerOpen) {
        Navigator.of(context).pop();
      }
    }
  }
  if (state == AppLifecycleState.resumed) {
    // フォアグラウンドサービスのおかげで通常は接続維持されているが、
    // 万一の切断に備えて短い遅延後にチェック
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      final managerState = ref.read(sessionManagerProvider);
      for (final session in managerState.sessions) {
        ref
            .read(terminalConnectionProvider(session.sessionId).notifier)
            .checkConnection();
      }
    });
  }
}
```

### 手順 2: SshChannelManager に CWD 取得メソッドを追加（問題 2）

ファイル: `lib/core/ssh/ssh_channel_manager.dart`

import 追加:
```dart
import 'dart:convert';
```

メソッド追加:
```dart
/// リモートシェルの推定カレントディレクトリを取得する。
/// /proc ファイルシステムを利用して PTY シェルの CWD を読み取る。
/// 取得できない場合は null を返す（macOS/BSD、権限不足等）。
Future<String?> getShellCwd() async {
  try {
    final session = await client.execute(
      r"readlink /proc/$(ps --no-headers -u $(whoami) -o pid,tty,comm "
      r"| grep 'pts/' | grep -E 'bash|zsh|fish|sh$' "
      r"| tail -1 | awk '{print $1}')/cwd 2>/dev/null",
    );
    final output = await session.stdout
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 5), onTimeout: () => '');
    final cwd = output.trim();
    if (cwd.isNotEmpty && cwd.startsWith('/')) {
      return cwd;
    }
  } catch (_) {
    // コマンド実行失敗 → null を返す
  }
  return null;
}
```

### 手順 3: FileBrowserNotifier に CWD ベースの初期化を追加（問題 2）

ファイル: `lib/features/file_browser/file_browser_provider.dart`

`navigateToInitialDirectory()` を変更:

変更前:
```dart
/// Navigates to the SSH login home directory (SFTP absolute path of '.').
/// Called when the file browser drawer is first opened so the user starts
/// in their home directory rather than the root.
Future<void> navigateToInitialDirectory() async {
  final sftp = _sftp;
  if (sftp == null) return;
  try {
    final home = await sftp.absolute('.');
    if (home.isNotEmpty) {
      await navigateTo(home);
    }
  } catch (_) {
    // If resolution fails, leave the current path unchanged.
  }
}
```

変更後:
```dart
/// Navigates to the terminal's current working directory if available,
/// otherwise falls back to the SSH login home directory.
/// Called when the file browser drawer is opened.
///
/// CWD 取得は Linux の /proc を利用した best-effort アプローチ。
/// macOS/BSD リモートホストや権限不足の場合はホームディレクトリにフォールバック。
Future<void> navigateToInitialDirectory() async {
  final sftp = _sftp;
  if (sftp == null) return;

  // まず PTY シェルの CWD を取得する（best-effort: Linux のみ）
  final channelManager = _channelManager;
  if (channelManager != null) {
    try {
      final cwd = await channelManager.getShellCwd();
      // getShellCwd() は非同期のため、結果が返る前に channelManager が
      // 差し替わっている可能性がある（再接続等）。stale result を無視する。
      if (cwd != null && cwd.isNotEmpty && _channelManager == channelManager) {
        await navigateTo(cwd);
        return;
      }
    } catch (_) {
      // CWD 取得失敗 → ホームディレクトリにフォールバック
    }
  }

  // フォールバック: ホームディレクトリ
  try {
    final home = await sftp.absolute('.');
    if (home.isNotEmpty) {
      await navigateTo(home);
    }
  } catch (_) {
    // If resolution fails, leave the current path unchanged.
  }
}
```

### 手順 4: スワイプでタブ切替を追加（問題 3）

ファイル: `lib/features/terminal/terminal_screen.dart`

`body:` セクションで `IndexedStack` を `GestureDetector` で包む:

変更前:
```dart
body: IndexedStack(
  index: activeIdx,
  children: sessions
      .map((s) => _TerminalTabContent(
            key: ValueKey(s.sessionId),
            sessionId: s.sessionId,
            connectionId: s.connectionId,
            isActive: s.sessionId == activeSession.sessionId,
            tmuxSessionName: s.tmuxSessionName,
          ))
      .toList(),
),
```

変更後:
```dart
body: GestureDetector(
  behavior: HitTestBehavior.translucent,
  onHorizontalDragEnd: sessions.length > 1
      ? (details) {
          final velocity = details.primaryVelocity ?? 0;
          if (velocity > 300) {
            // 右スワイプ → 前のタブ
            if (activeIdx > 0) {
              ref.read(sessionManagerProvider.notifier)
                  .setActiveSession(sessions[activeIdx - 1].sessionId);
            }
          } else if (velocity < -300) {
            // 左スワイプ → 次のタブ
            if (activeIdx < sessions.length - 1) {
              ref.read(sessionManagerProvider.notifier)
                  .setActiveSession(sessions[activeIdx + 1].sessionId);
            }
          }
        }
      : null,
  child: IndexedStack(
    index: activeIdx,
    children: sessions
        .map((s) => _TerminalTabContent(
              key: ValueKey(s.sessionId),
              sessionId: s.sessionId,
              connectionId: s.connectionId,
              isActive: s.sessionId == activeSession.sessionId,
              tmuxSessionName: s.tmuxSessionName,
            ))
        .toList(),
  ),
),
```

**注意**: `GestureDetector` と `TerminalView` のジェスチャーが競合する場合は、左右端に幅 20px の透明な `GestureDetector` を `Stack` で重ねるフォールバックアプローチに切り替える:

```dart
body: Stack(
  children: [
    IndexedStack(
      index: activeIdx,
      children: sessions.map((s) => _TerminalTabContent(...)).toList(),
    ),
    if (sessions.length > 1) ...[
      Positioned(
        left: 0, top: 0, bottom: 0, width: 20,
        child: GestureDetector(
          onHorizontalDragEnd: (details) {
            if ((details.primaryVelocity ?? 0) > 300 && activeIdx > 0) {
              ref.read(sessionManagerProvider.notifier)
                  .setActiveSession(sessions[activeIdx - 1].sessionId);
            }
          },
        ),
      ),
      Positioned(
        right: 0, top: 0, bottom: 0, width: 20,
        child: GestureDetector(
          onHorizontalDragEnd: (details) {
            if ((details.primaryVelocity ?? 0) < -300 && activeIdx < sessions.length - 1) {
              ref.read(sessionManagerProvider.notifier)
                  .setActiveSession(sessions[activeIdx + 1].sessionId);
            }
          },
        ),
      ),
    ],
  ],
),
```

### 手順 5: タブストリップを常時表示（問題 4）

ファイル: `lib/features/terminal/terminal_screen.dart`

変更前:
```dart
bottom: sessions.length > 1
    ? PreferredSize(
        preferredSize: const Size.fromHeight(36),
        child: _TabStrip(
          sessions: sessions,
          activeSessionId: activeSession.sessionId,
          onSelect: (id) => ref
              .read(sessionManagerProvider.notifier)
              .setActiveSession(id),
          onClose: (id) => ref
              .read(sessionManagerProvider.notifier)
              .removeSession(id),
        ),
      )
    : null,
```

変更後:
```dart
bottom: PreferredSize(
  preferredSize: const Size.fromHeight(36),
  child: _TabStrip(
    sessions: sessions,
    activeSessionId: activeSession.sessionId,
    onSelect: (id) => ref
        .read(sessionManagerProvider.notifier)
        .setActiveSession(id),
    onClose: (id) => ref
        .read(sessionManagerProvider.notifier)
        .removeSession(id),
  ),
),
```

### 手順 6: tmux 新タブ作成時にフォーカスを確実に移動（問題 5）

ファイル: `lib/features/terminal/terminal_screen.dart`

`_TerminalTabContentState.didUpdateWidget` で非アクティブになったタブの `FocusNode` から明示的に unfocus する:

変更前:
```dart
@override
void didUpdateWidget(covariant _TerminalTabContent oldWidget) {
  super.didUpdateWidget(oldWidget);
  // タブがアクティブになったらフォーカスを要求
  if (widget.isActive && !oldWidget.isActive) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isActive) {
        _focusNode.requestFocus();
      }
    });
  }
}
```

変更後:
```dart
@override
void didUpdateWidget(covariant _TerminalTabContent oldWidget) {
  super.didUpdateWidget(oldWidget);
  if (widget.isActive && !oldWidget.isActive) {
    // タブがアクティブになったらフォーカスを要求
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isActive) {
        _focusNode.requestFocus();
      }
    });
  } else if (!widget.isActive && oldWidget.isActive) {
    // タブが非アクティブになったらフォーカスを外す
    // これにより新しいアクティブタブの requestFocus() が確実に成功する
    _focusNode.unfocus();
  }
}
```

### 手順 7: 矢印キーの順序を ↑←→↓ に変更（問題 6）

ファイル: `lib/widgets/quick_action_bar.dart`

変更前（51〜66行目付近）:
```dart
_ActionButton(
  icon: Icons.arrow_upward,
  onPressed: () => onKeyPressed(TerminalKey.arrowUp),
),
_ActionButton(
  icon: Icons.arrow_downward,
  onPressed: () => onKeyPressed(TerminalKey.arrowDown),
),
_ActionButton(
  icon: Icons.arrow_back,
  onPressed: () => onKeyPressed(TerminalKey.arrowLeft),
),
_ActionButton(
  icon: Icons.arrow_forward,
  onPressed: () => onKeyPressed(TerminalKey.arrowRight),
),
```

変更後:
```dart
_ActionButton(
  icon: Icons.arrow_upward,
  onPressed: () => onKeyPressed(TerminalKey.arrowUp),
),
_ActionButton(
  icon: Icons.arrow_back,
  onPressed: () => onKeyPressed(TerminalKey.arrowLeft),
),
_ActionButton(
  icon: Icons.arrow_forward,
  onPressed: () => onKeyPressed(TerminalKey.arrowRight),
),
_ActionButton(
  icon: Icons.arrow_downward,
  onPressed: () => onKeyPressed(TerminalKey.arrowDown),
),
```

### 手順 8: バックグラウンド接続維持の強化（問題 7）

#### 8a: keepAliveInterval を 30 秒に変更

ファイル: `lib/core/ssh/ssh_client_service.dart`

変更前:
```dart
keepAliveInterval: const Duration(seconds: 10),
```

変更後:
```dart
keepAliveInterval: const Duration(seconds: 30),
```

#### 8b: フォアグラウンドサービスの repeat 間隔を 15 秒に短縮

ファイル: `lib/core/background/ssh_foreground_service.dart`

変更前:
```dart
eventAction: ForegroundTaskEventAction.repeat(30000),
```

変更後:
```dart
eventAction: ForegroundTaskEventAction.repeat(15000),
```

#### 8c: keepalive 受信時の処理を軽量化

ファイル: `lib/features/terminal/terminal_connection_provider.dart`

`_periodicHealthCheck()` を public `lightHealthCheck()` にリネーム:

変更前:
```dart
void _periodicHealthCheck() {
  // 接続中でなければ何もしない
  if (state.status != ConnectionStatus.connected) return;
  // isConnected が false なら切断を検知
  if (_sshService == null || !_sshService!.isConnected) {
    _onDisconnected();
  }
}
```

変更後:
```dart
/// 軽量ヘルスチェック。isConnected フラグのみで判定し、
/// probe() のような重い操作は行わない。
/// フォアグラウンドサービスの keepalive 受信時に呼ばれる。
void lightHealthCheck() {
  // 接続中でなければ何もしない
  if (state.status != ConnectionStatus.connected) return;
  // isConnected が false なら切断を検知
  if (_sshService == null || !_sshService!.isConnected) {
    _onDisconnected();
  }
}
```

`_startHealthCheck()` の呼び出しも更新:

変更前:
```dart
void _startHealthCheck() {
  _healthCheckTimer?.cancel();
  _healthCheckTimer = Timer.periodic(const Duration(seconds: 30), (_) {
    _periodicHealthCheck();
  });
}
```

変更後:
```dart
void _startHealthCheck() {
  _healthCheckTimer?.cancel();
  _healthCheckTimer = Timer.periodic(const Duration(seconds: 30), (_) {
    lightHealthCheck();
  });
}
```

ファイル: `lib/features/terminal/terminal_screen.dart`

`_onTaskData` を軽量化:

変更前:
```dart
void _onTaskData(Object data) {
  if (data == 'keepalive' && mounted) {
    // 全セッションのヘルスチェックを実行
    final managerState = ref.read(sessionManagerProvider);
    for (final session in managerState.sessions) {
      ref
          .read(terminalConnectionProvider(session.sessionId).notifier)
          .checkConnection();
    }
  }
}
```

変更後:
```dart
void _onTaskData(Object data) {
  if (data == 'keepalive' && mounted) {
    // 全セッションの軽量ヘルスチェックを実行
    // checkConnection() は probe() で重いため、バックグラウンドでは
    // isConnected フラグのみで判定する lightHealthCheck() を使う
    final managerState = ref.read(sessionManagerProvider);
    for (final session in managerState.sessions) {
      ref
          .read(terminalConnectionProvider(session.sessionId).notifier)
          .lightHealthCheck();
    }
  }
}
```

### 手順 9: 画像貼り付け機能を追加（問題 8）

#### 9a: QuickActionBar に画像ボタンを追加

ファイル: `lib/widgets/quick_action_bar.dart`

コンストラクタに `onImagePaste` を追加:
```dart
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

`build()` 内の `/` `-` `|` ボタンの前に画像ボタンを追加:
```dart
if (onImagePaste != null) ...[
  const SizedBox(width: 8),
  _ActionButton(
    icon: Icons.image,
    onPressed: onImagePaste!,
  ),
],
```

#### 9b: _TerminalTabContent に画像貼付ロジックを追加

ファイル: `lib/features/terminal/terminal_screen.dart`

import 追加:
```dart
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
```

**注意**: `dart:io` と `file_picker` が既に import 済みの場合は追加不要。`dart:convert` も他の場所で使われていれば不要。重複 import にならないよう確認すること。

`_TerminalTabContentState` にメソッド追加:
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

  // 5MB 制限
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
  // base64 データを分割送信（一度に大量のデータを送ると PTY バッファが溢れる）
  const chunkSize = 4096;
  for (var i = 0; i < base64Data.length; i += chunkSize) {
    final end = (i + chunkSize).clamp(0, base64Data.length);
    terminal.textInput(base64Data.substring(i, end));
    // チャンク間で短いディレイを入れて PTY バッファを消化させる
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

`build()` 内の `QuickActionBar` に `onImagePaste` を渡す:

変更前:
```dart
QuickActionBar(
  onKeyPressed: (key, {bool ctrl = false}) {
    connectionState.terminal?.keyInput(key, ctrl: ctrl);
  },
  onTextInput: (text) {
    connectionState.terminal?.textInput(text);
  },
),
```

変更後:
```dart
QuickActionBar(
  onKeyPressed: (key, {bool ctrl = false}) {
    connectionState.terminal?.keyInput(key, ctrl: ctrl);
  },
  onTextInput: (text) {
    connectionState.terminal?.textInput(text);
  },
  onImagePaste: connectionState.terminal != null ? _pasteImage : null,
),
```

### 手順 10: テスト確認・修正

既存テストへの影響:
- `_scaffoldKey` の追加は既存テストに影響なし
- `getShellCwd()` は新規メソッドなので既存テストに影響なし
- `_TabStrip` の表示条件変更: `sessions.length == 1` のテストがあれば `_TabStrip` が表示されることを期待するよう更新
- `GestureDetector` の追加: `find.byType(IndexedStack)` 等のテストがあれば調整
- `_periodicHealthCheck()` → `lightHealthCheck()` リネーム: private メソッドのためテスト影響なし
- `QuickActionBar` に `onImagePaste` 追加: optional パラメータのため既存テスト影響なし
- 矢印順序変更: QuickActionBar テストで矢印の並び順をチェックしている箇所があれば更新

## 実装順序

1. `lib/widgets/quick_action_bar.dart`:
   - 矢印ボタンの順序を ↑←→↓ に変更
   - `onImagePaste` パラメータと画像ボタンを追加
2. `lib/core/ssh/ssh_client_service.dart`:
   - `keepAliveInterval` を 30 秒に変更
3. `lib/core/background/ssh_foreground_service.dart`:
   - `repeat(30000)` → `repeat(15000)` に変更
4. `lib/core/ssh/ssh_channel_manager.dart`:
   - `dart:convert` import 追加
   - `getShellCwd()` メソッド追加
5. `lib/features/terminal/terminal_connection_provider.dart`:
   - `_periodicHealthCheck()` → `lightHealthCheck()` にリネーム（public 化）
   - `_startHealthCheck()` 内の呼び出しを更新
6. `lib/features/file_browser/file_browser_provider.dart`:
   - `navigateToInitialDirectory()` を CWD 優先に変更
7. `lib/features/terminal/terminal_screen.dart`:
   - `_scaffoldKey` フィールド追加、`Scaffold` に key 設定
   - `didChangeAppLifecycleState` でバックグラウンド時に Drawer を閉じる
   - `_onTaskData` で `lightHealthCheck()` を呼ぶよう変更
   - `appBar.bottom` の `sessions.length > 1` 条件を削除（常時表示）
   - `body` を `GestureDetector` で包んでスワイプ切替を追加
   - `didUpdateWidget` に非アクティブ時の `unfocus()` を追加
   - `_pasteImage()` メソッド追加
   - `QuickActionBar` に `onImagePaste` を渡す
   - 必要な import 追加（`dart:convert`, `dart:io`, `file_picker`）
8. テスト確認・修正
9. `~/flutter/bin/flutter analyze`
10. `~/flutter/bin/flutter test`
11. `~/flutter/bin/flutter build apk --debug`
