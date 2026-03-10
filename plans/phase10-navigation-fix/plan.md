---
goal: "Phase 10 - ナビゲーション根本修正: タブ再接続・tmuxクラッシュの真の原因を修正"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 10: ナビゲーション根本修正

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

## 背景

Phase 4〜9 で多くの修正を行ったが、**タブ再接続・tmux クラッシュ・過剰再接続**が依然として発生する。Phase 9 で connectivity_plus の listener を完全削除し、WidgetsBindingObserver も TerminalScreen に統一したが効果がなかった。

**今回、コードを完全に追跡して真の根本原因を特定した。**

## 根本原因（Phase 4〜9 で見落としていた核心）

### ナビゲーションフローの致命的な問題

1. 最初の接続: `ConnectionListScreen` → `pushNamed('/terminal')` → **TerminalScreen instance A** が作成される
2. 「+」ボタン（新タブ追加）: TerminalScreen A の line 100 → `pushNamed('/')` → **新しい ConnectionListScreen** が push される
3. 接続選択: ConnectionListScreen → `addSession()` → `pushNamed('/terminal')` → **TerminalScreen instance B** が作成される

**結果**: Navigator スタックに TerminalScreen が**2つ**存在する:
```
Stack: [ConnectionListScreen] → [TerminalScreen A] → [ConnectionListScreen] → [TerminalScreen B]
```

TerminalScreen B は `sessionManagerProvider` を watch し、全セッション（タブ A で作ったものも含む）の `_TerminalTabContent` を `IndexedStack` で作り直す。これにより:
- タブ A のセッションに対して**新しい `_TerminalTabContent` widget** が作られる
- `initState` → `_startConnection()` が呼ばれ、**同じ sessionId の provider に対して `connect()` が再度呼ばれる**
- `connect()` は `_connectCore()` を呼び、新しい SSH 接続・新しい Terminal オブジェクトを作る
- **既存のターミナル履歴が消え、ゼロからの再接続になる**

### 過剰再接続（放置で全セッション再接続）の原因

TerminalScreen が Navigator スタックに複数存在するため:
- 各 TerminalScreen の `didChangeAppLifecycleState(resumed)` が**全インスタンスで**発火する
- 複数の TerminalScreen が同じ `sessionManagerProvider` を watch し、同じセッションリストで同じ provider に対して操作を行う

### tmux Create/Rename で赤いエラー画面の原因

TerminalScreen B が新しい `_TerminalTabContent` を作る際、`ref.listenManual` で `setChannelManager` を呼ぶ。これが `_initializeState` を走らせ、SSH コマンドを実行する。同時に tmux 操作の `_safeRefresh` も走る。2つの SSH コマンドが同時に走り、一方が失敗する。

---

## 修正方針

**TerminalScreen は Navigator スタック上に常に1つだけ存在するようにする。**

新タブ追加時は Navigator で画面遷移するのではなく、**TerminalScreen 内にモーダルで接続選択画面を表示する**か、**ConnectionListScreen に戻ってから TerminalScreen に `pushReplacement` する**。

---

## Step 1: 新タブ追加のナビゲーションフローを修正する

### 現在の問題のあるフロー

```
TerminalScreen A → push('/') → ConnectionListScreen → push('/terminal') → TerminalScreen B
```
スタックに TerminalScreen が2つ。

### 修正後のフロー（方式A: TerminalScreen 内でダイアログ表示）

```
TerminalScreen → 接続選択ダイアログ → addSession → TerminalScreen が rebuild（同じ instance）
```

### 実装

1. `lib/features/terminal/terminal_screen.dart` の「+」ボタンを修正する:
   - `Navigator.of(context).pushNamed('/')` を**削除**する
   - 代わりに接続選択ダイアログを表示する:
   ```dart
   IconButton(
     icon: const Icon(Icons.add),
     tooltip: 'New terminal tab',
     onPressed: () => _showConnectionPicker(context, ref),
   ),
   ```

