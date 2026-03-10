---
goal: "Phase 14 - tmux _dependents.isEmpty 修正 + バックグラウンド復帰後のゾンビ接続対策"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 14: tmux _dependents.isEmpty 修正 + バックグラウンド復帰後のゾンビ接続対策

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

## 背景

Phase 12 と Phase 13 で再接続ロジックとフォアグラウンドサービスを実装したが、以下の2つの問題が残っている:

### Bug 1: tmux セッションの Rename / Create で赤いエラー画面

`_dependents.isEmpty` アサーションエラーが発生する。Phase 11 で `ConsumerWidget` → `ConsumerStatefulWidget`、Phase 12 で `ConsumerStatefulWidget` → `StatefulWidget` に変更したが解決していない。

**根本原因**: `TmuxManagerScreen`（ConsumerStatefulWidget）の `build()` 内で `ref.watch(tmuxProvider(widget.connectionId))` を使用している。tmux 操作（create/rename）後に `_safeRefresh()` が `state = AsyncData(...)` で state を更新すると、Riverpod が `tmuxProvider` の InheritedWidget を更新 → `TmuxManagerScreen` の rebuild をトリガーする。この rebuild が、Flutter フレームワークの `InheritedElement.deactivate()` の `_dependents.isEmpty` アサーションと競合する。

**修正方針**: `TmuxManagerScreen` を `ConsumerStatefulWidget` から通常の `StatefulWidget` に変更し、`ref.watch` の代わりに `ref.listenManual` を `initState` 内で登録してローカル state として保持する。これにより InheritedWidget の依存チェーンが切れ、`_dependents.isEmpty` アサーションが回避される。

### Bug 2: バックグラウンドから戻ると接続がサイレントに死んでいる

フォアグラウンドサービスでプロセスは維持されるが、TCP ソケットが死んでいる場合がある（ゾンビ接続）。`checkConnection()` は `_sshService!.isConnected` をチェックするが、dartssh2 の `isClosed` は TCP 切断を即座に検知しない。結果、`checkConnection()` は「接続は生きている」と判断して何もしない。

**修正方針**:
1. `checkConnection()` でアクティブな接続プローブを行う（SSH exec チャネルで `echo` コマンドを実行し、タイムアウトで死活判定）
2. 全セッションに対して `checkConnection()` を呼ぶ（現在はアクティブセッションのみ）
3. フォアグラウンドサービスに `allowWakeLock: true` を追加して CPU スリープを防ぐ

## 実装手順

### 手順 1: TmuxManagerScreen を StatefulWidget + ref.listenManual に変更

ファイル: `lib/features/tmux/tmux_manager_screen.dart`

`TmuxManagerScreen` を `ConsumerStatefulWidget` から `StatefulWidget` に変更し、Riverpod の依存を手動リスンに切り替える。

変更前:
```dart
class TmuxManagerScreen extends ConsumerStatefulWidget {
  // ...
  @override
  ConsumerState<TmuxManagerScreen> createState() => _TmuxManagerScreenState();
}

class _TmuxManagerScreenState extends ConsumerState<TmuxManagerScreen> {
  // build() 内で ref.watch(tmuxProvider(...))
}
```

変更後:
```dart
class TmuxManagerScreen extends ConsumerStatefulWidget {
  const TmuxManagerScreen({super.key, required this.connectionId});

  final String connectionId;

  @override
  ConsumerState<TmuxManagerScreen> createState() => _TmuxManagerScreenState();
}

class _TmuxManagerScreenState extends ConsumerState<TmuxManagerScreen> {
  AsyncValue<TmuxState> _tmuxState = const AsyncLoading();
  ProviderSubscription<AsyncValue<TmuxState>>? _subscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _subscription = ref.listenManual(
        tmuxProvider(widget.connectionId),
        (_, next) {
          if (mounted) {
            setState(() => _tmuxState = next);
          }
        },
        fireImmediately: true,
      );
    });
  }

  @override
  void dispose() {
    _subscription?.close();
    super.dispose();
  }

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

  @override
  Widget build(BuildContext context) {
    // ref.watch を使わない — _tmuxState はローカル state
    return Container(
      color: Colors.grey[900],
      child: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: _tmuxState.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => _ErrorView(
                error: e,
                onRetry: () =>
                    ref.invalidate(tmuxProvider(widget.connectionId)),
              ),
              data: (state) => !state.isAvailable
                  ? _NotInstalledView(
                      onRetry: () =>
                          ref.invalidate(tmuxProvider(widget.connectionId)),
                    )
                  : _SessionListView(
                      state: state,
                      onRefresh: () => ref
                          .read(tmuxProvider(widget.connectionId).notifier)
                          .refresh(),
                      onAttach: (name) => ref
                          .read(tmuxProvider(widget.connectionId).notifier)
                          .attachSession(name),
                      onDelete: (name) => ref
                          .read(tmuxProvider(widget.connectionId).notifier)
                          .killSession(name),
                      onRename: (oldName, newName) => ref
                          .read(tmuxProvider(widget.connectionId).notifier)
                          .renameSession(oldName, newName),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  // _buildHeader() と _showCreateDialog() は ref.watch を使わないのでそのまま
  // ただし _showCreateDialog 内で ref.read(tmuxProvider(...)) は OK（watch ではないので問題なし）
  // ...（既存コードを維持）
}
```

