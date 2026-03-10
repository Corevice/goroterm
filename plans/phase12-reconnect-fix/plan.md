---
goal: "Phase 12 - Reconnect修正 + tmux _dependents.isEmpty 解消"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 12: Reconnect修正 + tmux _dependents.isEmpty 解消

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

## 背景

Phase 11 で `checkConnection()` の自動再接続を削除し、バックグラウンド復帰時は「Connection lost」バナーを表示する方式にした。しかし以下の問題が残っている。

## Bug 1: tmux セッションの Rename / 新規作成で `_dependents.isEmpty` assertion エラー

### エラーメッセージ

```
'package:flutter/src/widgets/framework.dart': Failed assertion: line 6079 pos 14:
'_dependents.isEmpty': is not true.
```

### 原因

`TmuxManagerScreen.build()` で `ref.watch(tmuxProvider(...))` を使用している。tmux 操作（create/rename）後に `_safeRefresh()` がプロバイダの state を更新すると、Riverpod が `InheritedWidget` 経由で `TmuxManagerScreen` のリビルドを通知する。

このとき、子ウィジェット `_SessionListView`（`ConsumerStatefulWidget`）が `InheritedWidget` のデアクティベーション中にまだ依存関係を持っているため、Flutter フレームワークの assertion が発火する。

これは Riverpod 2.x + Flutter の `InheritedElement.deactivate()` における既知の問題で、入れ子の Consumer ウィジェットがある場合に発生する。

### 修正方針

`_SessionListView` を **`ConsumerStatefulWidget` から `StatefulWidget`** に変更し、Riverpod への依存を完全に排除する。プロバイダ操作はすべて親ウィジェット（`TmuxManagerScreen`）からコールバックとして渡す。

### 修正対象ファイル

- `lib/features/tmux/tmux_manager_screen.dart`

### 具体的な変更

```dart
// ===== 変更前 =====
class _SessionListView extends ConsumerStatefulWidget {
  const _SessionListView({
    required this.connectionId,
    required this.state,
  });
  final String connectionId;
  final TmuxState state;

  @override
  ConsumerState<_SessionListView> createState() => _SessionListViewState();
}

class _SessionListViewState extends ConsumerState<_SessionListView> {
  Future<void> _renameSession(String oldName, String newName) async {
    try {
      await ref.read(tmuxProvider(widget.connectionId).notifier)
          .renameSession(oldName, newName);
    } catch (e) { ... }
  }
  // ... ref を使用するメソッド多数
}

// ===== 変更後 =====
class _SessionListView extends StatefulWidget {
  const _SessionListView({
    required this.state,
    required this.onRefresh,
    required this.onAttach,
    required this.onDelete,
    required this.onRename,
  });

  final TmuxState state;
  final Future<void> Function() onRefresh;
  final void Function(String name) onAttach;
  final Future<void> Function(String name) onDelete;
  final Future<void> Function(String oldName, String newName) onRename;

  @override
  State<_SessionListView> createState() => _SessionListViewState();
}

class _SessionListViewState extends State<_SessionListView> {
  // ref を一切使わない。すべて widget のコールバックで処理する。

  @override
  Widget build(BuildContext context) {
    if (widget.state.sessions.isEmpty) {
      return const Center(
        child: Text(
          'No sessions.\nTap + to create one.',
          style: TextStyle(color: Colors.grey),
          textAlign: TextAlign.center,
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: ListView.builder(
        itemCount: widget.state.sessions.length,
        itemBuilder: (context, index) {
          final session = widget.state.sessions[index];
          return _SessionCard(
            session: session,
            onAttach: () {
              widget.onAttach(session.name);
              Navigator.of(context).pop(); // Close drawer
            },
            onDelete: () => _confirmDelete(session.name),
            onRename: () => _showRenameDialog(session.name),
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[850],
        title: const Text('Delete Session', style: TextStyle(color: Colors.white)),
        content: Text(
          'Kill session "$name"? This will close all windows.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Kill', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      try {
        await widget.onDelete(name);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to kill session: $e')),
          );
        }
      }
    }
  }

  Future<void> _showRenameDialog(String oldName) async {
    final existingNames = widget.state.sessions
        .map((s) => s.name)
        .where((n) => n != oldName)
        .toList();

    final controller = TextEditingController(text: oldName);
    String? errorText;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: Colors.grey[850],
          title: const Text('Rename Session', style: TextStyle(color: Colors.white)),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'New name',
              hintStyle: TextStyle(color: Colors.grey[600]),
              errorText: errorText,
              enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.grey),
              ),
              focusedBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.tealAccent),
              ),
            ),
            onChanged: (v) {
              setDialogState(() {
                errorText = validateTmuxSessionName(v, existingNames);
              });
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: errorText != null
                  ? null
                  : () {
                      final newName = controller.text.trim();
                      final err = validateTmuxSessionName(newName, existingNames);
                      if (err != null) {
                        setDialogState(() => errorText = err);
                        return;
                      }
                      Navigator.of(ctx).pop();
                      _doRename(oldName, newName);
                    },
              child: const Text('Rename', style: TextStyle(color: Colors.tealAccent)),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }

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
}
```

