---
goal: "Phase 8 - 最終安定化: タブ干渉・過剰再接続・tmuxクラッシュ・ダウンロード修正"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 8: 最終安定化

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

## 背景

Phase 7 で `ref.invalidateSelf()` 排除・セパレータ修正等を行ったが、実機テストで以下が残存:

1. **別タブを開くと既存タブが再接続されゼロからになる**: `ConnectivityMonitor` が初期化時に `unknown → connected` 遷移を発火させ、全セッションの `checkConnection()` → `_autoReconnect()` が走る
2. **少し放置すると全セッション（tmux含む）が再接続される**: `connectivity_plus` がモバイル端末のラジオスリープで `none → connected` を頻繁に発火し、再接続が連鎖する。また並行再接続のガードがない
3. **tmux の Rename/Create で赤いエラー画面**: 操作自体は成功するが、直後の `refresh()` 中に `_channelManager` が null になる（connectivity 再接続との競合）、またはドロワー閉じで provider が dispose され `_dependents.isEmpty` が発火
4. **ファイルダウンロードが端末に保存されない**: Android 10+ で `/storage/emulated/0/Download` への直接書き込みに権限がない。共有シート経由でのみ保存可能

### 根本原因の共通テーマ

**Bug 1, 2, 3 は全て `ConnectivityMonitor` の過剰な再接続トリガーが原因**。接続が正常な場合でも `checkConnection()` → `_autoReconnect()` が走り、既存の SSH セッション・PTY チャネル・Terminal オブジェクトが破壊される。

---

## Step 1: ConnectivityMonitor の過剰発火を抑制する

### 問題の本質

- `ConnectivityMonitor.build()` が `NetworkStatus.unknown` を返し、直後に `_checkInitialConnectivity()` が `connected` にする → 全セッションの listener が `unknown → connected` で発火
- モバイル端末のラジオスリープで `none → connected` が頻繁に発生
- 複数セッションの `_autoReconnect()` が同時に走り、レースコンディションで既存セッションも壊れる

### 実装

1. `lib/core/network/connectivity_monitor.dart` を修正する:
   - 初期状態を `connected` に戻す（`unknown` にしない）。ネットワーク接続はほぼ常に利用可能であり、起動時に offline の場合は最初の `onConnectivityChanged` で正しく `disconnected` に遷移する
   ```dart
   @override
   NetworkStatus build() {
     _subscription?.cancel();
     _subscription = Connectivity()
         .onConnectivityChanged
         .listen(_onConnectivityChanged);
     ref.onDispose(() => _subscription?.cancel());
     return NetworkStatus.connected; // 初期状態は connected（起動直後の spurious 遷移を防ぐ）
   }
   ```
   - `_checkInitialConnectivity()` を削除する（不要になる）
   - `NetworkStatus.unknown` を enum から削除する

2. `lib/features/terminal/terminal_connection_provider.dart` の connectivityProvider listener を修正する:
   - **`disconnected → connected` 遷移のみ**を再接続トリガーにする（`unknown → connected` は不要に）
   - debounce を入れる: 最後の遷移から **3秒間** 安定して `connected` を維持した場合のみ `checkConnection()` を実行
   ```dart
   // build() 内の ref.listen を修正
   Timer? _connectivityDebounce;

   ref.listen(connectivityProvider, (prev, next) {
     _connectivityDebounce?.cancel();
     if (prev == NetworkStatus.disconnected && next == NetworkStatus.connected) {
       // 3秒 debounce: ラジオスリープの瞬断を無視する
       _connectivityDebounce = Timer(const Duration(seconds: 3), () {
         checkConnection();
       });
     }
   });
   ```
   - `_cleanup()` で `_connectivityDebounce?.cancel()` を呼ぶ

