---
goal: "Phase 38 - 診断ログ（設定画面で閲覧可能）+ tmux タブ自動リアタッチ + シームレス再接続"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 38: 診断ログ + tmux タブ自動リアタッチ + シームレス再接続

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題

1. バックグラウンド復帰時に接続が切れ、**セッションが失われる**
2. 切断の原因が不明 — ログがなく追跡できない。ログを見る手段もアプリ内にない
3. 再接続時に赤い「Connection lost」バナーが表示されて UX が悪い
4. tmux ドロワーから開いたタブが再接続しても、tmux セッションにリアタッチしない

## 修正方針

### A) アプリ内診断ログ

- リングバッファ（最新 500 件）にログを蓄積する `AppLogger` シングルトンを作成
- `debugPrint` に加えて `AppLogger.log()` で記録
- 設定画面に「Connection Log」項目を追加 → タップで全ログ表示 + コピーボタン

### B) tmux タブの自動リアタッチ

- `TerminalSession.tmuxSessionName` が設定されているタブ（tmux ドロワーから開いたタブ）が再接続した場合
- 再接続後に自動で `tmux attach -t <name>` を送信してセッション復帰
- 通常タブ（tmuxSessionName == null）では何もしない

### C) シームレス再接続

- `_onDisconnected()` で即座に `disconnected`（赤バナー）にせず、`reconnecting`（スピナーのみ）に遷移
- 再接続失敗時のみ赤バナーを表示

---

## 実装手順

### ステップ 1: AppLogger シングルトンの作成

**新規ファイル:** `lib/core/utils/app_logger.dart`

```dart
// BEFORE: このファイルは存在しない

// AFTER:
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// アプリ内診断ログ。リングバッファに最新のログを保持する。
/// 設定画面から閲覧・コピー可能。
class AppLogger {
  AppLogger._();
  static final AppLogger instance = AppLogger._();

  static const int maxEntries = 500;
  final _entries = Queue<LogEntry>();

  List<LogEntry> get entries => List.unmodifiable(_entries);

  /// ログを追加する。[debugPrint] にも出力する。
  void log(String message) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      message: message,
    );
    _entries.addLast(entry);
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
    debugPrint(message);
  }

  /// 全ログをテキストとして取得する。
  String toText() {
    final buffer = StringBuffer();
    for (final entry in _entries) {
      buffer.writeln(
        '${entry.timestamp.toIso8601String()} ${entry.message}',
      );
    }
    return buffer.toString();
  }

  void clear() => _entries.clear();
}

class LogEntry {
  const LogEntry({required this.timestamp, required this.message});
  final DateTime timestamp;
  final String message;
}
```

---

### ステップ 2: 主要ポイントにログを追加

全てのログは `AppLogger.instance.log(...)` を使う。
`debugPrint` は `AppLogger.log` 内で自動的に呼ばれるので二重呼び出ししないこと。

**ファイル:** `lib/features/terminal/terminal_screen.dart`

import 追加:

```dart
// BEFORE:
import '../../widgets/terminal_selection_toolbar.dart';

// AFTER:
import '../../core/utils/app_logger.dart';
import '../../widgets/terminal_selection_toolbar.dart';
```

```dart
// BEFORE (_onTaskData):
  void _onTaskData(Object data) {
    if (data == 'keepalive' && mounted) {
      final managerState = ref.read(sessionManagerProvider);
      for (final session in managerState.sessions) {
        ref
            .read(terminalConnectionProvider(session.sessionId).notifier)
            .activeKeepAlive();
      }
    }
  }

// AFTER:
  void _onTaskData(Object data) {
    if (data == 'keepalive' && mounted) {
      AppLogger.instance.log('[SSH] keepalive tick from service');
      final managerState = ref.read(sessionManagerProvider);
      for (final session in managerState.sessions) {
        ref
            .read(terminalConnectionProvider(session.sessionId).notifier)
            .activeKeepAlive();
      }
    }
  }
```

---

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

import 追加:

```dart
// BEFORE:
import '../../core/ssh/ssh_client_service.dart';

// AFTER:
import '../../core/ssh/ssh_client_service.dart';
import '../../core/utils/app_logger.dart';
```