**重要ポイント**:
- `ref.watch` を `ref.listenManual` + `setState` に置き換える
- `ref.read` と `ref.invalidate` はそのまま使用可（`watch` と異なり InheritedWidget 依存を作らない）
- `ConsumerStatefulWidget` / `ConsumerState` はそのまま維持する（`ref.read` と `ref.listenManual` に必要）
- `_tmuxState` フィールドで AsyncValue を保持し、`build()` では `_tmuxState.when(...)` を使用
- `_showCreateDialog` 内の `ref.read(tmuxProvider(...))` は watch ではないので問題なし

### 手順 2: checkConnection() にアクティブプローブを追加

ファイル: `lib/features/terminal/terminal_connection_provider.dart`

`checkConnection()` で `isConnected` が true でも、実際に SSH exec チャネルで `echo` コマンドを実行して生死を確認する。

変更前:
```dart
Future<void> checkConnection() async {
  if (_sshService != null && _sshService!.isConnected) return;
  // ...
}
```

変更後:
```dart
Future<void> checkConnection() async {
  // 既に再接続中なら何もしない
  if (state.status == ConnectionStatus.reconnecting) return;
  // 既に切断状態なら何もしない（バナーが既に表示されている）
  if (state.status == ConnectionStatus.disconnected) return;
  // config がない（未接続）なら切断状態にするだけ
  if (_config == null) {
    _onDisconnected();
    return;
  }

  // isConnected が true でもゾンビ接続の可能性がある
  // アクティブプローブで確認する
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

  // 接続が切れていたら自動再接続を試みる
  await reconnect();
}
```

### 手順 3: SshClientService にプローブメソッドを追加

ファイル: `lib/core/ssh/ssh_client_service.dart`

SSH exec チャネルを開いて `echo ok` を実行し、正常なレスポンスが返るかで接続の生死を判定する。

```dart
/// 接続が実際に生きているかアクティブプローブで確認する。
/// exec チャネルで `echo ok` を実行し、結果が返れば true。
Future<bool> probe() async {
  if (_client == null || _client!.isClosed) return false;
  try {
    final session = await _client!.execute('echo ok');
    final stdout = await session.stdout
        .transform(const Utf8Decoder())
        .join();
    await session.done;
    return stdout.trim() == 'ok';
  } catch (_) {
    return false;
  }
}
```

**注意**: `dart:convert` の `Utf8Decoder` を import する必要がある。既に `dart:typed_data` が import されているので、`dart:convert` を追加する。

### 手順 4: 全セッションに対して checkConnection() を呼ぶ

ファイル: `lib/features/terminal/terminal_screen.dart`

`didChangeAppLifecycleState` で、アクティブセッションだけでなく全セッションの接続を確認する。

変更前:
```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      final managerState = ref.read(sessionManagerProvider);
      final activeId = managerState.activeSessionId;
      if (activeId != null) {
        ref
            .read(terminalConnectionProvider(activeId).notifier)
            .checkConnection();
      }
    });
  }
}
```

変更後:
```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted) return;
      final managerState = ref.read(sessionManagerProvider);
      // 全セッションの接続を確認（バックグラウンドで全部死んでいる可能性がある）
      for (final session in managerState.sessions) {
        ref
            .read(terminalConnectionProvider(session.sessionId).notifier)
            .checkConnection();
      }
    });
  }
}
```

### 手順 5: フォアグラウンドサービスに allowWakeLock を追加

ファイル: `lib/core/background/ssh_foreground_service.dart`

`ForegroundTaskOptions` に `allowWakeLock: true` を追加して、画面オフ時も CPU がスリープしないようにする。

変更前:
```dart
foregroundTaskOptions: ForegroundTaskOptions(
  eventAction: ForegroundTaskEventAction.nothing(),
  autoRunOnBoot: false,
  allowWifiLock: true,
),
```

変更後:
```dart
foregroundTaskOptions: ForegroundTaskOptions(
  eventAction: ForegroundTaskEventAction.nothing(),
  autoRunOnBoot: false,
  allowWakeLock: true,
  allowWifiLock: true,
),
```

## テストへの影響

- `SshClientService.probe()` は `SSHClient.execute()` を使用する。テスト環境ではモック対象。既存のモックパターン（`class MockSshClientService extends Mock implements SshClientService`）に `probe()` が自動的に追加される。
- `TmuxManagerScreen` のウィジェットテスト：`ref.watch` → `ref.listenManual` の変更によりテスト動作に影響はないはず（Riverpod の ProviderScope でオーバーライドする方法は同じ）。ただし、`addPostFrameCallback` で `_subscription` を登録するため、テスト内で `tester.pump()` が必要。
- フォアグラウンドサービスの変更は `Platform.isAndroid` ガードにより Linux テスト環境では no-op。

## 実装順序

1. `lib/features/tmux/tmux_manager_screen.dart` — `ref.watch` → `ref.listenManual` + `setState`
2. `lib/core/ssh/ssh_client_service.dart` — `probe()` メソッド追加 + `dart:convert` import
3. `lib/features/terminal/terminal_connection_provider.dart` — `checkConnection()` にアクティブプローブ追加
4. `lib/features/terminal/terminal_screen.dart` — 全セッションに `checkConnection()` 呼び出し
5. `lib/core/background/ssh_foreground_service.dart` — `allowWakeLock: true` 追加
6. `~/flutter/bin/flutter analyze` でエラーがないことを確認
7. `~/flutter/bin/flutter test` で全テストパスを確認
8. `~/flutter/bin/flutter build apk --debug` でビルド
