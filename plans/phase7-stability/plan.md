---
goal: "Phase 7 - 安定性完全修正: tmux操作クラッシュ・タブ干渉・ダウンロード・接続安定性"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 7: 安定性完全修正

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

## 背景

Phase 6 で tmux セッション一覧は表示されるようになったが、以下の問題が残存:

1. **tmux セッション作成・リネーム時にクラッシュ**: `refresh()` 内の `ref.invalidateSelf()` が build 実行中に再度呼ばれ `_dependents.isEmpty` assertion が発火。また `_execCommand` が `exitCode == null` を失敗と誤判定する
2. **新しいタブを開くと既存セッションがリフレッシュされる**: `_TerminalTabContent.build()` 内の `ref.listen` が毎回再登録され、`setChannelManager` → `ref.invalidateSelf()` が全タブに波及する
3. **ファイルダウンロードがアプリ内部ストレージに保存される**: `getApplicationDocumentsDirectory()` を使用しており、Android の Downloads フォルダに保存されない
4. **接続が全体的に不安定**: SSH クライアントのリソースリーク、done subscription のレース、post-connect タイムアウトなし

---

## Step 1: tmux 操作クラッシュの修正

### 問題 1a: `refresh()` 内の `ref.invalidateSelf()` が build 中に呼ばれる

`refresh()` で `state.valueOrNull` が null（= AsyncLoading 中）のとき `ref.invalidateSelf()` を呼ぶが、`build()` がまだ完了していない状態で再 invalidate すると assertion が発火する。

### 問題 1b: `_execCommand` の `exitCode == null` 誤判定

dartssh2 の `session.exitCode` は `session.done` 完了後でも null になるケースがある。null を失敗として扱うと、成功したコマンドでも `TmuxError` が投げられる。

### 実装

1. `lib/features/tmux/tmux_provider.dart` の `refresh()` を修正する:
   - `ref.invalidateSelf()` を使わず、直接 fetch して state を更新する
   ```dart
   Future<void> refresh() async {
     final channelManager = _channelManager;
     if (channelManager == null) return;
     // build 中かどうかに関わらず安全に更新できる
     try {
       final sessions = await _fetchSessions(channelManager);
       state = AsyncData(TmuxState(
         availability: const TmuxAvailable(),
         sessions: sessions,
       ));
     } catch (e, st) {
       // エラーでも state は更新するが、前回データは維持
       final prev = state.valueOrNull;
       if (prev != null) {
         state = AsyncData(prev); // 前回データを維持してエラーは SnackBar に任せる
       } else {
         state = AsyncError(e, st);
       }
     }
   }
   ```
   - `createSession`, `renameSession`, `killSession` の各メソッドから呼ばれる `refresh()` が安全になる

2. `_execCommand` の exit code 処理を修正する:
   ```dart
   Future<void> _execCommand(SshChannelManager channelManager, String command) async {
     final (output, error, exitCode) = await _runCommand(channelManager, command);
     // exitCode == null は成功として扱う（dartssh2 の制約）
     // exitCode が明確に非ゼロの場合のみエラー
     if (exitCode != null && exitCode != 0) {
       throw TmuxError(
         'Command failed (exit $exitCode): $command\n$error',
         reason: TmuxErrorReason.unknown,
       );
     }
   }
   ```

3. `setChannelManager()` 内の `ref.invalidateSelf()` も同じ問題を起こす可能性がある。安全な更新に変更:
   ```dart
   void setChannelManager(SshChannelManager? channelManager) {
     if (_channelManager == channelManager) return;
     _channelManager = channelManager;
     if (channelManager != null) {
       // ref.invalidateSelf() の代わりに直接 fetch
       _initializeState(channelManager);
     } else {
       state = const AsyncData(TmuxState(availability: TmuxNotInstalled()));
     }
   }

   Future<void> _initializeState(SshChannelManager channelManager) async {
     state = const AsyncLoading();
     try {
       final result = await _checkAvailability(channelManager);
       state = AsyncData(result);
     } catch (e, st) {
       state = AsyncError(e, st);
     }
   }
   ```