親ウィジェット `TmuxManagerScreen` 側でコールバックを渡す:

```dart
// TmuxManagerScreen.build() の asyncState.when(data:) 部分
data: (state) => !state.isAvailable
    ? _NotInstalledView(...)
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
```

**要点**: `_SessionListView` は `ConsumerStatefulWidget` ではなく `StatefulWidget` にする。`ref` を一切使わない。これにより `InheritedWidget` の依存関係チェーンが切れ、`_dependents.isEmpty` assertion が解消される。

## Bug 2: Reconnect ボタンで `AuthenticationError: Authentication aborted`

### 原因

`reconnect()` メソッドに以下の問題がある:

1. **ステータスガードがない**: ユーザーが Reconnect ボタンを連打すると、複数の再接続試行が同時に走り、`_cleanup()` が他の接続試行の途中で呼ばれる
2. **古い接続のクローズを待たない**: `_cleanup()` → `_sshService?.disconnect()` → `_client?.close()` は即座に戻る。しかし SSH サーバーは古い接続をまだアクティブとみなしている可能性がある。新しい接続が即座に開始されると、サーバーが同一ユーザーの並行セッション制限で認証を拒否する
3. **`reconnecting` ステータスに遷移しない**: UI にリコネクト中の表示がされない

### 修正対象ファイル

- `lib/features/terminal/terminal_connection_provider.dart`

### 具体的な変更

```dart
// ===== 変更前 =====
Future<void> reconnect() async {
  if (_config == null) return;
  final existingTerminal = state.terminal;
  _cleanup();
  try {
    final terminal = await _connectCore(
      config: _config!,
      password: _password,
      privateKeyPem: _privateKeyPem,
      passphrase: _passphrase,
      existingTerminal: existingTerminal,
    );
    ...
  } catch (e) {
    ...
  }
}

// ===== 変更後 =====
Future<void> reconnect() async {
  if (_config == null) return;
  // 既に接続中・再接続中・接続済みなら何もしない
  if (state.status == ConnectionStatus.connecting ||
      state.status == ConnectionStatus.reconnecting ||
      state.status == ConnectionStatus.connected) {
    return;
  }

  final existingTerminal = state.terminal;
  // UI に再接続中を表示
  state = state.copyWith(status: ConnectionStatus.reconnecting);

  // 古い接続を確実にクリーンアップ
  _cleanupConnections();
  // サーバーが古い接続を認識解除するまで少し待つ
  await Future.delayed(const Duration(milliseconds: 500));

  try {
    final terminal = await _connectCore(
      config: _config!,
      password: _password,
      privateKeyPem: _privateKeyPem,
      passphrase: _passphrase,
      existingTerminal: existingTerminal,
    );
    if (existingTerminal != null) {
      terminal.write('\r\n\x1B[33m--- Reconnected ---\x1B[0m\r\n');
    }
    state = state.copyWith(
      status: ConnectionStatus.connected,
      terminal: terminal,
      channelManager: _channelManager,
    );
  } catch (e) {
    state = state.copyWith(
      status: ConnectionStatus.disconnected,
      terminal: existingTerminal,
      errorMessage: e.toString(),
      clearChannelManager: true,
    );
  }
}
```

## Bug 3: バックグラウンド復帰で全タブが切断され、手動で再接続が必要

### 原因

Phase 11 で `checkConnection()` から `_autoReconnect()` を削除した。その結果、バックグラウンドで接続が切れるとすべてのタブが「Connection lost」バナーを表示し、ユーザーは各タブで手動 Reconnect が必要になった。

### 修正方針