2. 接続選択ダイアログを TerminalScreen 内に実装する:
   ```dart
   Future<void> _showConnectionPicker(BuildContext context, WidgetRef ref) async {
     // connectionListProvider から接続一覧を取得
     final connections = await ref.read(connectionListProvider.future);
     if (!context.mounted || connections.isEmpty) return;

     final selected = await showModalBottomSheet<Connection>(
       context: context,
       backgroundColor: Colors.grey[900],
       builder: (ctx) => SafeArea(
         child: Column(
           mainAxisSize: MainAxisSize.min,
           children: [
             const Padding(
               padding: EdgeInsets.all(16),
               child: Text(
                 'Select connection',
                 style: TextStyle(color: Colors.white, fontSize: 16,
                     fontWeight: FontWeight.bold),
               ),
             ),
             ...connections.map((conn) => ListTile(
               leading: const Icon(Icons.dns, color: Colors.tealAccent),
               title: Text(
                 conn.label.isNotEmpty ? conn.label : conn.host,
                 style: const TextStyle(color: Colors.white),
               ),
               subtitle: Text(
                 '${conn.username}@${conn.host}:${conn.port}',
                 style: TextStyle(color: Colors.grey[500]),
               ),
               onTap: () => Navigator.of(ctx).pop(conn),
             )),
           ],
         ),
       ),
     );

     if (selected != null) {
       final label = selected.label.isNotEmpty ? selected.label : selected.host;
       ref.read(sessionManagerProvider.notifier).addSession(
         connectionId: selected.id,
         label: label,
       );
       // TerminalScreen は sessionManagerProvider を watch しているので自動で rebuild される
       // 新しい _TerminalTabContent が作られ、initState で接続が開始される
     }
   }
   ```

3. `connection_provider.dart` の `connectionListProvider` が `import` 可能か確認する（`terminal_screen.dart` から参照するため）

4. `lib/features/connections/connection_list_screen.dart` の `_ConnectionTile.onTap` を修正する:
   - 最初の接続時（TerminalScreen がまだ表示されていない場合）のナビゲーションを修正する:
   ```dart
   onTap: () {
     final label = connection.label.isNotEmpty
         ? connection.label
         : connection.host;
     ref.read(sessionManagerProvider.notifier).addSession(
       connectionId: connection.id,
       label: label,
     );
     // pushNamed ではなく pushReplacementNamed を使う
     // これにより ConnectionListScreen は Navigator スタックから消え、
     // TerminalScreen が唯一の画面になる
     // ただし戻るボタンで ConnectionListScreen に戻れるように
     // pushNamed を維持するが、TerminalScreen から ConnectionListScreen に
     // 戻る導線を別途用意する
     Navigator.of(context).pushNamed('/terminal');
   },
   ```
   - ※ 最初の接続時の `pushNamed('/terminal')` はそのまま。問題は「2回目以降」の push のみ。

### 重要: _startConnection の二重実行防止

同じ `sessionId` の `_TerminalTabContent` が2回 mount されることは今後ないはずだが、安全のため provider 側にガードを入れる:

5. `lib/features/terminal/terminal_connection_provider.dart` の `connect()` にガードを追加する:
   ```dart
   Future<void> connect({...}) async {
     // 既に接続中 or 接続済みなら二重接続しない
     if (state.status == ConnectionStatus.connecting ||
         state.status == ConnectionStatus.connected) {
       return;
     }
     // 以下既存ロジック
   }
   ```

### Codex レビュー