4. `FileBrowserNotifier` の `setChannelManager()` も同様に `ref.invalidateSelf()` を排除する

### Codex レビュー

```bash
codex exec --full-auto "tmux_provider.dart と file_browser_provider.dart を確認してください。(1) refresh() 内に ref.invalidateSelf() が存在しないこと、(2) setChannelManager() 内に ref.invalidateSelf() が存在しないこと、(3) _execCommand で exitCode == null を成功として扱っていること、(4) 状態更新が全て直接 state = AsyncData/AsyncError で行われていること。問題があれば修正してください。変更対象: lib/features/tmux/tmux_provider.dart, lib/features/file_browser/file_browser_provider.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 2: 新タブ追加時の既存セッション干渉の修正

### 問題の本質

`_TerminalTabContent.build()` 内で `ref.listen` を呼んでいるため、親 widget の rebuild（新タブ追加で `sessionManagerProvider` が変化）で全タブの `build()` が再実行され、`ref.listen` が再登録される。再登録時に listener が発火し、`setChannelManager()` → 状態更新が波及する。

### 実装

1. `lib/features/terminal/terminal_screen.dart` の `_TerminalTabContent` を修正する:
   - `ref.listen` を `build()` から `initState()` に移動する
   - `ConsumerStatefulWidget` の `initState` では `ref.listenManual` を使う:
   ```dart
   ProviderSubscription? _channelManagerSubscription;

   @override
   void initState() {
     super.initState();
     // initState で一度だけ登録（rebuild で再登録されない）
     WidgetsBinding.instance.addPostFrameCallback((_) {
       _channelManagerSubscription = ref.listenManual(
         terminalConnectionProvider(widget.sessionId).select((s) => s.channelManager),
         (prev, next) {
           ref.read(tmuxProvider(widget.sessionId).notifier).setChannelManager(next);
           ref.read(fileBrowserProvider(widget.sessionId).notifier).setChannelManager(next);
         },
         fireImmediately: true, // 初回も発火して channelManager を設定
       );
     });
     _startConnection();
   }

   @override
   void dispose() {
     _channelManagerSubscription?.close();
     super.dispose();
   }
   ```
   - `build()` から `ref.listen(terminalConnectionProvider(...).select(...), ...)` を完全に削除する
   - `build()` 内の初回 `setChannelManager` 呼び出しも削除（`fireImmediately: true` で代替）

2. `IndexedStack` の children を `const` で保持することは不可能だが、`AutomaticKeepAliveClientMixin` を使って widget の再構築を最小化する:
   - `_TerminalTabContentState` に `AutomaticKeepAliveClientMixin` を mixin
   - `wantKeepAlive` を `true` にする

### Codex レビュー

```bash
codex exec --full-auto "_TerminalTabContent の ref.listen 修正をレビューしてください。(1) build() 内に ref.listen が存在しないこと、(2) ref.listenManual が initState 内で一度だけ登録されていること、(3) dispose で subscription が close されていること、(4) 新タブ追加時に既存タブの terminal が再初期化されないこと。問題があれば修正してください。変更対象: lib/features/terminal/terminal_screen.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 3: ファイルダウンロードをシステムの Downloads フォルダに保存

### 問題の本質

`getApplicationDocumentsDirectory()` はアプリ内部ストレージを返すため、ユーザーがファイルマネージャーからダウンロードしたファイルを見つけられない。

### 実装

1. `pubspec.yaml` に以下のパッケージを追加する:
   ```yaml
   dependencies:
     share_plus: ^10.0.0        # ファイル共有（iOS 向け + Android フォールバック）
     permission_handler: ^11.0.0 # ストレージ権限リクエスト
   ```
   `~/flutter/bin/flutter pub get` を実行する