以下の箇所に `AppLogger.instance.log(...)` を追加する。
既存の `debugPrint` がある場合は置き換える（`AppLogger.log` 内で `debugPrint` が呼ばれるため）。

client.done リスナー:

```dart
// BEFORE:
    _doneSubscription = client.done.asStream().listen((_) {
      if (_sshService?.client == currentClient) {
        _onDisconnected();
      }
    });

// AFTER:
    _doneSubscription = client.done.asStream().listen((_) {
      if (_sshService?.client == currentClient) {
        AppLogger.instance.log('[SSH][$arg] client.done fired');
        _onDisconnected();
      }
    });
```

connect 成功時:

```dart
// BEFORE (connect 内、_startHealthCheck() の後):
      _startHealthCheck();

// AFTER:
      _startHealthCheck();
      AppLogger.instance.log('[SSH][$arg] connected');
```

connect 失敗時:

```dart
// BEFORE (connect 内、catch ブロック):
      _cleanupConnections(); // SSH クライアントとチャネルを確実に解放
      state = state.copyWith(

// AFTER:
      _cleanupConnections();
      AppLogger.instance.log('[SSH][$arg] connect failed: $e');
      state = state.copyWith(
```

activeKeepAlive 結果:

```dart
// BEFORE (_activeKeepAliveCore 内):
      final alive = await service.keepAlive();
      // await 中にサービスが差し替わった場合はタイムスタンプを更新しない
      if (alive && identical(service, _sshService) &&
          state.status == ConnectionStatus.connected) {
        _lastAliveConfirmed = DateTime.now();
        _keepAliveFailCount = 0;
      } else if (!alive && identical(service, _sshService)) {

// AFTER:
      final alive = await service.keepAlive();
      if (alive && identical(service, _sshService) &&
          state.status == ConnectionStatus.connected) {
        _lastAliveConfirmed = DateTime.now();
        _keepAliveFailCount = 0;
      } else if (!alive && identical(service, _sshService)) {
        AppLogger.instance.log('[SSH][$arg] keepalive FAILED (${_keepAliveFailCount + 1})');
```

reconnect 成功/失敗:

```dart
// BEFORE (reconnect 成功時):
      if (existingTerminal != null) {
        terminal.write('\r\n\x1B[33m--- Reconnected ---\x1B[0m\r\n');
      }

// AFTER:
      AppLogger.instance.log('[SSH][$arg] reconnect succeeded');
      if (existingTerminal != null) {
        terminal.write('\r\n\x1B[33m--- Reconnected ---\x1B[0m\r\n');
      }
```

```dart
// BEFORE (reconnect 失敗時):
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        terminal: existingTerminal,
        errorMessage: e.toString(),
        clearChannelManager: true,
      );

// AFTER:
      AppLogger.instance.log('[SSH][$arg] reconnect failed: $e');
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        terminal: existingTerminal,
        errorMessage: e.toString(),
        clearChannelManager: true,
      );
```

---

**ファイル:** `lib/core/ssh/keepalive_ssh_socket.dart`

import 追加:

```dart
// BEFORE:
import 'package:dartssh2/dartssh2.dart';

// AFTER:
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
```

```dart
// BEFORE:
    } catch (_) {
      // プラットフォームが raw socket option をサポートしない場合は無視
      // （SSH レベルの keepalive がフォールバックとして動作する）
    }

// AFTER:
      debugPrint('[SSH] TCP keepalive configured OK');
    } catch (e) {
      debugPrint('[SSH] TCP keepalive setup FAILED: $e');
    }
```

---

### ステップ 3: 設定画面にログ閲覧機能を追加

**ファイル:** `lib/features/settings/settings_screen.dart`

import 追加:

```dart
// BEFORE:
import 'package:flutter/material.dart';

// AFTER:
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/utils/app_logger.dart';
```

ログ項目を About セクションの前に追加:

```dart
// BEFORE:
          const Divider(),

          // About section
          const _SectionHeader(title: 'About'),

// AFTER:
          const Divider(),

          // Diagnostics section
          const _SectionHeader(title: 'Diagnostics'),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Connection Log'),
            subtitle: const Text('View SSH connection diagnostics'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ConnectionLogScreen(),
                ),
              );
            },
          ),

          const Divider(),

          // About section
          const _SectionHeader(title: 'About'),
```