3. `checkConnection()` を修正する:
   - **接続中の場合は何もしない**（現在接続済みでクライアントが生きている場合はスキップ）
   ```dart
   Future<void> checkConnection() async {
     // 既に接続済みなら何もしない
     if (_sshService != null && _sshService!.isConnected) return;
     // 既に再接続中なら何もしない
     if (state.status == ConnectionStatus.reconnecting) return;
     // 切断を検知 → 再接続
     await _autoReconnect();
   }
   ```

4. `_autoReconnect()` に排他制御を追加する:
   ```dart
   bool _isReconnecting = false;

   Future<void> _autoReconnect() async {
     if (_isReconnecting) return; // 二重再接続防止
     _isReconnecting = true;
     try {
       final existingTerminal = state.terminal;
       state = state.copyWith(status: ConnectionStatus.reconnecting);
       for (var i = 0; i < 3; i++) {
         try {
           _cleanupConnections();
           final terminal = await _connectCore(
             config: _config!,
             password: _password,
             privateKeyPem: _privateKeyPem,
             passphrase: _passphrase,
             existingTerminal: existingTerminal,
           );
           state = state.copyWith(
             status: ConnectionStatus.connected,
             terminal: terminal,
             errorMessage: null,
           );
           return; // 成功
         } catch (_) {
           if (i < 2) await Future.delayed(const Duration(seconds: 2));
         }
       }
       state = state.copyWith(
         status: ConnectionStatus.disconnected,
         terminal: existingTerminal,
         errorMessage: 'Reconnection failed',
       );
     } finally {
       _isReconnecting = false;
     }
   }
   ```

### Codex レビュー

```bash
codex exec --full-auto "ConnectivityMonitor と再接続ロジックの修正をレビューしてください。(1) ConnectivityMonitor.build() が connected を初期値で返すこと、(2) _checkInitialConnectivity() が削除されていること、(3) connectivityProvider listener に 3秒 debounce が入っていること、(4) checkConnection() が接続済みの場合スキップすること、(5) _autoReconnect() に排他制御 (_isReconnecting) が入っていること、(6) NetworkStatus.unknown が削除されていること。問題があれば修正してください。変更対象: lib/core/network/connectivity_monitor.dart, lib/features/terminal/terminal_connection_provider.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 2: tmux Create/Rename の赤いエラー画面を修正する

### 問題の本質

2つの原因が重なっている:

**原因 A**: `createSession()` / `renameSession()` の実行中に `_channelManager` が null になる（Step 1 の過剰再接続が原因 → Step 1 で大幅に緩和されるが、完全には防げない）

**原因 B**: ダイアログを `Navigator.of(ctx).pop()` で閉じた後、`refresh()` → SSH コマンド実行 → `state = AsyncData(...)` が走るが、この時点で tmux provider が dispose されている可能性がある（ドロワーが閉じられた場合）

### 実装

1. `lib/features/tmux/tmux_provider.dart` の `createSession`, `renameSession`, `killSession` を修正する:
   - 各操作メソッドに try-catch を入れ、エラーを `state` に反映しない（SnackBar 通知のみ）:
   ```dart
   Future<void> createSession(String name) async {
     final channelManager = _channelManager;
     if (channelManager == null) return; // 接続切れならスキップ
     final escaped = shellEscape(name);
     await _execCommand(channelManager, 'tmux new-session -d -s $escaped');
     // refresh は安全に — 失敗しても state を壊さない
     await _safeRefresh();
   }

   Future<void> _safeRefresh() async {
     try {
       final channelManager = _channelManager;
       if (channelManager == null) return;
       final sessions = await _fetchSessions(channelManager);
       // dispose 済みでないことを確認
       if (_channelManager != null) {
         state = AsyncData(TmuxState(
           availability: const TmuxAvailable(),
           sessions: sessions,
         ));
       }
     } catch (_) {
       // refresh 失敗は無視（既存データを維持）
     }
   }
   ```
   - 既存の `refresh()` 公開メソッドも `_safeRefresh()` を呼ぶように変更

2. `lib/features/tmux/tmux_manager_screen.dart` を修正する:
   - `_createSession` のエラーハンドリングを改善:
   ```dart
   Future<void> _createSession(String name) async {
     if (!mounted) return;
     try {
       await ref.read(tmuxProvider(widget.connectionId).notifier)
           .createSession(name);
     } catch (e) {
       if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text('セッション作成に失敗: $e')),
         );
       }
     }
   }
   ```
   - `_showCreateDialog` で `Navigator.pop()` の**後**に `_createSession` を呼ぶ（ダイアログの context が無効になるのを防ぐ）:
   ```dart
   onPressed: () {
     final name = controller.text.trim();
     Navigator.of(dialogContext).pop();
     // pop してからセッション作成（ダイアログ context は使わない）
     _createSession(name);
   },
   ```
   - `_showRenameDialog` も同様のパターンに統一する

3. **ドロワー閉じ時の provider dispose を防ぐ**:
   - `tmuxProvider` に `ref.keepAlive()` を追加する（`build()` 内で呼ぶ）
   - これによりドロワーの widget が destroy されても provider は生き続ける
   - provider の破棄は `TerminalScreen` の dispose 時に `ref.invalidate(tmuxProvider(sessionId))` で明示的に行う:
   ```dart
   // tmux_provider.dart の build() 内
   @override
   Future<TmuxState> build(String arg) async {
     ref.keepAlive(); // ドロワー閉じても provider を維持
     // ...
   }
   ```

### Codex レビュー

```bash
codex exec --full-auto "tmux Create/Rename のクラッシュ修正をレビューしてください。(1) createSession/renameSession/killSession 内に try-catch があり state を壊さないこと、(2) _safeRefresh() が channelManager null と dispose 済みを安全に処理すること、(3) ダイアログ pop 後に操作を呼んでいること（pop 前ではないこと）、(4) tmuxProvider に ref.keepAlive() があること、(5) TerminalScreen の dispose で tmuxProvider を invalidate していること。問題があれば修正してください。変更対象: lib/features/tmux/**, lib/features/terminal/terminal_screen.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 3: ファイルダウンロードを正しく端末に保存する