2. `android/app/src/main/AndroidManifest.xml` に権限を追加する:
   ```xml
   <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"
       android:maxSdkVersion="28" />
   ```
   ※ Android 10 (API 29) 以降は Scoped Storage のため不要

3. `lib/features/file_browser/file_browser_provider.dart` の `downloadFile` を修正する:
   ```dart
   Future<String> downloadFile(String remotePath) async {
     final sftp = _requireSftp();

     // 一時ファイルにダウンロード
     final tempDir = await getTemporaryDirectory();
     final filename = p.basename(remotePath);
     final tempPath = p.join(tempDir.path, filename);
     final tempFile = File(tempPath);

     // SFTP からダウンロード
     final remoteFile = await sftp.open(remotePath);
     try {
       final sink = tempFile.openWrite();
       await for (final chunk in remoteFile.read()) {
         sink.add(chunk);
       }
       await sink.close();
     } finally {
       remoteFile.close();
     }

     // Android: Downloads フォルダにコピー
     if (Platform.isAndroid) {
       final downloadsDir = Directory('/storage/emulated/0/Download');
       if (await downloadsDir.exists()) {
         final destPath = p.join(downloadsDir.path, filename);
         await tempFile.copy(destPath);
         await tempFile.delete();
         return destPath;
       }
     }

     // iOS / フォールバック: アプリドキュメントに保存して共有シートを開く
     final docsDir = await getApplicationDocumentsDirectory();
     final destPath = p.join(docsDir.path, filename);
     await tempFile.copy(destPath);
     await tempFile.delete();
     return destPath;
   }
   ```

4. `lib/features/file_browser/file_browser_screen.dart` のダウンロード成功時 UI を修正する:
   - SnackBar のメッセージを「ダウンロード完了」に変更（内部パスを表示しない）
   - 「開く」アクションを SnackBar に追加:
     ```dart
     SnackBar(
       content: Text('$filename をダウンロードしました'),
       action: SnackBarAction(
         label: '共有',
         onPressed: () {
           Share.shareXFiles([XFile(localPath)]);
         },
       ),
     )
     ```
   - iOS の場合はダウンロード完了後に自動で共有シートを開く

5. Android API 29+ (Scoped Storage) 対応:
   - `MediaStore` を使った保存は複雑なため、この Phase では `/storage/emulated/0/Download` への直接書き込みを使用する（`requestLegacyExternalStorage` が build.gradle の `android:requestLegacyExternalStorage="true"` でフォールバック可能）
   - `android/app/src/main/AndroidManifest.xml` の `<application>` タグに追加:
     ```xml
     android:requestLegacyExternalStorage="true"
     ```
   - ※ API 30+ ではこのフラグは無視されるが、`/storage/emulated/0/Download` への書き込みはアプリが作成したファイルに限り許可されるため、新規ファイルの保存は可能

### Codex レビュー

