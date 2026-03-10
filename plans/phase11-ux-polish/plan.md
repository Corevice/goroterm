---
goal: "Phase 11 - UX修正: tmuxエラー画面・タブフォーカス・バックグラウンド復帰"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 11: UX修正 — tmuxエラー画面・タブフォーカス・バックグラウンド復帰

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

## 背景

Phase 10 でナビゲーションの根本問題（複数 TerminalScreen インスタンス）を解消し、セッション再接続の問題は解決した。しかし以下の3つの問題が残っている。

## Bug 1: tmux セッションの Rename / 新規作成で赤いエラー画面

### 症状

tmux ドロワーでセッションを作成またはリネームすると Flutter の赤いエラー画面（ErrorWidget）が表示される。操作自体は成功している。

### 原因分析

`tmux_manager_screen.dart` の `_showRenameDialog` で `.catchError()` パターンを使用しているが、Dart の `.catchError` は `Future<void>` に対して型安全ではなく、コールバック内の例外がハンドルされない unhandled future error になる可能性がある。

また、`_createSession` と `_showRenameDialog` で非同期操作の完了を待たずに fire-and-forget でプロバイダメソッドを呼んでいるため、操作中にウィジェットツリーが再構築されたとき、古い `BuildContext` や `WidgetRef` が無効になり `ErrorWidget` が表示される可能性がある。

さらに、`tmux_provider.dart` の `_safeRefresh()` 内で `state = AsyncData(...)` を設定する際、もし何らかの理由でプロバイダが dispose 済みだった場合に `StateError` が発生する可能性がある（`catch (_)` で捕捉されるはずだが念のため強化する）。

### 修正方針

1. `_showRenameDialog` の `.catchError()` を `async/await` + `try-catch` に変換する
2. `_createSession` と新しい `_renameSession` メソッドを統一的に `async/await` + `try-catch` + `mounted` チェックで実装する
3. `_SessionListView` を `ConsumerStatefulWidget` に変更し、非同期操作中の `ref` と `context` の安全性を保証する
4. `asyncState.when()` の `error:` ハンドラをドロワー内に収まるウィジェットに限定する（赤いエラー画面ではなくインラインエラー表示）

### 修正対象ファイル

- `lib/features/tmux/tmux_manager_screen.dart`

### 具体的な変更

#### 変更1: `_SessionListView` を `ConsumerStatefulWidget` に変更

```dart
// Before: ConsumerWidget（非同期操作中に ref/context が無効になるリスク）
class _SessionListView extends ConsumerWidget {
  ...
  Future<void> _showRenameDialog(...) async {
    ...
    ref.read(tmuxProvider(connectionId).notifier)
        .renameSession(oldName, newName)
        .catchError((e) { ... }); // 危険なパターン
  }
}

// After: ConsumerStatefulWidget（mounted チェックで安全性を保証）
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
      await ref
          .read(tmuxProvider(widget.connectionId).notifier)
          .renameSession(oldName, newName);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to rename session: $e')),
        );
      }
    }
  }

  Future<void> _deleteSession(String name) async {
    try {
      await ref
          .read(tmuxProvider(widget.connectionId).notifier)
          .killSession(name);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to kill session: $e')),
        );
      }
    }
  }
  // ... build() と _showRenameDialog, _confirmDelete は既存ロジックを維持するが
  //     .catchError を廃止し、await _renameSession(...) を使用する
}
```

#### 変更2: `_showRenameDialog` 内の `.catchError` を廃止

```dart
// Before:
Navigator.of(ctx).pop();
ref.read(tmuxProvider(connectionId).notifier)
    .renameSession(oldName, newName)
    .catchError((e) { ... });

// After:
Navigator.of(ctx).pop();
_renameSession(oldName, newName); // fire-and-forget だが内部で try-catch + mounted チェック
```

#### 変更3: `_confirmDelete` 内の try-catch を _deleteSession メソッドに統一

```dart
// Before:
if (confirmed == true) {
  try {
    await ref.read(tmuxProvider(connectionId).notifier).killSession(name);
  } catch (e) {
    if (context.mounted) { ... }
  }
}

// After:
if (confirmed == true) {
  await _deleteSession(name);
}
```

## Bug 2: タブ切り替え時にフォーカスが追従しない

### 症状

別タブに切り替えた後、入力エリアをタップしないまま文字を入力すると、前のタブの TerminalView に文字が送られる。

### 原因分析

`IndexedStack` は全ての子ウィジェットを同時にビルドして保持する（`AutomaticKeepAliveClientMixin` 使用）。各タブの `TerminalView` に `autofocus: true` が設定されているが、これは初回ビルド時のみ有効。タブ切り替え時にフォーカスは自動的に移動しない。

結果、前のタブの `TerminalView` が引き続きキーボードフォーカスを持ち、入力がそちらに送られる。

### 修正方針

1. 各 `_TerminalTabContent` に `FocusNode` を追加し、`TerminalView` の `focusNode` パラメータに渡す
2. `_TerminalTabContent` に `isActive` パラメータを追加する
3. `isActive` が `true` に変わったとき `focusNode.requestFocus()` を呼ぶ

### 修正対象ファイル

- `lib/features/terminal/terminal_screen.dart`

### 具体的な変更

#### 変更1: `_TerminalTabContent` に `isActive` パラメータ追加

```dart
class _TerminalTabContent extends ConsumerStatefulWidget {
  const _TerminalTabContent({
    super.key,
    required this.sessionId,
    required this.connectionId,
    required this.isActive, // 追加
  });

  final String sessionId;
  final int connectionId;
  final bool isActive; // 追加
  ...
}
```

