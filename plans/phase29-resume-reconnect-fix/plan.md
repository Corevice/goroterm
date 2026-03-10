---
goal: "Phase 29 - バックグラウンド復帰時の不要な再接続を防止"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 29: バックグラウンド復帰時の不要な再接続を防止

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題: アプリ復帰時に接続が必ずリフレッシュされる

### 現在の動作

`didChangeAppLifecycleState(resumed)` → 500ms 遅延 → 全セッションに `checkConnection()` を呼ぶ:

```dart
// terminal_screen.dart:137-149
if (state == AppLifecycleState.resumed) {
  Future.delayed(const Duration(milliseconds: 500), () {
    for (final session in managerState.sessions) {
      ref.read(terminalConnectionProvider(session.sessionId).notifier)
          .checkConnection();
    }
  });
}
```

`checkConnection()` は `connected` 状態のセッションに対して**常に** `probe()` を実行する:

```dart
// terminal_connection_provider.dart:318-327
if (_sshService != null && _sshService!.isConnected) {
  try {
    final probeOk = await _sshService!.probe().timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
    if (probeOk) return;
  } catch (_) {}
}
_cleanupConnections();
await reconnect();
```

### 根本原因

3 つの問題が重なっている:

#### 1. probe() が重い＆ハングしやすい

`probe()` は `echo ok` を実行して stdout を `await ...join()` + `await session.done` で読む:

```dart
// ssh_client_service.dart:130-143
Future<bool> probe() async {
  final session = await _client!.execute('echo ok');
  final stdout = await session.stdout
      .cast<List<int>>()
      .transform(utf8.decoder)
      .join();
  await session.done;
  return stdout.trim() == 'ok';
}
```

- `session.stdout...join()` は dartssh2 の Channel_Close バグで**ハングする可能性がある**（Phase 28 で発見した問題と同じ）
- `session.done` にタイムアウトがない
- Android の Wi-Fi がバックグラウンドから復帰する際、ネットワーク再接続に数秒かかることがあり、5 秒タイムアウトに引っかかりやすい

結果: probe() がタイムアウト → 接続が生きているのに「死んでいる」と判定 → 不要な reconnect。

#### 2. keepalive との重複チェック

フォアグラウンドサービスが 10 秒ごとに `lightHealthCheck()` / 30 秒ごとに `activeKeepAlive()` を実行している。これらが正常に動いている場合、接続はすでに確認済みなのに、resume 時に再度 probe() を実行するのは無駄。

#### 3. _onDisconnected() との競合

バックグラウンド中に SSH 接続が切れると `_onDisconnected()` → `reconnect()` が即座に発動する。その再接続が進行中に resume → `checkConnection()` が呼ばれると:
- `reconnecting` 状態ならスキップされる（問題なし）
- しかし reconnect が完了して `connected` になった直後だと、再度 probe() が走る

---

## 修正方針

### A. 「最終確認時刻」を導入し、最近確認済みならスキップ

`_lastAliveConfirmed` タイムスタンプを追加。以下のタイミングで更新:
- `keepAlive()` 成功時
- `probe()` 成功時
- `reconnect()` 成功時
- 初回 `connect()` 成功時

`checkConnection()` で `connected` 状態のとき、最終確認から 10 秒以内ならプローブをスキップする。フォアグラウンドサービスの activeKeepAlive は 30 秒間隔なので、10 秒の閾値なら偽陽性（死んでいるのにスキップ）の隙間を小さく抑えられる。

### B. probe() を keepAlive() に置き換え

`checkConnection()` 内のプローブを `probe()` から `keepAlive()` に変更する:
- `probe()`: `echo ok` 実行 → stdout を `await ...join()` で読む → `session.done` を待つ → dartssh2 のハングバグに影響される
- `keepAlive()`: `true` 実行 → stdout を読まない → `session.done.timeout(5s)` のみ → ハングリスクが低い

さらに、バックグラウンド復帰直後は Wi-Fi 再接続に時間がかかるため、`keepAlive()` のタイムアウトをパラメータ化し、resume 時は 10 秒に延長する。

### C. keepAlive 成功時のレース対策