### 問題の本質

Android 10+ (API 29+) では Scoped Storage により、`/storage/emulated/0/Download` への直接書き込みに `WRITE_EXTERNAL_STORAGE` 権限が必要（API 28 以下）、または `MediaStore` API を使う必要がある（API 29+）。現在のコードは直接パス書き込みのため、権限エラーで保存に失敗し、共有シート経由でのみファイルが保存される。

### 実装

1. 方針変更: **全プラットフォームで「一時ファイルにダウンロード → 共有シートで保存」パターンに統一する**
   - MediaStore API は複雑で、プラットフォーム固有のコードが多い
   - `share_plus` の `Share.shareXFiles()` は Android/iOS 両方で「ファイルに保存」オプションを提供する
   - ユーザーが「ダウンロード」に保存するか他のアプリに共有するかを選べる

2. `lib/features/file_browser/file_browser_provider.dart` の `downloadFile` を修正する:
   ```dart
   /// ファイルをダウンロードし、一時ファイルのパスを返す。
   /// UI 側で共有シートを開いてユーザーに保存先を選ばせる。
   Future<String> downloadFile(String remotePath) async {
     final sftp = _requireSftp();

     // 一時ディレクトリにダウンロード
     final tempDir = await getTemporaryDirectory();
     final filename = p.basename(remotePath);
     final tempPath = p.join(tempDir.path, filename);
     final tempFile = File(tempPath);

     // 既存ファイルがあれば削除（前回のダウンロードの残り）
     if (await tempFile.exists()) await tempFile.delete();

     // SFTP からダウンロード
     final stat = await sftp.stat(remotePath);
     final totalSize = stat.size ?? 0;
     var downloaded = 0;

     final remoteFile = await sftp.open(remotePath);
     try {
       final sink = tempFile.openWrite();
       await for (final chunk in remoteFile.read()) {
         sink.add(chunk);
         downloaded += chunk.length;
         if (totalSize > 0) {
           // progress 更新（state の downloadProgress フィールド等）
         }
       }
       await sink.close();
     } finally {
       remoteFile.close();
     }

     return tempPath; // 一時パスを返す
   }
   ```

