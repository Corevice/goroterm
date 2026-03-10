---
goal: "Phase 22 - 矢印長押しリピート + tmuxフォーカス修正 + バックグラウンド接続強化 + 切断時タブクリーンアップ + タブ別CWD"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 22: UX + 安定性改善

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題 1: 矢印ボタンの長押しで連続入力

### 根本原因

`_ActionButton` は `InkWell` の `onTap` のみを使っているため、1回のタップで1回しか入力されない。矢印キーは長押しで連続入力できるのが自然。

### 修正方針

矢印ボタン専用の `_RepeatableActionButton` ウィジェットを作成する。`GestureDetector` の `onLongPressStart` / `onLongPressEnd` を使い、長押し中は `Timer.periodic` で繰り返し `onPressed` を発火する。

リピート間隔は初回 300ms 遅延後、50ms 間隔（キーボードのリピートレートに近い）。

---

## 問題 2: tmux セッションを開いた後のカーソル（フォーカス）問題

### 根本原因分析

Phase 19 で `didUpdateWidget` に `unfocus()` を追加したが、tmux セッションを開く流れは:

1. `_attachTmuxSession()` → `addTmuxSession()` で新タブ作成 → `activeSessionId` 更新
2. `IndexedStack` の子に新しい `_TerminalTabContent` が追加される
3. **新しいタブはまだ `initState` 段階で `_startConnection()` を実行中**
4. `_startConnection()` が async で接続完了を待つ間、古いタブの `didUpdateWidget` が呼ばれ `unfocus()` する
5. しかし新タブの `_focusNode` はまだ作成直後で、`TerminalView` がまだ構築されていない
6. 新タブの `didUpdateWidget` で `requestFocus()` が呼ばれるが、`TerminalView` が存在しないため Focus ツリーに参加できていない
7. 結果、**どのタブもフォーカスを持たない状態**になり、ユーザーの入力はフォーカスが最後にあった場所（古いタブ）に残る

さらに、`addTmuxSession` で作成されたタブは `_startConnection()` → `connect()` → 500ms 遅延 → `tmux attach` と順番に実行されるため、**接続完了後に改めてフォーカスを要求する必要がある**。

### 修正方針

`_TerminalTabContentState._startConnection()` の最後に、接続完了後にフォーカスを要求するコードを追加する。これにより `TerminalView` が構築された後に確実にフォーカスが移動する。

---

## 問題 3: バックグラウンドでの接続切断をさらに減らす

### 現状の対策（Phase 18, 19 で実施済み）

- `keepAliveInterval: 30s`（dartssh2）
- フォアグラウンドサービス repeat: 15秒
- `lightHealthCheck()`: `isConnected` フラグチェック
- `_onDisconnected()` で即時 `reconnect()`
- バッテリー最適化の無効化リクエスト

### まだ切れる原因の分析

1. **Android の Doze モード**: バッテリー最適化を無効化しても、画面消灯後しばらくすると Android の Doze モードに入り、ネットワーク接続が制限される。フォアグラウンドサービスがあっても WiFi 接続が throttle される場合がある。
2. **フォアグラウンドサービスの `allowWifiLock: true`** は設定済みだが、WiFi lock は画面消灯時の WiFi 切断を防ぐだけで Doze による制限は防げない。
3. **`keepAliveInterval: 30s`**: 30秒はサーバーのデフォルト `ClientAliveInterval` (通常15〜30s) × `ClientAliveCountMax` (通常3) = 45〜90秒のタイムアウトに対して余裕があるが、Dart タイマーが Doze で大幅に遅延すると（数分単位で）keepalive が間に合わない。

### 追加修正

#### 3a. `WifiLock` を明示的に取得

`flutter_foreground_task` の `allowWifiLock: true` は WiFi lock を有効にするが、これはサービスイソレート側の設定。メインイソレート側で追加の WiFi lock を取得するため、`wakelock_plus` パッケージを使って画面消灯時もプロセッサを起こし続ける。

ただし `wakelock_plus` は画面を点灯し続ける（不要）。代わりに `flutter_foreground_task` の `allowWakeLock: true`（既に設定済み）で十分。

**実際に効果がある追加対策**: フォアグラウンドサービスの通知優先度を上げる。`NotificationChannelImportance.LOW` → `NotificationChannelImportance.DEFAULT` に変更。LOW だと Android がサービスを低優先として扱い、リソース回収の対象になりやすい。

#### 3b. keepAliveInterval を 15 秒に戻す

30 秒だとサーバー側のタイムアウトギリギリの場合がある。15 秒に戻し、フォアグラウンドサービスの 15 秒 repeat でタイマーが確実に発火するようにする。