`await keepAlive()` 中にサービスが差し替わる（切断→再接続）可能性がある。タイムスタンプ更新前に `identical(_sshService, service)` で同一インスタンスか確認する。

### D. _onDisconnected() でもタイムスタンプをクリア

`_cleanupConnections()` は `_onDisconnected()` 内で即座に呼ばれないため、`_onDisconnected()` でも `_lastAliveConfirmed = null` を設定して、切断後の誤スキップを防ぐ。

### E. probe() のハング対策

`probe()` 自体も dartssh2 の stdout ハングバグの影響を受ける。`await session.stdout...join()` が永遠に返らない可能性がある。全体にタイムアウトを追加する。

---

## 実装手順

### 手順 1: _lastAliveConfirmed タイムスタンプの追加

ファイル: `lib/features/terminal/terminal_connection_provider.dart`

#### 1a. フィールド追加

既存のフィールド群（`_lastReconnectAttempt` の近く）に追加:

変更前:
```dart
  DateTime? _lastReconnectAttempt;
  bool _isActiveKeepAliveRunning = false;
```

変更後:
```dart
  DateTime? _lastReconnectAttempt;
  DateTime? _lastAliveConfirmed;
  bool _isActiveKeepAliveRunning = false;
```

#### 1b. activeKeepAlive 成功時に更新

変更前:
```dart
  Future<void> _activeKeepAliveCore() async {
    if (state.status == ConnectionStatus.connected) {
      if (_sshService == null) return;
      final alive = await _sshService!.keepAlive();
      if (!alive) {
        _onDisconnected();
      }
      return;
    }
```

変更後:
```dart
  Future<void> _activeKeepAliveCore() async {
    if (state.status == ConnectionStatus.connected) {
      final service = _sshService;
      if (service == null) return;
      final alive = await service.keepAlive();
      // await 中にサービスが差し替わった場合はタイムスタンプを更新しない
      if (alive && identical(service, _sshService) &&
          state.status == ConnectionStatus.connected) {
        _lastAliveConfirmed = DateTime.now();
      } else if (!alive) {
        _onDisconnected();
      }
      return;
    }
```

#### 1c. reconnect 成功時に更新

`reconnect()` メソッド内、再接続成功後のブロック:

変更前:
```dart
      _retryCount = 0;
      _lastReconnectAttempt = null;
      state = state.copyWith(
        status: ConnectionStatus.connected,
        terminal: terminal,
        channelManager: _channelManager,
      );
```

変更後:
```dart
      _retryCount = 0;
      _lastReconnectAttempt = null;
      _lastAliveConfirmed = DateTime.now();
      state = state.copyWith(
        status: ConnectionStatus.connected,
        terminal: terminal,
        channelManager: _channelManager,
      );
```

#### 1d. 初回接続成功時に更新

`connect()` メソッド（117 行目付近）の成功パスで更新:

変更前:
```dart
      final terminal = await _connectCore(
        config: config,
        password: password,
        privateKeyPem: privateKeyPem,
        passphrase: passphrase,
      );
      state = state.copyWith(
        status: ConnectionStatus.connected,
        terminal: terminal,
        channelManager: _channelManager,
      );
      _startHealthCheck();
```

変更後:
```dart
      final terminal = await _connectCore(
        config: config,
        password: password,
        privateKeyPem: privateKeyPem,
        passphrase: passphrase,
      );
      _lastAliveConfirmed = DateTime.now();
      state = state.copyWith(
        status: ConnectionStatus.connected,
        terminal: terminal,
        channelManager: _channelManager,
      );
      _startHealthCheck();
```

#### 1e. _onDisconnected() でタイムスタンプクリア

`_cleanupConnections()` は `_onDisconnected()` 内で即座に呼ばれないため、ここでもクリアする:

変更前:
```dart
  void _onDisconnected() {
    if (state.status == ConnectionStatus.reconnecting) return;
    if (state.status == ConnectionStatus.disconnected) return;
    state = state.copyWith(
      status: ConnectionStatus.disconnected,
      errorMessage: 'Connection lost',
      clearChannelManager: true,
    );
```