3. `lib/features/file_browser/file_browser_screen.dart` のダウンロードボタンを修正する:
   - ダウンロード完了後に自動で共有シートを開く:
   ```dart
   onPressed: () async {
     try {
       final path = await ref.read(fileBrowserProvider(connectionId).notifier)
           .downloadFile(remotePath);
       // 共有シートを開く（ユーザーが保存先を選べる）
       await Share.shareXFiles(
         [XFile(path)],
         subject: filename,
       );
       if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text('$filename をダウンロードしました')),
         );
       }
     } catch (e) {
       if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text('ダウンロード失敗: $e')),
         );
       }
     }
   }
   ```

4. `/storage/emulated/0/Download` への直接書き込みコードを削除する（権限問題を完全に回避）

5. `android/app/src/main/AndroidManifest.xml` から不要なストレージ権限を削除する（共有シートは権限不要）

### Codex レビュー

```bash
codex exec --full-auto "ファイルダウンロード修正をレビューしてください。(1) downloadFile() が一時ファイルのパスを返すこと（/storage/emulated/0/Download への直接書き込みがないこと）、(2) UI 側で Share.shareXFiles() が呼ばれること、(3) AndroidManifest.xml に不要な WRITE_EXTERNAL_STORAGE がないこと、(4) 一時ファイルのクリーンアップが適切か。問題があれば修正してください。変更対象: lib/features/file_browser/**, android/app/src/main/AndroidManifest.xml のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 4: 接続安定性の追加改善

Step 1 の再接続ガードに加えて、接続のロバスト性をさらに高める。

### 実装

1. `lib/features/terminal/terminal_connection_provider.dart` を修正する:
   - `didChangeAppLifecycleState(resumed)` の `checkConnection()` にも接続済みガードを適用する（Step 1 で `checkConnection()` 自体にガードを入れたので自動的に適用される）
   - `_onDisconnected()` に debounce を入れる:
     ```dart
     void _onDisconnected() {
       // 既に再接続中なら無視（再接続のクリーンアップで done が発火するのを防ぐ）
       if (_isReconnecting) return;
       if (state.status == ConnectionStatus.disconnected) return; // 既に切断状態

       state = state.copyWith(
         status: ConnectionStatus.disconnected,
         errorMessage: 'Connection lost',
       );
     }
     ```

2. `lib/core/ssh/ssh_client_service.dart` を修正する:
   - `connect()` の socket タイムアウトを 15秒 → 10秒 に短縮（再接続のリトライを速くする）
   - `disconnect()` に安全ガードを追加:
     ```dart
     void disconnect() {
       try {
         _client?.close();
       } catch (_) {
         // close 中のエラーは無視
       } finally {
         _client = null;
       }
     }
     ```

3. `lib/core/ssh/ssh_channel_manager.dart` の `dispose()` に安全ガードを追加:
   ```dart
   void dispose() {
     try { _ptySession?.close(); } catch (_) {}
     try { _sftpClient?.close(); } catch (_) {}
     _ptySession = null;
     _sftpClient = null;
   }
   ```

4. `_connectCore` 内の `_doneSubscription` 設定を改善する:
   - 新しい接続の `client.done` listener 内で、**現在のクライアントと一致する場合のみ** `_onDisconnected()` を呼ぶ:
   ```dart
   final currentClient = client;
   _doneSubscription = client.done.asStream().listen((_) {
     // 古いクライアントの done イベントを無視する
     if (_sshService?.client == currentClient) {
       _onDisconnected();
     }
   });
   ```
   - `SshClientService` に `SSHClient get client => _client` getter を追加（比較用）

### Codex レビュー

```bash
codex exec --full-auto "接続安定性の追加改善をレビューしてください。(1) _onDisconnected に再接続中ガードがあること、(2) disconnect() と dispose() に try-catch があること、(3) done subscription が古いクライアントを無視すること、(4) 全体的にリソースリークがないこと。問題があれば修正してください。変更対象: lib/features/terminal/terminal_connection_provider.dart, lib/core/ssh/ssh_client_service.dart, lib/core/ssh/ssh_channel_manager.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 5: 結合テスト & 動作確認