ログ閲覧画面を同ファイルの末尾に追加:

```dart
// BEFORE: ファイル末尾（_Section クラスの閉じ括弧の後）

// AFTER: _Section クラスの後に追加

// ---------------------------------------------------------------------------
// Connection Log Screen
// ---------------------------------------------------------------------------

class ConnectionLogScreen extends StatelessWidget {
  const ConnectionLogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final logger = AppLogger.instance;
    final entries = logger.entries;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connection Log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy all logs',
            onPressed: () {
              final text = logger.toText();
              if (text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('No logs to copy')),
                );
                return;
              }
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Copied ${entries.length} log entries'),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear logs',
            onPressed: () {
              logger.clear();
              // rebuild
              (context as Element).markNeedsBuild();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Logs cleared')),
              );
            },
          ),
        ],
      ),
      body: entries.isEmpty
          ? const Center(
              child: Text(
                'No logs yet.\nConnect to an SSH server to see diagnostics.',
                textAlign: TextAlign.center,
              ),
            )
          : ListView.builder(
              reverse: true,
              itemCount: entries.length,
              itemBuilder: (context, index) {
                // reverse: true なので最新が上に来る
                final entry = entries[entries.length - 1 - index];
                final time =
                    '${entry.timestamp.hour.toString().padLeft(2, '0')}:'
                    '${entry.timestamp.minute.toString().padLeft(2, '0')}:'
                    '${entry.timestamp.second.toString().padLeft(2, '0')}';
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                  child: Text(
                    '$time ${entry.message}',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                );
              },
            ),
    );
  }
}
```

---

### ステップ 4: シームレス再接続（_onDisconnected 改善）

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

`_onDisconnected` を `reconnecting` に直接遷移させ、即座に再接続を試みる。

```dart
// BEFORE:
  void _onDisconnected() {
    // 再接続中なら無視（reconnect() が完了を処理する）
    if (state.status == ConnectionStatus.reconnecting) return;
    // 既に切断状態なら無視
    if (state.status == ConnectionStatus.disconnected) return;
    _lastAliveConfirmed = null;
    _keepAliveFailCount = 0;
    state = state.copyWith(
      status: ConnectionStatus.disconnected,
      errorMessage: 'Connection lost',
      clearChannelManager: true,
    );
    // 一時的なネットワーク不安定で PTY セッションを無駄に破棄しないよう、
    // 2 秒遅延してから接続状態を再確認して reconnect する。
    if (_config != null) {
      Future.delayed(const Duration(seconds: 2), () {
        // 遅延中に既に reconnect/connect が始まっていたら何もしない
        if (state.status == ConnectionStatus.reconnecting ||
            state.status == ConnectionStatus.connecting ||
            state.status == ConnectionStatus.connected) {
          return;
        }
        reconnect();
      });
    }
  }

// AFTER:
  void _onDisconnected() {
    if (state.status == ConnectionStatus.reconnecting) return;
    if (state.status == ConnectionStatus.disconnected) return;
    if (state.status == ConnectionStatus.connecting) return;
    AppLogger.instance.log('[SSH][$arg] disconnected, attempting silent reconnect');
    _lastAliveConfirmed = null;
    _keepAliveFailCount = 0;
    if (_config != null) {
      _silentReconnect();
    } else {
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        errorMessage: 'Connection lost',
        clearChannelManager: true,
      );
    }
  }

  /// 赤バナーを出さずに即座に再接続を試みる。
  /// reconnecting 状態に遷移してスピナーのみ表示。
  /// 失敗した場合のみ disconnected + エラーバナーを表示する。
  Future<void> _silentReconnect() async {
    if (_config == null) return;
    if (state.status == ConnectionStatus.reconnecting ||
        state.status == ConnectionStatus.connecting ||
        state.status == ConnectionStatus.connected) {
      return;
    }

    final existingTerminal = state.terminal;
    state = state.copyWith(
      status: ConnectionStatus.reconnecting,
      clearChannelManager: true,
    );

    _cleanupConnections();
    await Future.delayed(const Duration(milliseconds: 500));

    try {
      final terminal = await _connectCore(
        config: _config!,
        password: _password,
        privateKeyPem: _privateKeyPem,
        passphrase: _passphrase,
        existingTerminal: existingTerminal,
      );
      AppLogger.instance.log('[SSH][$arg] silent reconnect succeeded');
      if (existingTerminal != null) {
        terminal.write('\r\n\x1B[33m--- Reconnected ---\x1B[0m\r\n');
      }
      _retryCount = 0;
      _lastReconnectAttempt = null;
      _lastAliveConfirmed = DateTime.now();
      _keepAliveFailCount = 0;
      state = state.copyWith(
        status: ConnectionStatus.connected,
        terminal: terminal,
        channelManager: _channelManager,
      );
      _startHealthCheck();
      // tmux タブの場合は自動リアタッチ
      _autoReattachTmux(terminal);
    } catch (e) {
      AppLogger.instance.log('[SSH][$arg] silent reconnect failed: $e');
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        terminal: existingTerminal,
        errorMessage: e.toString(),
        clearChannelManager: true,
      );
      if (_retryCount < _maxRetries) {
        _retryCount++;
        final delay = Duration(seconds: 1 << _retryCount);
        _retryTimer?.cancel();
        _retryTimer = Timer(delay, () {
          reconnect(isAutoRetry: true);
        });
      }
    }
  }
```