```bash
codex exec --full-auto "新タブ追加のナビゲーション修正をレビューしてください。(1) TerminalScreen の「+」ボタンが pushNamed('/') ではなく接続選択ダイアログを表示すること、(2) ConnectionListScreen の onTap が正しくナビゲーションすること、(3) connect() に二重接続防止ガードがあること、(4) Navigator スタックに TerminalScreen が複数存在しないこと。問題があれば修正してください。変更対象: lib/features/terminal/terminal_screen.dart, lib/features/connections/connection_list_screen.dart, lib/features/terminal/terminal_connection_provider.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 2: TerminalScreen から ConnectionListScreen への「戻る」導線

TerminalScreen 内にダイアログで接続選択を実装したため、全タブを閉じた場合や設定へのアクセス方法を整理する。

### 実装

1. TerminalScreen の AppBar に「戻る（接続一覧）」ボタンを追加する:
   - 既存の drawer ボタンの代わりに、左端にメニューボタンを置く:
   ```dart
   // AppBar に追加（既存の leading を修正）
   leading: PopupMenuButton<String>(
     icon: const Icon(Icons.menu),
     onSelected: (value) {
       switch (value) {
         case 'connections':
           Navigator.of(context).pop(); // ConnectionListScreen に戻る
         case 'settings':
           Navigator.of(context).pushNamed('/settings');
         case 'file_browser':
           Scaffold.of(context).openDrawer();
       }
     },
     itemBuilder: (context) => [
       const PopupMenuItem(value: 'file_browser', child: Text('File Browser')),
       const PopupMenuItem(value: 'connections', child: Text('Connections')),
       const PopupMenuItem(value: 'settings', child: Text('Settings')),
     ],
   ),
   ```
   - または、よりシンプルに: File Browser ボタンはそのまま残し、戻る機能はシステムの Back ボタンに任せる

2. 全タブを閉じた場合の処理:
   ```dart
   // TerminalScreen の build() 内
   if (sessions.isEmpty) {
     // 全タブ閉じたら接続一覧に戻る
     WidgetsBinding.instance.addPostFrameCallback((_) {
       if (mounted) Navigator.of(context).pop();
     });
     return const Scaffold(
       backgroundColor: Colors.black,
       body: Center(child: CircularProgressIndicator()),
     );
   }
   ```

### Codex レビュー

```bash
codex exec --full-auto "TerminalScreen の戻る導線をレビューしてください。(1) 全タブ閉じた場合に ConnectionListScreen に戻ること、(2) メニューやバックボタンで接続一覧に戻れること。問題があれば修正してください。変更対象: lib/features/terminal/terminal_screen.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 3: 過剰再接続の追加対策

Step 1 で TerminalScreen の重複を排除したが、追加の安全策を入れる。

### 実装

1. `_TerminalTabContent.initState` の `_startConnection()` に接続済みチェックを追加する:
   ```dart
   void _startConnection() async {
     // 既に接続済みなら何もしない（TerminalScreen rebuild で remount された場合の保護）
     final currentState = ref.read(terminalConnectionProvider(widget.sessionId));
     if (currentState.status == ConnectionStatus.connected ||
         currentState.status == ConnectionStatus.connecting) {
       return;
     }
     // 以下既存ロジック（DB から接続情報をロード → connect()）
   }
   ```

2. `didChangeAppLifecycleState(resumed)` の `checkConnection()` に接続中チェックを追加する（既に Phase 9 で `checkConnection()` 内に `isConnected` ガードがあるので追加対策は不要だが、念のため確認）

3. SSH keepAlive interval を 30秒 → 15秒 に短縮する（ソケットの生存確認を速くする）:
   - `lib/core/ssh/ssh_client_service.dart` の `keepAliveInterval` を変更:
   ```dart
   keepAliveInterval: const Duration(seconds: 15),
   ```

### Codex レビュー

```bash
codex exec --full-auto "_startConnection の二重実行防止をレビューしてください。(1) initState の _startConnection で接続済みならスキップすること、(2) connect() にも二重接続ガードがあること。問題があれば修正してください。変更対象: lib/features/terminal/terminal_screen.dart, lib/features/terminal/terminal_connection_provider.dart, lib/core/ssh/ssh_client_service.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 4: tmux Create/Rename のエラー画面を完全修正する

Step 1 で TerminalScreen の重複を排除することで、tmux 操作中に `setChannelManager` が呼ばれて `_initializeState` が二重実行される問題は大幅に緩和される。追加の安全策:

### 実装

1. `lib/features/tmux/tmux_provider.dart` に操作中フラグを追加する:
   ```dart
   bool _isOperating = false;

   Future<void> createSession(String name) async {
     if (_isOperating) return;
     _isOperating = true;
     try {
       final channelManager = _channelManager;
       if (channelManager == null) return;
       final escaped = shellEscape(name);
       await _execCommand(channelManager, 'tmux new-session -d -s $escaped');
       await _safeRefresh();
     } catch (_) {
       // エラーは握り潰す（_safeRefresh で前回データが維持される）
     } finally {
       _isReOperating = false;
     }
   }
   ```
   - `renameSession`, `killSession` にも同様のパターンを適用

2. `setChannelManager()` で操作中の場合は `_initializeState` をスキップする:
   ```dart
   void setChannelManager(SshChannelManager? channelManager) {
     if (_channelManager == channelManager) return;
     _channelManager = channelManager;
     if (channelManager != null && !_isOperating) {
       _initializeState(channelManager);
     } else if (channelManager == null) {
       state = const AsyncData(TmuxState(availability: TmuxNotInstalled()));
     }
   }
   ```

3. `tmux_manager_screen.dart` の `_showRenameDialog` で `.catchError()` の代わりに `_TmuxManagerScreenState` に rename メソッドを追加する（`_createSession` と同じパターン）:
   ```dart
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
   ```
   - `_showRenameDialog` で `Navigator.pop()` 後に `_renameSession(oldName, newName)` を呼ぶ

### Codex レビュー

```bash
codex exec --full-auto "tmux 操作のエラーハンドリング修正をレビューしてください。(1) createSession/renameSession/killSession に _isOperating ガードがあること、(2) setChannelManager が操作中の場合 _initializeState をスキップすること、(3) _showRenameDialog が _renameSession メソッド経由で呼ばれること、(4) 全操作に try-catch があること。問題があれば修正してください。変更対象: lib/features/tmux/tmux_provider.dart, lib/features/tmux/tmux_manager_screen.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 5: 結合テスト & 動作確認