1. `~/flutter/bin/flutter analyze` がエラーなしで通ることを確認する
2. `~/flutter/bin/flutter test` で全テストがパスすることを確認する
3. `~/flutter/bin/flutter build apk --debug` でビルドが成功することを確認する
4. 以下のテストを追加・更新する:
   - `test/core/network/connectivity_monitor_test.dart`:
     - 初期状態が `connected` であること
     - `_checkInitialConnectivity` が呼ばれないこと
   - `test/features/terminal/terminal_connection_provider_test.dart`:
     - `checkConnection()` が接続済みの場合スキップすること
     - `_autoReconnect()` が二重実行されないこと（`_isReconnecting` ガード）
     - connectivity debounce が機能すること
   - `test/features/tmux/tmux_provider_test.dart`:
     - `createSession` → `_safeRefresh` が channelManager null でもクラッシュしないこと
     - `ref.keepAlive()` が設定されていること
   - `test/features/file_browser/file_browser_provider_test.dart`:
     - `downloadFile` が一時パスを返すこと（`/storage/emulated/0/Download` を使わないこと）
5. 手動テストシナリオ（APK を Android 実機にインストール）:
   - 新しいタブを開いても既存タブのターミナルが再接続されない
   - 30秒〜1分放置しても全セッションが維持される（不要な再接続が起きない）
   - tmux セッションの作成・リネーム・削除がエラー画面なしで動作する
   - SFTP ファイルダウンロード時に共有シートが開き、「ファイルに保存」で Downloads フォルダに保存できる
   - バックグラウンド移行→復帰後、接続が維持されている（30秒以内の復帰なら再接続不要）
   - WiFi OFF → ON で自動再接続される（3秒 debounce 後）
   - 再接続時にターミナル履歴が保持される

### Codex レビュー

```bash
codex exec --full-auto "Phase 8 の全修正を統合レビューしてください。(1) ~/flutter/bin/flutter analyze がクリーンか、(2) ~/flutter/bin/flutter test で全テストがパスするか、(3) ConnectivityMonitor の初期値が connected で _checkInitialConnectivity がないこと、(4) _autoReconnect に _isReconnecting ガードがあること、(5) tmux 操作に _safeRefresh と ref.keepAlive が使われていること、(6) downloadFile が一時パスのみ返すこと。問題があれば修正してください。変更対象: lib/**, test/** のみ。"
```

---

## Expected Outcome

- 新タブ追加時に既存セッションが再接続されない
- アイドル時に不要な再接続が発生しない
- tmux セッションの作成・リネーム・削除がクラッシュなしで動作する
- ファイルダウンロード後に共有シートが開き、Downloads フォルダに保存できる
- SSH 接続が安定し、長時間維持される
- バックグラウンド復帰・ネットワーク切替後に適切に再接続される

## 制約

- Flutter SDK は `~/flutter/bin/flutter` をフルパスで使用すること
- `android/app/build.gradle` の `minSdk: 24`, `compileSdk: 36` を維持
- `ConnectivityMonitor` の初期状態は `connected`（`unknown` は使用禁止 — spurious 遷移を防ぐ）
- `_autoReconnect()` は排他制御必須（`_isReconnecting` フラグ）
- `checkConnection()` は接続済みの場合は即座に return すること
- connectivity listener には 3秒 debounce を入れること
- ファイルダウンロードは一時ファイル + `Share.shareXFiles()` パターンに統一（直接パス書き込み禁止）
- tmux provider に `ref.keepAlive()` を設定し、ドロワー閉じで dispose されないようにすること