#### 3c. フォアグラウンドサービスの repeat 間隔を 10 秒に短縮

15 秒 → 10 秒に短縮し、メインイソレートをより頻繁に起こす。10 秒は keepAliveInterval と同じなので、毎回の keepalive 発火タイミングに間に合う。

#### 3d. `_onTaskData` で SSH keepalive を能動的にトリガー

現在 `_onTaskData` は `lightHealthCheck()`（`isConnected` フラグチェックのみ）を呼ぶが、これはパッシブチェック。能動的に SSH 接続を維持するため、dartssh2 の `SSHClient` に対してデータ送信を行う。

dartssh2 の `SSHClient` は `keepAliveInterval` で自動的に keepalive を送信するが、Dart タイマーが throttle されると遅延する。フォアグラウンドサービスのイベントで `_onTaskData` が呼ばれた際に、**`SSHClient.sendIgnore()`** を呼んで明示的に SSH_MSG_IGNORE パケットを送信する。これによりサーバーに「生きている」ことを通知する。

ただし dartssh2 の `SSHClient` に `sendIgnore()` のような API があるか確認が必要。ない場合は、`probe()`（`echo ok` exec）は重すぎるので、代わりに軽量な exec チャネルを開いて即閉じるなどのアプローチを検討する。

**実装方針**: `SshClientService` に `keepAlive()` メソッドを追加。内部で `client.execute('true')` を実行して即座に完了する（`true` コマンドは何もしないで成功する最軽量コマンド）。タイムアウト付き。失敗したら `_onDisconnected()` を呼ぶ。

---

## 問題 4: 全接続切断時にタブをクリーンアップして次回新規タブを開く

### 修正方針

フォアグラウンド復帰時に `checkConnection()` を呼んだ後、一定時間後にまだ全セッションが `disconnected` なら全タブを閉じる。`sessions.isEmpty` になると `TerminalScreen` は `Navigator.pop()` で接続一覧に戻る。次回タップで新規タブが開く。

ただし、自動再接続（`reconnect()` のリトライ）がまだ進行中の場合は待つ必要がある。`reconnecting` 状態のセッションがあれば待機し、全セッションが `disconnected`（リトライも全て失敗）になって初めてクリーンアップする。

---

## 問題 5: ファイル一覧が今開いているタブの CWD で開かれない（タブごとの CWD 取得）

### 根本原因

現在の `getShellCwd()` は以下のコマンドでシェルの CWD を取得している:

```bash
readlink /proc/$(ps --no-headers -u $(whoami) -o pid,tty,comm \
  | grep 'pts/' | grep -E 'bash|zsh|fish|sh$' \
  | tail -1 | awk '{print $1}')/cwd
```

`tail -1` が **最も新しいシェルプロセス**をグローバルに選んでいるため、複数タブ（複数 SSH 接続）がある場合、別のタブのシェルの CWD を返してしまう。

### 解決方針

各タブは独自の `SshChannelManager`（= 独自の `SSHClient`）を持つ。`SSHClient` が `client.execute()` でコマンドを実行すると、そのコマンドのプロセスの親プロセスは **この SSH 接続の sshd プロセス**になる。PTY シェルも同じ sshd プロセスの子である。

したがって:
1. `client.execute()` の中で `$PPID`（= sshd PID）を取得
2. 同じ `PPID` を持ち、`pts/` 上で動いているシェルプロセスを探す
3. そのシェルの `/proc/<pid>/cwd` を `readlink` で取得

これにより、**このタブの SSH 接続に紐づくシェルだけ**の CWD を正確に取得できる。

---

## 実装手順

### 手順 1: 矢印ボタンに長押しリピートを追加

ファイル: `lib/widgets/quick_action_bar.dart`

`_ActionButton` の隣に `_RepeatableActionButton` を追加:

```dart
class _RepeatableActionButton extends StatefulWidget {
  const _RepeatableActionButton({
    this.label,
    this.icon,
    required this.onPressed,
  });

  final String? label;
  final IconData? icon;
  final VoidCallback onPressed;

  @override
  State<_RepeatableActionButton> createState() =>
      _RepeatableActionButtonState();
}

class _RepeatableActionButtonState extends State<_RepeatableActionButton> {
  Timer? _repeatTimer;

  void _startRepeat() {
    widget.onPressed(); // 即座に1回発火
    _repeatTimer?.cancel();
    // 初回遅延 300ms 後、50ms 間隔でリピート
    _repeatTimer = Timer(const Duration(milliseconds: 300), () {
      _repeatTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (!mounted) {
          _stopRepeat();
          return;
        }
        widget.onPressed();
      });
    });
  }

  void _stopRepeat() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
  }

  @override
  void deactivate() {
    _stopRepeat(); // ルート遷移やウィジェットツリー変更時にも確実に停止
    super.deactivate();
  }

  @override
  void dispose() {
    _repeatTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: Colors.grey[800],
        borderRadius: BorderRadius.circular(4),
        child: GestureDetector(
          onTapDown: (_) => _startRepeat(),
          onTapUp: (_) => _stopRepeat(),
          onTapCancel: _stopRepeat,
          child: Container(
            constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: widget.icon != null
                ? Icon(widget.icon, size: 18, color: Colors.white)
                : Text(
                    widget.label!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
```

`dart:async` の import が必要（`Timer` 用）。既に import されていれば不要。

矢印ボタンを `_ActionButton` → `_RepeatableActionButton` に変更:

変更前:
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

変更後:
```dart
_RepeatableActionButton(
  icon: Icons.arrow_upward,
  onPressed: () => onKeyPressed(TerminalKey.arrowUp),
),
_RepeatableActionButton(
  icon: Icons.arrow_back,
  onPressed: () => onKeyPressed(TerminalKey.arrowLeft),
),
_RepeatableActionButton(
  icon: Icons.arrow_forward,
  onPressed: () => onKeyPressed(TerminalKey.arrowRight),
),
_RepeatableActionButton(
  icon: Icons.arrow_downward,
  onPressed: () => onKeyPressed(TerminalKey.arrowDown),
),
```

### 手順 2: tmux タブ作成後のフォーカス修正

ファイル: `lib/features/terminal/terminal_screen.dart`

`_TerminalTabContentState._startConnection()` の末尾（tmux attach 後）にフォーカス要求を追加。

変更前:
```dart
// Auto-attach tmux session after connection is established.
if (widget.tmuxSessionName != null && mounted) {
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final terminal =
      ref.read(terminalConnectionProvider(widget.sessionId)).terminal;
  if (terminal != null) {
    final escaped =
        widget.tmuxSessionName!.replaceAll("'", r"'\''");
    terminal.textInput("tmux attach -t '$escaped'\r");
  }
}
```

変更後:
```dart
// Auto-attach tmux session after connection is established.
if (widget.tmuxSessionName != null && mounted) {
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final terminal =
      ref.read(terminalConnectionProvider(widget.sessionId)).terminal;
  if (terminal != null) {
    final escaped =
        widget.tmuxSessionName!.replaceAll("'", r"'\''");
    terminal.textInput("tmux attach -t '$escaped'\r");
  }
}

// 接続完了後にフォーカスを確実に要求
// （特に新しいタブの場合、didUpdateWidget のタイミングでは
//   TerminalView がまだ構築されていない可能性がある）
if (mounted && widget.isActive) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && widget.isActive) {
      _focusNode.requestFocus();
    }
  });
}
```

### 手順 3: バックグラウンド接続維持の追加強化

#### 3a. 通知チャネルの優先度を DEFAULT に変更

ファイル: `lib/core/background/ssh_foreground_service.dart`

変更前:
```dart
channelImportance: NotificationChannelImportance.LOW,
priority: NotificationPriority.LOW,
```

変更後:
```dart
channelImportance: NotificationChannelImportance.DEFAULT,
priority: NotificationPriority.DEFAULT,
```

**注意**: チャネルの importance を変更しても、既にインストール済みのアプリではチャネルが再作成されない場合がある。チャネル ID を変更するか、ユーザーがアプリの通知設定をリセットする必要がある可能性がある。確実を期すために **チャネル ID を変更**する:

変更前:
```dart
channelId: 'ssh_connection',
```

変更後:
```dart
channelId: 'ssh_connection_v2',
```

#### 3b. keepAliveInterval を 15 秒に戻す

ファイル: `lib/core/ssh/ssh_client_service.dart`

変更前:
```dart
keepAliveInterval: const Duration(seconds: 30),
```

変更後:
```dart
keepAliveInterval: const Duration(seconds: 15),
```

#### 3c. フォアグラウンドサービスの repeat を 10 秒に短縮

ファイル: `lib/core/background/ssh_foreground_service.dart`

変更前:
```dart
eventAction: ForegroundTaskEventAction.repeat(15000),
```

変更後:
```dart
eventAction: ForegroundTaskEventAction.repeat(10000),
```

#### 3d. SshClientService に軽量 keepAlive メソッドを追加

ファイル: `lib/core/ssh/ssh_client_service.dart`