#### 変更2: `_TerminalTabContentState` に FocusNode 追加

```dart
class _TerminalTabContentState extends ConsumerState<_TerminalTabContent>
    with AutomaticKeepAliveClientMixin {
  final _terminalController = TerminalController();
  final _focusNode = FocusNode(); // 追加
  ProviderSubscription<SshChannelManager?>? _channelManagerSubscription;

  @override
  void dispose() {
    _channelManagerSubscription?.close();
    _terminalController.dispose();
    _focusNode.dispose(); // 追加
    super.dispose();
  }

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
  ...
}
```

#### 変更3: TerminalView に focusNode を渡す

```dart
// Before:
TerminalView(
  connectionState.terminal!,
  controller: _terminalController,
  autofocus: true,
  ...
)

// After:
TerminalView(
  connectionState.terminal!,
  controller: _terminalController,
  focusNode: _focusNode,
  autofocus: true,
  ...
)
```

#### 変更4: IndexedStack 内の _TerminalTabContent に isActive を渡す

```dart
// Before:
body: IndexedStack(
  index: activeIdx,
  children: sessions
      .map((s) => _TerminalTabContent(
            key: ValueKey(s.sessionId),
            sessionId: s.sessionId,
            connectionId: s.connectionId,
          ))
      .toList(),
),

// After:
body: IndexedStack(
  index: activeIdx,
  children: sessions
      .map((s) => _TerminalTabContent(
            key: ValueKey(s.sessionId),
            sessionId: s.sessionId,
            connectionId: s.connectionId,
            isActive: s.sessionId == activeSession.sessionId,
          ))
      .toList(),
),
```

## Bug 3: バックグラウンド復帰時にアクティブタブだけが再接続されて初期状態に戻る

### 症状

アプリをバックグラウンドにして戻ると、開いているタブ（アクティブタブ）だけが自動再接続されて新しいシェルセッションになり、ターミナルの内容が初期状態に見える。非アクティブタブはそのまま（ターミナル内容が保持される）。

### 原因分析

`terminal_screen.dart` の `didChangeAppLifecycleState` で、アプリ復帰時にアクティブタブの `checkConnection()` を呼んでいる。`checkConnection()` は接続が切れていると `_autoReconnect()` を呼び、新しい SSH 接続 → 新しい PTY セッション → 新しいシェルを開く。

Terminal オブジェクト自体は再利用されるが、新しいシェルのログインバナーやプロンプトが表示されるため、ユーザーにとっては「初期状態に戻った」ように見える。

一方、非アクティブタブは `checkConnection()` が呼ばれないため、接続が切れていても状態変更が起きず、ターミナル内容がそのまま保持される。

### 修正方針

バックグラウンド復帰時に自動再接続（`_autoReconnect`）を呼ばず、代わりに接続状態の確認のみ行う。接続が切れていれば `_onDisconnected` を呼んで「Connection lost」バナーを表示し、ユーザーが手動で「Reconnect」ボタンを押すまで再接続しない。

これにより全タブが統一的な挙動になる：接続が切れたらバナー表示 + ターミナル内容保持。

### 修正対象ファイル

- `lib/features/terminal/terminal_connection_provider.dart`

### 具体的な変更

#### 変更1: `checkConnection()` を自動再接続しないように変更

```dart
// Before:
Future<void> checkConnection() async {
  if (_sshService != null && _sshService!.isConnected) return;
  if (state.status == ConnectionStatus.reconnecting) return;
  if (_config == null) {
    _onDisconnected();
    return;
  }
  await _autoReconnect();
}

// After:
Future<void> checkConnection() async {
  // 接続が生きているなら何もしない
  if (_sshService != null && _sshService!.isConnected) return;
  // 既に切断状態 or 再接続中なら何もしない
  if (state.status == ConnectionStatus.disconnected) return;
  if (state.status == ConnectionStatus.reconnecting) return;
  // 接続が切れていたら切断状態にする（自動再接続はしない）
  // ユーザーが手動で Reconnect ボタンを押すまで待つ
  _onDisconnected();
}
```

これにより:
- アプリ復帰時、接続が切れていれば「Connection lost」バナーが表示される
- ターミナル内容（スクロールバック）は保持される
- ユーザーが「Reconnect」ボタンを押したときのみ `reconnect()` が呼ばれて新しいシェルが開く
- 非アクティブタブと同じ挙動になる（一貫性のあるUX）

## テストの修正

### `test/features/terminal/terminal_connection_provider_test.dart`

`checkConnection` のテストを更新する:

```dart
// 既存テスト: 'checkConnection when never connected transitions to disconnected'
// → _config == null の場合は _onDisconnected → disconnected（変更なし）

// 修正が必要なテスト: checkConnection の挙動変更に伴う期待値の更新
// → _autoReconnect が呼ばれなくなるため、checkConnection 後の状態は
//   disconnected になる（reconnecting にはならない）
```

## 実装順序

1. **Bug 3** を最初に修正（`terminal_connection_provider.dart` の `checkConnection` 変更）
2. **Bug 1** を修正（`tmux_manager_screen.dart` の `.catchError` 廃止 + `ConsumerStatefulWidget` 変換）
3. **Bug 2** を修正（`terminal_screen.dart` の `FocusNode` + `isActive` 追加）
4. テストを更新して全テストが通ることを確認
5. `flutter analyze` でエラーがないことを確認
6. `flutter build apk --debug` でビルド