`checkConnection()` にアクティブタブ限定の自動再接続を復活させる。ただし Phase 11 以前の `_autoReconnect()` とは異なり、`reconnect()` メソッド（Bug 2 で修正済み、ガード・ディレイ付き）を呼ぶ形にする。

### 修正対象ファイル

- `lib/features/terminal/terminal_connection_provider.dart`

### 具体的な変更

```dart
// ===== 変更前 =====
Future<void> checkConnection() async {
  // 接続が生きているなら何もしない
  if (_sshService != null && _sshService!.isConnected) return;
  // 既に切断状態 or 再接続中なら何もしない
  if (state.status == ConnectionStatus.disconnected) return;
  if (state.status == ConnectionStatus.reconnecting) return;
  // 接続が切れていたら切断状態にする（自動再接続はしない）
  _onDisconnected();
}

// ===== 変更後 =====
Future<void> checkConnection() async {
  // 接続が生きているなら何もしない
  if (_sshService != null && _sshService!.isConnected) return;
  // 既に再接続中なら何もしない
  if (state.status == ConnectionStatus.reconnecting) return;
  // 既に切断状態なら何もしない（バナーが既に表示されている）
  if (state.status == ConnectionStatus.disconnected) return;
  // config がない（未接続）なら切断状態にするだけ
  if (_config == null) {
    _onDisconnected();
    return;
  }
  // 接続が切れていたら自動再接続を試みる
  await reconnect();
}
```

これにより:
- バックグラウンド復帰時に `checkConnection()` が呼ばれ、接続が切れていれば `reconnect()` が自動的に呼ばれる
- `reconnect()` は Bug 2 の修正でガード・ディレイ・ステータス管理が入っているため安全
- ターミナル内容（スクロールバック）は保持される
- 新しい PTY セッションが開かれるが、「--- Reconnected ---」メッセージが表示される
- 非アクティブタブは `checkConnection()` が呼ばれないため、切り替え時にユーザーが手動 Reconnect する

### `_onDisconnected()` の修正

`_isReconnecting` フラグを Phase 11 で削除したが、`reconnect()` でステータスが `reconnecting` に設定されるため、`_onDisconnected` で `reconnecting` ガードを復活させる必要がある。

```dart
// ===== 変更前 =====
void _onDisconnected() {
  // 既に切断状態なら無視
  if (state.status == ConnectionStatus.disconnected) return;
  state = state.copyWith(
    status: ConnectionStatus.disconnected,
    errorMessage: 'Connection lost',
    clearChannelManager: true,
  );
}

// ===== 変更後 =====
void _onDisconnected() {
  // 再接続中なら無視（reconnect() が完了を処理する）
  if (state.status == ConnectionStatus.reconnecting) return;
  // 既に切断状態なら無視
  if (state.status == ConnectionStatus.disconnected) return;
  state = state.copyWith(
    status: ConnectionStatus.disconnected,
    errorMessage: 'Connection lost',
    clearChannelManager: true,
  );
}
```

## テストの修正

### `test/features/terminal/terminal_connection_provider_test.dart`

`checkConnection` と `reconnect` のテストを更新:

- `checkConnection` が `reconnect()` を呼ぶようになるが、`_config == null`（初期状態）では `_onDisconnected()` が呼ばれるだけなので既存テストの多くは変更不要
- `reconnect` のステータスガードテストを追加: `connecting` / `reconnecting` / `connected` 状態で `reconnect()` を呼んでも何も起きないことを確認

### `test/features/tmux/tmux_manager_screen_test.dart`

`_SessionListView` のコンストラクタ変更に伴い、テスト内のウィジェット生成を更新（コールバック引数の追加）。

## 実装順序

1. **Bug 1** — `lib/features/tmux/tmux_manager_screen.dart`:
   - `_SessionListView` を `StatefulWidget` に変更
   - `TmuxManagerScreen` からコールバックを渡す
   - `connectionId` パラメータ不要になるので削除

2. **Bug 2** — `lib/features/terminal/terminal_connection_provider.dart`:
   - `reconnect()` にステータスガード追加
   - `reconnecting` ステータスに遷移
   - `_cleanupConnections()` 後に 500ms delay 追加
   - `_onDisconnected()` に `reconnecting` ガード復活

3. **Bug 3** — `lib/features/terminal/terminal_connection_provider.dart`:
   - `checkConnection()` で `reconnect()` を呼ぶように変更

4. テストを更新して全テストが通ることを確認
5. `flutter analyze` でエラーがないことを確認
6. `flutter build apk --debug` でビルド