```bash
codex exec --full-auto "ファイルダウンロードの修正をレビューしてください。(1) Android で Downloads フォルダに保存されるか、(2) iOS で共有シートが開くか、(3) AndroidManifest.xml の権限設定が正しいか、(4) Scoped Storage (API 29+) で動作するか、(5) SnackBar の表示が適切か。問題があれば修正してください。変更対象: lib/features/file_browser/**, pubspec.yaml, android/app/src/main/AndroidManifest.xml のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 4: SSH 接続安定性の改善

### 問題一覧

| ID | 問題 | ファイル |
|----|------|----------|
| 4a | `connect()` の catch ブロックで `_cleanupConnections()` が呼ばれず SSH クライアントがリーク | `terminal_connection_provider.dart` |
| 4b | `_doneSubscription` が新セッション開始後に旧セッションの close を検知して即座に切断状態にする可能性 | `terminal_connection_provider.dart` |
| 4c | 接続後の read タイムアウトがなく、TCP が死んでも検知できない | `ssh_client_service.dart` |
| 4d | `ConnectivityMonitor` の初期状態が常に `connected` で、オフライン起動時に誤判定 | `connectivity_monitor.dart` |
| 4e | `openPtyChannel` 失敗時に channelManager が cleanup されない | `terminal_connection_provider.dart` |

### 実装

1. `lib/features/terminal/terminal_connection_provider.dart` を修正する:

   **4a & 4e: connect() の catch ブロックにクリーンアップを追加**
   ```dart
   Future<void> connect({...}) async {
     try {
       final terminal = await _connectCore(...);
       state = state.copyWith(
         status: ConnectionStatus.connected,
         terminal: terminal,
       );
     } catch (e) {
       _cleanupConnections(); // SSH クライアントとチャネルを確実に解放
       state = state.copyWith(
         status: ConnectionStatus.disconnected,
         errorMessage: e.toString(),
       );
     }
   }
   ```

   **4b: done subscription のレース防止**
   ```dart
   Future<Terminal> _connectCore({...}) async {
     // 新しい接続を開始する前に、旧 subscription を確実にキャンセル
     _doneSubscription?.cancel();
     _doneSubscription = null;

     // ... SSH 接続処理 ...

     // 新しい client の done を監視（旧 client の done は既にキャンセル済み）
     _doneSubscription = client.done.asStream().listen((_) {
       // 現在の client と一致する場合のみ切断処理
       if (_sshService?.isConnected == false) {
         _onDisconnected();
       }
     });
   }
   ```

2. `lib/core/ssh/ssh_client_service.dart` を修正する:

   **4c: 接続後のヘルスチェック追加**
   - dartssh2 には read タイムアウトの設定がないため、アプリ側で定期的なヘルスチェックを行う
   - `SshClientService` に `isAlive()` メソッドを追加:
     ```dart
     Future<bool> isAlive() async {
       if (_client == null || _client!.isClosed) return false;
       try {
         // 軽量なコマンドで生存確認（タイムアウト付き）
         await _client!.run('echo ok').timeout(
           const Duration(seconds: 5),
           onTimeout: () => throw TimeoutException('SSH health check timeout'),
         );
         return true;
       } catch (_) {
         return false;
       }
     }
     ```
   - `TerminalConnectionNotifier.checkConnection()` で `isAlive()` を使用:
     ```dart
     Future<void> checkConnection() async {
       if (_sshService == null) { _onDisconnected(); return; }
       final alive = await _sshService!.isAlive();
       if (!alive) {
         await _autoReconnect();
       }
     }
     ```

3. `lib/core/network/connectivity_monitor.dart` を修正する:

   **4d: 初期状態を実際のネットワーク状態から取得**
   ```dart
   @override
   NetworkStatus build() {
     _subscription?.cancel();
     _subscription = Connectivity()
         .onConnectivityChanged
         .listen(_onConnectivityChanged);
     ref.onDispose(() => _subscription?.cancel());
     // 初期状態を非同期で取得し、結果が来たら更新
     _checkInitialConnectivity();
     return NetworkStatus.unknown; // 初期状態は unknown
   }

   Future<void> _checkInitialConnectivity() async {
     final result = await Connectivity().checkConnectivity();
     _onConnectivityChanged(result);
   }
   ```
   - `NetworkStatus` enum に `unknown` を追加
   - `TerminalConnectionNotifier` の listener で `unknown` → `connected` への変化も再接続トリガーにする

4. `lib/core/ssh/ssh_channel_manager.dart` の `dispose()` を安全に:
   ```dart
   void dispose() {
     _ptySession?.close();
     _sftpClient?.close();
     _ptySession = null;
     _sftpClient = null;
     // SSHClient の close は SshClientService.disconnect() が担当するため
     // ここでは close しない（二重 close 防止）
     // ただし、このメソッドが単独で呼ばれた場合のために参照は保持
   }
   ```

### Codex レビュー

```bash
codex exec --full-auto "SSH 接続安定性の修正をレビューしてください。(1) connect() の catch ブロックで _cleanupConnections() が呼ばれているか、(2) done subscription のレース条件が解消されているか、(3) isAlive() ヘルスチェックが正しく動作するか、(4) ConnectivityMonitor の初期状態が unknown で、実際の状態を非同期取得しているか、(5) 全体的にリソースリークがないか。問題があれば修正してください。変更対象: lib/features/terminal/terminal_connection_provider.dart, lib/core/ssh/ssh_client_service.dart, lib/core/ssh/ssh_channel_manager.dart, lib/core/network/connectivity_monitor.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 5: 結合テスト & 動作確認