メソッド追加:
```dart
/// 軽量な keepalive: `true` コマンドを実行して接続を維持する。
/// SSH_MSG_CHANNEL_OPEN → SSH_MSG_CHANNEL_CLOSE のやり取りで
/// サーバーに接続が生きていることを通知する。
/// 成功なら true、失敗（接続切れ）なら false。
Future<bool> keepAlive() async {
  if (_client == null || _client!.isClosed) return false;
  try {
    final session = await _client!.execute('true');
    await session.done.timeout(
      const Duration(seconds: 5),
      onTimeout: () {},
    );
    return true;
  } catch (_) {
    return false;
  }
}
```

#### 3e. TerminalConnectionNotifier に keepAlive メソッドを追加

ファイル: `lib/features/terminal/terminal_connection_provider.dart`

`lightHealthCheck()` を拡張して能動的 keepalive を行うメソッドを追加:

```dart
/// フォアグラウンドサービスの keepalive 受信時に呼ばれる。
/// SSH 接続に軽量なコマンドを送信して接続を維持する。
Future<void> activeKeepAlive() async {
  if (state.status != ConnectionStatus.connected) return;
  if (_sshService == null) return;
  final alive = await _sshService!.keepAlive();
  if (!alive) {
    _onDisconnected();
  }
}
```

#### 3f. _onTaskData で activeKeepAlive を呼ぶ

ファイル: `lib/features/terminal/terminal_screen.dart`

変更前:
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

変更後:
```dart
int _keepAliveCounter = 0;

void _onTaskData(Object data) {
  if (data == 'keepalive' && mounted) {
    _keepAliveCounter++;
    final managerState = ref.read(sessionManagerProvider);
    if (_keepAliveCounter % 3 == 0) {
      // 3回に1回（約30秒間隔）だけ能動的 keepalive（exec チャネル）
      // 毎回 exec すると SSH チャネル消費が多すぎるため
      for (final session in managerState.sessions) {
        ref
            .read(terminalConnectionProvider(session.sessionId).notifier)
            .activeKeepAlive();
      }
    } else {
      // 通常は軽量な isConnected フラグチェックのみ
      for (final session in managerState.sessions) {
        ref
            .read(terminalConnectionProvider(session.sessionId).notifier)
            .lightHealthCheck();
      }
    }
  }
}
```

### 手順 4: 全接続切断時にタブをクリーンアップ

ファイル: `lib/features/terminal/terminal_screen.dart`

`didChangeAppLifecycleState` の `resumed` 処理を拡張。復帰後に全セッションの接続チェックを行い、一定時間後に全セッションが `disconnected`（`reconnecting` でもない）なら全タブを閉じる。

変更前:
```dart
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
```

変更後:
```dart
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

  // 状態ベースでタブクリーンアップ判定:
  // 再接続中のセッションがなくなり、全 disconnected ならクリーンアップ
  // 最大 90 秒待機（5秒ごとにチェック、18回で打ち切り）
  _scheduleCleanupCheck(0);
}
```

新しいヘルパーメソッドを `_TerminalScreenState` に追加:

```dart
void _scheduleCleanupCheck(int attempt) {
  if (attempt >= 18) return; // 最大 90 秒で打ち切り
  Future.delayed(const Duration(seconds: 5), () {
    if (!mounted) return;
    final managerState = ref.read(sessionManagerProvider);
    if (managerState.sessions.isEmpty) return;

    // まだ再接続中のセッションがあれば待機
    final hasReconnecting = managerState.sessions.any((session) {
      final connState =
          ref.read(terminalConnectionProvider(session.sessionId));
      return connState.status == ConnectionStatus.reconnecting ||
          connState.status == ConnectionStatus.connecting;
    });

    if (hasReconnecting) {
      _scheduleCleanupCheck(attempt + 1);
      return;
    }

    // 全セッションが disconnected なら全タブを閉じる
    final allDisconnected = managerState.sessions.every((session) {
      final connState =
          ref.read(terminalConnectionProvider(session.sessionId));
      return connState.status == ConnectionStatus.disconnected;
    });

    if (allDisconnected) {
      final manager = ref.read(sessionManagerProvider.notifier);
      for (final session in [...managerState.sessions]) {
        manager.removeSession(session.sessionId);
      }
    }
  });
}
```

### 手順 5: getShellCwd() をタブ固有の CWD 取得に修正

ファイル: `lib/core/ssh/ssh_channel_manager.dart`