1. `~/flutter/bin/flutter analyze` がエラーなしで通ることを確認する
2. `~/flutter/bin/flutter test` で全テストがパスすることを確認する
3. `~/flutter/bin/flutter build apk --debug` でビルドが成功することを確認する
4. テストの更新:
   - `test/features/terminal/terminal_connection_provider_test.dart`:
     - `connect()` が connecting/connected 状態で呼ばれた場合にスキップすること
   - `test/features/terminal/terminal_screen_test.dart`:
     - 接続選択ダイアログが表示されること
   - `test/features/tmux/tmux_provider_test.dart`:
     - `_isOperating` 中に `setChannelManager` が `_initializeState` をスキップすること
5. 手動テストシナリオ（APK を Android 実機にインストール）:
   - **タブ追加テスト（最重要）**: 接続済みのタブがある状態で「+」ボタン → 接続選択ダイアログ → 接続選択 → 新タブが追加される → **既存タブのターミナル履歴が消えない**
   - **放置テスト**: 1分間放置 → 不要な再接続が起きない
   - **tmux テスト**: セッション作成・リネーム・削除がエラー画面なしで動作する
   - **戻る動作**: Back ボタンで接続一覧に戻れる
   - **全タブ閉じ**: 全タブを閉じると接続一覧に自動で戻る

### Codex レビュー

```bash
codex exec --full-auto "Phase 10 の全修正を統合レビューしてください。(1) TerminalScreen の「+」ボタンがダイアログで接続選択すること（pushNamed('/') ではないこと）、(2) Navigator スタックに TerminalScreen が複数存在しないこと、(3) _startConnection と connect() に二重実行防止があること、(4) tmux 操作に _isOperating ガードがあること、(5) 全タブ閉じで ConnectionListScreen に戻ること。問題があれば修正してください。変更対象: lib/**, test/** のみ。"
```

---

## Expected Outcome

- 新タブ追加時に既存タブが再接続されない（TerminalScreen のインスタンスは常に1つ）
- アプリ放置時に不要な再接続が起きない
- tmux セッションの作成・リネーム・削除がエラー画面なしで動作する
- TerminalScreen 内の接続選択ダイアログで新タブを追加できる
- 全タブを閉じると接続一覧に自動で戻る

## 制約

- Flutter SDK は `~/flutter/bin/flutter` をフルパスで使用すること
- **Navigator スタックに TerminalScreen が複数存在してはならない**（これが Phase 4〜9 の全バグの根本原因）
- `connect()` は connecting/connected 状態では二重実行しない
- tmux 操作中は `setChannelManager` → `_initializeState` をスキップする

## Phase 4〜9 で見落としていた真の原因

| Phase | やったこと | 効かなかった理由 |
|-------|-----------|-----------------|
| 5 | ref.watch → ref.listen | TerminalScreen が2つあるので listen も2重に登録される |
| 6 | ref.invalidateSelf 排除 | TerminalScreen B が新しい widget を作り直して _startConnection する |
| 7 | _safeRefresh, ref.keepAlive | TerminalScreen B の initState が connect() を再度呼ぶ |
| 8 | connectivity debounce, _isReconnecting | TerminalScreen B の _startConnection が直接 connect() を呼ぶため debounce は無関係 |
| 9 | connectivity 完全削除, WidgetsBindingObserver 統一 | TerminalScreen が2つあるので WidgetsBindingObserver も2つ登録される。connect() の二重呼出しが真因 |