1. `~/flutter/bin/flutter analyze` がエラーなしで通ることを確認する
2. `~/flutter/bin/flutter test` で全テストがパスすることを確認する
3. `~/flutter/bin/flutter build apk --debug` でビルドが成功することを確認する
4. 以下のテストを追加・更新する:
   - `test/features/tmux/tmux_provider_test.dart`:
     - `refresh()` が build 中に呼ばれてもクラッシュしないこと
     - `_execCommand` で exitCode null が成功として扱われること
     - `createSession` / `renameSession` がエラーなく完了すること
   - `test/features/terminal/terminal_screen_test.dart`:
     - 新タブ追加時に既存タブの Terminal が再初期化されないこと
   - `test/features/file_browser/file_browser_provider_test.dart`:
     - downloadFile が正しいパスに保存すること
   - `test/features/terminal/terminal_connection_provider_test.dart`:
     - connect() 失敗時に _cleanupConnections が呼ばれること
     - checkConnection() で isAlive() が使われること
5. 手動テストシナリオ（APK を Android 実機にインストール）:
   - tmux セッションの作成・リネーム・削除が動作する（クラッシュなし）
   - 新タブを開いても既存タブのターミナルが再初期化されない
   - SFTP でファイルをダウンロードすると Android の Downloads フォルダに保存される
   - ファイルマネージャーからダウンロードしたファイルが見える
   - バックグラウンドから復帰後、自動再接続される
   - WiFi→モバイル切替後も自動再接続される
   - 長時間放置後も接続が維持される（keepalive + health check）

### Codex レビュー

```bash
codex exec --full-auto "Phase 7 の全修正を統合レビューしてください。(1) ~/flutter/bin/flutter analyze がクリーンか、(2) ~/flutter/bin/flutter test で全テストがパスするか、(3) ref.invalidateSelf() が tmux_provider.dart と file_browser_provider.dart に存在しないこと、(4) terminal_screen.dart の build() 内に ref.listen が存在しないこと、(5) downloadFile が Downloads フォルダを使用していること。問題があれば修正してください。変更対象: lib/**, test/** のみ。"
```

---

## Expected Outcome

- tmux セッションの作成・リネーム・削除がクラッシュせずに動作する
- 新タブを追加しても既存タブの SSH セッションが干渉されない
- SFTP でダウンロードしたファイルが Android の Downloads フォルダに保存される
- ダウンロード完了後に「共有」ボタンが表示される
- SSH 接続が安定し、長時間維持される
- バックグラウンド復帰・ネットワーク切替後に自動再接続される
- 接続失敗時にリソースリークが発生しない

## 制約

- Flutter SDK は `~/flutter/bin/flutter` をフルパスで使用すること
- `android/app/build.gradle` の `minSdk: 24`, `compileSdk: 36` を維持
- `TmuxNotifier` と `FileBrowserNotifier` 内で `ref.invalidateSelf()` を使用禁止（直接 `state = AsyncData(...)` で更新）
- `_TerminalTabContent.build()` 内で `ref.listen` を使用禁止（`initState` で `ref.listenManual` を使用）
- ダウンロード先は Android: `/storage/emulated/0/Download`、iOS: 共有シート経由
- `exitCode == null` は dartssh2 の制約として成功扱いにする