activeKeepAlive の連続失敗時にも _silentReconnect を使う:

```dart
// BEFORE:
        _keepAliveFailCount++;
        if (_keepAliveFailCount >= 3) {
          _keepAliveFailCount = 0;
          _onDisconnected();
        }

// AFTER:
        _keepAliveFailCount++;
        if (_keepAliveFailCount >= 3) {
          _keepAliveFailCount = 0;
          AppLogger.instance.log('[SSH][$arg] keepalive failed 3 times, silent reconnect');
          _silentReconnect();
        }
```

checkConnection 内のゾンビ接続処理:

```dart
// BEFORE:
      // ゾンビ接続: state を disconnected に変更してから reconnect
      // （reconnect() は disconnected 状態でないと実行しないため）
      _cleanupConnections();
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        errorMessage: 'Connection lost',
        clearChannelManager: true,
      );
      await reconnect();

// AFTER:
      AppLogger.instance.log('[SSH][$arg] zombie connection, silent reconnect');
      await _silentReconnect();
```

---

### ステップ 5: tmux タブの自動リアタッチ

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

tmux セッション名を保持するフィールドと、リアタッチメソッドを追加する。

フィールド追加:

```dart
// BEFORE:
  bool _isActiveKeepAliveRunning = false;
  int _keepAliveFailCount = 0;

// AFTER:
  bool _isActiveKeepAliveRunning = false;
  int _keepAliveFailCount = 0;
  String? _tmuxSessionName;
```

connect に tmuxSessionName パラメータを追加:

```dart
// BEFORE:
  Future<void> connect({
    required ConnectionConfig config,
    String? password,
    String? privateKeyPem,
    String? passphrase,
  }) async {

// AFTER:
  Future<void> connect({
    required ConnectionConfig config,
    String? password,
    String? privateKeyPem,
    String? passphrase,
    String? tmuxSessionName,
  }) async {
```

connect の冒頭で保存:

```dart
// BEFORE:
    _config = config;
    _password = password;

// AFTER:
    _tmuxSessionName = tmuxSessionName;
    _config = config;
    _password = password;
```

自動リアタッチメソッド（`_silentReconnect` の後に追加）:

```dart
// BEFORE:
  void _startHealthCheck() {

// AFTER:
  /// tmux タブの場合、再接続後に自動で tmux セッションにリアタッチする。
  void _autoReattachTmux(Terminal terminal) {
    if (_tmuxSessionName == null) return;
    AppLogger.instance.log('[SSH][$arg] auto-reattach tmux: $_tmuxSessionName');
    final escaped = _tmuxSessionName!.replaceAll("'", r"'\''");
    // 少し待ってからアタッチ（シェルの起動を待つ）
    Future.delayed(const Duration(milliseconds: 500), () {
      terminal.textInput("tmux attach -t '$escaped'\r");
    });
  }

  void _startHealthCheck() {
```

reconnect の成功時にもリアタッチを追加:

```dart
// BEFORE (reconnect 成功時、_startHealthCheck の後):
      _startHealthCheck();

// AFTER:
      _startHealthCheck();
      // tmux タブの場合は自動リアタッチ
      _autoReattachTmux(terminal);
```