変更後:
```dart
  void _onDisconnected() {
    if (state.status == ConnectionStatus.reconnecting) return;
    if (state.status == ConnectionStatus.disconnected) return;
    _lastAliveConfirmed = null;
    state = state.copyWith(
      status: ConnectionStatus.disconnected,
      errorMessage: 'Connection lost',
      clearChannelManager: true,
    );
```

### 手順 2: checkConnection() の改善

ファイル: `lib/features/terminal/terminal_connection_provider.dart`

変更前:
```dart
  Future<void> checkConnection() async {
    // レース条件ガード: 既に checkConnection が実行中なら何もしない
    if (_isCheckingConnection) return;
    // 既に再接続中・接続中なら何もしない
    if (state.status == ConnectionStatus.reconnecting) return;
    if (state.status == ConnectionStatus.connecting) return;
    // config がない（一度も接続していない）なら何もしない
    if (_config == null) return;

    _isCheckingConnection = true;
    try {
      // ケース B: バックグラウンド中に _onDisconnected() で disconnected になった場合
      // → 自動再接続を試みる（バナーが出ていても再接続）
      if (state.status == ConnectionStatus.disconnected) {
        await reconnect();
        return;
      }

      // ケース A: state が connected だが実際は死んでいる（ゾンビ）可能性
      if (_sshService != null && _sshService!.isConnected) {
        try {
          final probeOk = await _sshService!.probe().timeout(
            const Duration(seconds: 5),
            onTimeout: () => false,
          );
          if (probeOk) return; // 本当に生きている
        } catch (_) {
          // プローブ失敗 = 接続は死んでいる
        }
      }

      // ゾンビ接続: state を disconnected に変更してから reconnect
      // （reconnect() は disconnected 状態でないと実行しないため）
      _cleanupConnections();
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        errorMessage: 'Connection lost',
        clearChannelManager: true,
      );
      await reconnect();
    } finally {
      _isCheckingConnection = false;
    }
  }
```

変更後:
```dart
  Future<void> checkConnection() async {
    // レース条件ガード: 既に checkConnection が実行中なら何もしない
    if (_isCheckingConnection) return;
    // 既に再接続中・接続中なら何もしない
    if (state.status == ConnectionStatus.reconnecting) return;
    if (state.status == ConnectionStatus.connecting) return;
    // config がない（一度も接続していない）なら何もしない
    if (_config == null) return;

    _isCheckingConnection = true;
    try {
      // ケース B: バックグラウンド中に _onDisconnected() で disconnected になった場合
      // → 自動再接続を試みる
      if (state.status == ConnectionStatus.disconnected) {
        await reconnect();
        return;
      }

      // ケース A: state が connected — 本当に生きているか確認
      if (_sshService != null && _sshService!.isConnected) {
        // 最後の確認から 10 秒以内なら probe をスキップ
        // （keepalive / reconnect で確認済み）
        if (_lastAliveConfirmed != null &&
            DateTime.now().difference(_lastAliveConfirmed!) <
                const Duration(seconds: 10)) {
          return;
        }

        try {
          // probe() ではなく keepAlive() を使う:
          // - probe() は session.stdout を await ...join() で読むため
          //   dartssh2 の Channel_Close バグでハングする可能性がある
          // - keepAlive() は session.done のみ待機するためハングリスクが低い
          // バックグラウンド復帰直後は Wi-Fi 再接続に時間がかかるため
          // keepAlive のタイムアウトを 10 秒に延長する
          final service = _sshService!;
          final alive = await service.keepAlive(
            executeTimeout: const Duration(seconds: 10),
            doneTimeout: const Duration(seconds: 10),
          );
          if (alive && identical(service, _sshService)) {
            _lastAliveConfirmed = DateTime.now();
            return; // 生きている
          }
        } catch (_) {
          // keepAlive 失敗 = 接続は死んでいる
        }
      }

      // ゾンビ接続: state を disconnected に変更してから reconnect
      _cleanupConnections();
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        errorMessage: 'Connection lost',
        clearChannelManager: true,
      );
      await reconnect();
    } finally {
      _isCheckingConnection = false;
    }
  }
```

### 手順 3: keepAlive() のタイムアウトをパラメータ化

ファイル: `lib/core/ssh/ssh_client_service.dart`