変更前:
```dart
Future<String?> getShellCwd() async {
  try {
    final session = await client.execute(
      r"readlink /proc/$(ps --no-headers -u $(whoami) -o pid,tty,comm "
      r"| grep 'pts/' | grep -E 'bash|zsh|fish|sh$' "
      r"| tail -1 | awk '{print $1}')/cwd 2>/dev/null",
    );
    final output = await session.stdout
        .cast<List<int>>()
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 5), onTimeout: () => '');
    final cwd = output.trim();
    if (cwd.isNotEmpty && cwd.startsWith('/')) {
      return cwd;
    }
  } catch (_) {
    // コマンド実行失敗（非 Linux、権限不足等）→ null を返す
  }
  return null;
}
```

変更後:
```dart
Future<String?> getShellCwd() async {
  try {
    // 方式1: $PPID = この exec チャネルの親 = この SSH 接続の sshd プロセス
    // 同じ sshd の子で pts 上のシェルプロセスの CWD を取得
    // → タブ（SSH 接続）ごとに正しい CWD が返る
    // 方式2 (フォールバック): tmux 内等で $PPID がマッチしない場合、
    //   従来の tail -1 で最新シェルの CWD を返す（1タブなら正確）
    final session = await client.execute(
      r"CWD=$(readlink /proc/$(ps --no-headers -o pid,ppid,tty,comm -u $(whoami) "
      r"| awk -v ppid=$PPID "
      r"'$2==ppid && $3 ~ /pts\// && $4 ~ /bash|zsh|fish|sh$/ {print $1; exit}'"
      r")/cwd 2>/dev/null); "
      r"if [ -n '$CWD' ]; then echo '$CWD'; else "
      r"readlink /proc/$(ps --no-headers -u $(whoami) -o pid,tty,comm "
      r"| grep 'pts/' | grep -E 'bash|zsh|fish|sh$' "
      r"| tail -1 | awk '{print $1}')/cwd 2>/dev/null; fi",
    );
    final output = await session.stdout
        .cast<List<int>>()
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 5), onTimeout: () => '');
    final cwd = output.trim();
    if (cwd.isNotEmpty && cwd.startsWith('/')) {
      return cwd;
    }
  } catch (_) {
    // コマンド実行失敗（非 Linux、権限不足等）→ null を返す
  }
  return null;
}
```

**変更点**:
- まず `$PPID` ベースでこの SSH 接続固有のシェルを探す
- tmux 内等で `$PPID` がマッチしない場合は従来の `tail -1` にフォールバック
- 1タブしかない場合はフォールバックでも正確な結果が返る

---

## テストへの影響

- `_RepeatableActionButton`: 新規ウィジェット、既存テストに影響なし。`_ActionButton` から `_RepeatableActionButton` への変更で矢印ボタンの `find.byType` が変わる可能性あり
- `_startConnection` のフォーカス追加: 既存テストに影響なし
- 通知チャネル ID 変更: テスト影響なし（Android のみ）
- `keepAlive()` / `activeKeepAlive()`: 新規メソッド、既存テストに影響なし
- タブクリーンアップ: `SessionManagerNotifier.removeSession` のテストがあれば確認
- `getShellCwd()` コマンド変更: 既存の `getShellCwd` テストがあれば期待するコマンド文字列の更新が必要

## 実装順序

1. `lib/widgets/quick_action_bar.dart`:
   - `_RepeatableActionButton` ウィジェット追加
   - 矢印ボタンを `_RepeatableActionButton` に変更
   - `dart:async` import 追加（未 import の場合）
2. `lib/features/terminal/terminal_screen.dart`:
   - `_startConnection()` 末尾にフォーカス要求追加
   - `_onTaskData` で `activeKeepAlive()` を呼ぶよう変更
   - `didChangeAppLifecycleState` の `resumed` に 70 秒後のタブクリーンアップ追加
3. `lib/core/ssh/ssh_client_service.dart`:
   - `keepAlive()` メソッド追加
   - `keepAliveInterval` を 15 秒に変更
4. `lib/core/background/ssh_foreground_service.dart`:
   - 通知チャネルの importance を `DEFAULT` に変更
   - チャネル ID を `ssh_connection_v2` に変更
   - repeat 間隔を `10000` に変更
5. `lib/features/terminal/terminal_connection_provider.dart`:
   - `activeKeepAlive()` メソッド追加
6. `lib/core/ssh/ssh_channel_manager.dart`:
   - `getShellCwd()` を `$PPID` ベースのタブ固有 CWD 取得に修正
7. テスト確認・修正
8. `~/flutter/bin/flutter analyze`
9. `~/flutter/bin/flutter test`
10. `~/flutter/bin/flutter build apk --debug`