---

### ステップ 6: terminal_screen.dart から tmuxSessionName を渡す

**ファイル:** `lib/features/terminal/terminal_screen.dart`

`_startConnection` 内の `connect()` 呼び出しに `tmuxSessionName` を渡す。
また、手動 tmux attach のコードは `tmuxSessionName` が設定されていても
`connect` に渡すので不要になるが、**初回接続時に tmux attach が必要**なので維持する。
ただし、reconnect 時のリアタッチは provider 側で処理するので、
terminal_screen.dart の手動 attach は初回接続のみ。

```dart
// BEFORE:
    await ref
        .read(terminalConnectionProvider(widget.sessionId).notifier)
        .connect(
          config: config,
          password: password,
          privateKeyPem: privateKeyPem,
          passphrase: passphrase,
        );

// AFTER:
    await ref
        .read(terminalConnectionProvider(widget.sessionId).notifier)
        .connect(
          config: config,
          password: password,
          privateKeyPem: privateKeyPem,
          passphrase: passphrase,
          tmuxSessionName: widget.tmuxSessionName,
        );
```

checkConnection の遅延を 500ms → 1500ms に調整:

```dart
// BEFORE:
      Future.delayed(const Duration(milliseconds: 500), () {

// AFTER:
      Future.delayed(const Duration(milliseconds: 1500), () {
```

---

## 変更ファイル一覧

| ファイル | 変更内容 |
|---------|---------|
| `lib/core/utils/app_logger.dart` | **新規作成** — リングバッファ式ログ |
| `lib/features/terminal/terminal_connection_provider.dart` | ログ追加、`_silentReconnect`、`_autoReattachTmux`、`tmuxSessionName` パラメータ |
| `lib/features/terminal/terminal_screen.dart` | ログ追加、`tmuxSessionName` 渡し、checkConnection 遅延調整 |
| `lib/features/settings/settings_screen.dart` | Diagnostics セクション + `ConnectionLogScreen` 追加 |
| `lib/core/ssh/keepalive_ssh_socket.dart` | TCP keepalive ログ + import 追加 |

---

## 検証項目

1. `~/flutter/bin/flutter analyze` — 静的解析エラーなし
2. `~/flutter/bin/flutter test` — 全テスト通過
3. `~/flutter/bin/flutter build apk --debug` — デバッグビルド成功
4. **手動テスト（デバイス）:**
   - 設定画面に「Connection Log」が表示される
   - SSH 接続後、ログ画面に接続成功ログが表示される
   - ログのコピーボタンでクリップボードにコピーされる
   - tmux ドロワーからセッションを開く → バックグラウンド → 復帰 → 自動で tmux セッションにリアタッチ
   - 通常タブ（tmux 以外）では tmux リアタッチしない
   - 復帰時に赤バナーではなくスピナーのみ表示 → 再接続後に消える
   - 再接続失敗時のみ赤バナー表示

---

## 技術的補足

### tmux リアタッチのフロー

```
tmux ドロワーから「my-session」を選択
  ↓
addTmuxSession(tmuxSessionName: 'my-session') → 新タブ作成
  ↓
connect(tmuxSessionName: 'my-session') → _tmuxSessionName を保存
  ↓
初回接続: terminal_screen.dart の既存コードが tmux attach -t 'my-session' を送信
  ↓
バックグラウンドで接続切断
  ↓
client.done 発火 → _onDisconnected → _silentReconnect
  ↓
state = reconnecting（スピナーのみ、赤バナーなし）
  ↓
新しい SSH 接続を確立 → _autoReattachTmux
  ↓
tmux attach -t 'my-session' → tmux セッション内のプロセス/状態が復元！
```

### AppLogger の設計

- **リングバッファ（500 件）**: メモリ消費を抑えつつ十分な履歴を保持
- **`debugPrint` と連携**: `AppLogger.log()` 内で `debugPrint` も呼ぶので `adb logcat` でも見える
- **シングルトン**: アプリ全体で 1 インスタンス。provider 不要でどこからでもアクセス可能
- **コピー機能**: 設定画面からワンタップで全ログをクリップボードにコピー → 開発者に送信可能