`checkConnection()` で復帰直後の Wi-Fi 再接続に備えてタイムアウトを延長できるようにする。

変更前:
```dart
  Future<bool> keepAlive() async {
    if (_client == null || _client!.isClosed) return false;
    try {
      final session = await _client!
          .execute('true')
          .timeout(const Duration(seconds: 5));
      await session.done.timeout(const Duration(seconds: 5));
      return true;
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }
```

変更後:
```dart
  Future<bool> keepAlive({
    Duration executeTimeout = const Duration(seconds: 5),
    Duration doneTimeout = const Duration(seconds: 5),
  }) async {
    if (_client == null || _client!.isClosed) return false;
    try {
      final session = await _client!
          .execute('true')
          .timeout(executeTimeout);
      await session.done.timeout(doneTimeout);
      return true;
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }
```

### 手順 4: probe() にタイムアウトを追加

ファイル: `lib/core/ssh/ssh_client_service.dart`

`probe()` は `checkConnection()` では使わなくなるが、他の箇所から呼ばれる可能性に備えてハング対策を追加する。

変更前:
```dart
  Future<bool> probe() async {
    if (_client == null || _client!.isClosed) return false;
    try {
      final session = await _client!.execute('echo ok');
      final stdout = await session.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .join();
      await session.done;
      return stdout.trim() == 'ok';
    } catch (_) {
      return false;
    }
  }
```

変更後:
```dart
  Future<bool> probe() async {
    if (_client == null || _client!.isClosed) return false;
    try {
      final session = await _client!.execute('echo ok')
          .timeout(const Duration(seconds: 5));
      // stdout の await ...join() は dartssh2 の Channel_Close バグで
      // ハングする可能性がある。全体を 5 秒タイムアウトで保護する。
      final stdout = await session.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 5));
      await session.done.timeout(const Duration(seconds: 5));
      return stdout.trim() == 'ok';
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }
```

### 手順 5: _cleanupConnections で _lastAliveConfirmed をクリア

ファイル: `lib/features/terminal/terminal_connection_provider.dart`

`_cleanupConnections()` 内で `_lastAliveConfirmed` をリセットして、切断後は必ず再確認が走るようにする。

`_cleanupConnections()` メソッドの先頭付近に追加:

```dart
_lastAliveConfirmed = null;
```

---

## テストへの影響

- `checkConnection()`: `probe()` → `keepAlive()` に変更。`probe()` をモックしていたテストは `keepAlive()` のモックに変更が必要
- `keepAlive()`: シグネチャ変更（名前付きオプション引数追加）。既存の呼び出しはデフォルト値で互換性あり。モックが厳密にシグネチャを検証している場合は更新が必要
- `_lastAliveConfirmed`: 新規フィールド。テストで「最近確認済み」パスを検証する場合は、`activeKeepAlive()` を先に呼んでタイムスタンプを設定してから `checkConnection()` を呼ぶ
- `probe()`: タイムアウト追加 + `TimeoutException` の import が必要（`dart:async`）。既存のモックテストには影響なし
- `reconnect()` / `connect()`: `_lastAliveConfirmed` 設定追加。既存テストに影響なし

## 実装順序

1. `lib/features/terminal/terminal_connection_provider.dart`:
   - `_lastAliveConfirmed` フィールド追加
   - `_activeKeepAliveCore()` で成功時にタイムスタンプ更新（`identical` チェック付き）
   - `reconnect()` 成功時にタイムスタンプ更新
   - 初回 `connect()` 成功時にタイムスタンプ更新
   - `_onDisconnected()` でタイムスタンプクリア
   - `checkConnection()` を書き換え（10 秒スキップ + keepAlive 使用 + identical チェック）
   - `_cleanupConnections()` でタイムスタンプクリア
2. `lib/core/ssh/ssh_client_service.dart`:
   - `keepAlive()` にタイムアウトパラメータ追加（`executeTimeout`, `doneTimeout`）
   - `probe()` に個別タイムアウト追加
3. テスト確認・修正
4. `~/flutter/bin/flutter analyze`
5. `~/flutter/bin/flutter test`
6. `~/flutter/bin/flutter build apk --debug`
