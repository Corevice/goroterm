---
goal: "Phase 5 - 安定性改善 & マルチセッション: tmux/ライフサイクル修正・複数ターミナルタブ対応"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 5: 安定性改善 & マルチセッション

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

## 背景

Phase 4 で sqlite3 クラッシュと SSH 鍵認証 UI を修正したが、実機テストで以下の問題が判明した:

1. **`_dependents.isEmpty` assertion エラー**: `TmuxNotifier.build()` と `FileBrowserNotifier.build()` が `ref.watch(terminalConnectionProvider(...))` しているため、drawer 閉時に provider の破棄順序が衝突する
2. **tmux セッション制御の不具合**: `attachSession` が `\n`（LF）を使用しており `\r`（CR）であるべき。exit code の null ハンドリングも不正
3. **バックグラウンド移行で即座に切断**: auto-reconnect がなく、`ConnectivityMonitor` が未接続。keepalive がバックグラウンドで停止し、サーバーが接続を切る
4. **1セッションしか持てない**: タブ UI がなく、Navigator の push/pop で1ターミナルずつしか開けない

スクリーンショット: `tmp/20260308_01/Screenshot_20260308-212727.png`

---

## Step 1: `_dependents.isEmpty` assertion エラーの修正

`TmuxNotifier.build()` と `FileBrowserNotifier.build()` 内の `ref.watch()` が原因で、provider の破棄順序が衝突している。

1. `lib/features/tmux/tmux_provider.dart` の `build()` メソッドを修正する
   - `ref.watch(terminalConnectionProvider(arg).select(...))` を `ref.read(...)` に変更
   - channelManager の変更を検知する必要がある場合は `ref.listen()` を使い、コールバック内で `ref.invalidateSelf()` する
   ```dart
   @override
   Future<TmuxState> build(String arg) async {
     final channelManager = ref.read(
       terminalConnectionProvider(arg).select((s) => s.channelManager));
     ref.listen(terminalConnectionProvider(arg).select((s) => s.channelManager),
       (prev, next) { if (prev != next) ref.invalidateSelf(); });
     if (channelManager == null) throw NetworkError('SSH not connected');
     return _checkAvailability(channelManager);
   }
   ```
2. `lib/features/file_browser/file_browser_provider.dart` の `build()` も同様に修正する
   - `ref.watch()` → `ref.read()` + `ref.listen()` + `ref.invalidateSelf()`
3. 修正後、以下を確認する:
   - TerminalScreen の endDrawer（tmux）を開閉してもクラッシュしない
   - TerminalScreen の drawer（file browser）を開閉してもクラッシュしない
   - TerminalScreen から接続一覧に戻ってもクラッシュしない

### Codex レビュー

```bash
codex exec --full-auto "lib/features/tmux/tmux_provider.dart と lib/features/file_browser/file_browser_provider.dart の build() メソッドで ref.watch を ref.read + ref.listen パターンに修正したコードをレビューしてください。(1) ref.listen のコールバックで ref.invalidateSelf() が正しく使われているか、(2) channelManager が null の場合のエラーハンドリングが適切か、(3) 既存の tmux/file_browser テストが壊れないか。問題があれば修正してください。変更対象: lib/features/tmux/tmux_provider.dart, lib/features/file_browser/file_browser_provider.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 2: tmux セッション制御の修正

tmux のコマンド送信とエラーハンドリングに複数の問題がある。

1. `lib/features/tmux/tmux_provider.dart` を修正する:
   - **`attachSession`**: `\n` → `\r` に変更（SSH/TTY は CR を Enter として認識する）
     ```dart
     terminal.textInput('tmux attach -t $escaped\r');
     ```
   - **`detachSession`**: 同様に `\n` → `\r` に変更
   - **`createSession`**: `_execCommand` 経由なので変更不要（exec チャネルで実行）
   - **`_checkAvailability`**: exit code の null ハンドリングを修正
     ```dart
     // Before (buggy):
     if (exitCode != 0 && exitCode != null) return const TmuxNotInstalled();
     // After:
     if (exitCode == null || exitCode != 0) return const TmuxNotInstalled();
     ```
   - **`_execCommand`**: exit code null の場合も例外を投げるようにする
     ```dart
     if (exitCode == null || exitCode != 0) {
       throw AppError('tmux command failed: $command (exit: $exitCode)');
     }
     ```

2. `lib/features/tmux/tmux_manager_screen.dart` を修正する:
   - **タイマー管理**: `_refreshTimer` を drawer の表示状態と連動させる
     - `initState` で即座にタイマーを開始するのではなく、drawer が実際に表示されている時のみタイマーを動かす
     - ただし `endDrawer` の widget は一度 build されると tree に残るため、別のアプローチが必要:
       - `VisibilityDetector` パッケージを使うか、または `TmuxManagerScreen` をステートレスにして `TerminalScreen` 側でタイマーを制御する
     - 最もシンプルな方法: `TerminalScreen` が `onEndDrawerChanged(bool isOpened)` コールバックで tmux リフレッシュを制御する
       ```dart
       // TerminalScreen の Scaffold に追加:
       onEndDrawerChanged: (isOpened) {
         final notifier = ref.read(tmuxProvider(widget.connectionId).notifier);
         if (isOpened) { notifier.startAutoRefresh(); }
         else { notifier.stopAutoRefresh(); }
       },
       ```
     - `TmuxNotifier` に `startAutoRefresh()` / `stopAutoRefresh()` メソッドを追加
     - `TmuxManagerScreen` から `_refreshTimer` と `WidgetsBindingObserver` を削除

3. tmux 操作のエラーハンドリング改善:
   - `killSession`, `createSession`, `renameSession` の呼び出しに `await` を追加し、エラー時に `SnackBar` を表示する
   - `TmuxManagerScreen` の各操作ボタンに try-catch を追加

### Codex レビュー

```bash
codex exec --full-auto "lib/features/tmux/ の tmux セッション制御修正をレビューしてください。(1) attachSession/detachSession の改行コードが \\r になっているか、(2) exit code の null ハンドリングが正しいか、(3) タイマーが drawer の表示状態と正しく連動しているか、(4) エラーハンドリングが適切か。問題があれば修正してください。変更対象: lib/features/tmux/**, lib/features/terminal/terminal_screen.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 3: バックグラウンド復帰時の自動再接続

バックグラウンドに移行すると OS がソケットをサスペンドし、SSH 接続が切れる。復帰時に自動再接続する仕組みを実装する。

1. `lib/features/terminal/terminal_connection_provider.dart` を修正する:
   - `checkConnection()` を拡張し、切断検知時に自動再接続を試みる
     ```dart
     Future<void> checkConnection() async {
       if (_sshService == null || !_sshService!.isConnected) {
         // 自動再接続を試行（最大3回、1秒間隔）
         await _autoReconnect();
       }
     }

     Future<void> _autoReconnect() async {
       if (_config == null) { _onDisconnected(); return; }
       state = state.copyWith(status: ConnectionStatus.reconnecting);
       for (var i = 0; i < 3; i++) {
         try {
           await connect(
             config: _config!,
             password: _password,
             privateKeyPem: _privateKeyPem,
             passphrase: _passphrase,
           );
           return; // 成功
         } catch (_) {
           if (i < 2) await Future.delayed(const Duration(seconds: 1));
         }
       }
       _onDisconnected(); // 3回失敗したら切断状態にする
     }
     ```
   - `ConnectionStatus` enum に `reconnecting` を追加する（既にある場合はスキップ）
   - `connect()` メソッド内で `_config`, `_password`, `_privateKeyPem`, `_passphrase` を保存する（再接続に必要）

2. `lib/features/terminal/terminal_screen.dart` の `didChangeAppLifecycleState` を修正する:
   - `resumed` 時に再接続中のインジケータを表示する
   - 再接続中は画面にオーバーレイで「再接続中...」を表示
   - 再接続成功時にオーバーレイを除去

3. `lib/core/network/connectivity_monitor.dart` を `TerminalConnectionNotifier` に接続する:
   - `TerminalConnectionNotifier.build()` 内で `ref.listen(connectivityProvider, ...)` する
   - ネットワーク復帰（`NetworkStatus.connected`）検知時に `checkConnection()` を呼ぶ
   - これにより、WiFi→モバイル切替などフォアグラウンドでの接続断にも対応できる

4. 再接続時のターミナル状態維持:
   - `Terminal` オブジェクト（xterm のバッファ）は再接続後も保持する（スクロールバックの内容を消さない）
   - 新しい PTY セッションの stdout を既存の `Terminal` に書き込む
   - 再接続成功時に `\r\n--- Reconnected ---\r\n` をターミナルに表示する

### Codex レビュー

```bash
codex exec --full-auto "バックグラウンド復帰時の自動再接続実装をレビューしてください。(1) _autoReconnect のリトライロジックが正しいか、(2) ConnectivityMonitor の統合が適切か、(3) Terminal バッファが再接続で消えないか、(4) 再接続中のUI表示が適切か、(5) 認証情報の保持にセキュリティ上の問題はないか（メモリ上のパスワード保持）。問題があれば修正してください。変更対象: lib/features/terminal/**, lib/core/network/** のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 4: マルチセッション（複数ターミナルタブ）対応

現在は Navigator の push/pop で1ターミナルしか開けない。タブ UI を追加して複数の SSH セッションを同時に保持できるようにする。

1. **セッション管理モデルを作成する**: `lib/features/terminal/session_manager.dart`
   - `TerminalSession` データクラス: `sessionId` (UUID), `connectionId` (DB int), `label`, `createdAt`
   - `SessionManagerNotifier extends Notifier<List<TerminalSession>>`
     - `addSession(connectionId)` → 新しいセッションを作成し、UUID を生成
     - `removeSession(sessionId)` → セッションを削除、provider を破棄
     - `activeSessionId` → 現在表示中のセッション
     - `setActiveSession(sessionId)` → タブ切替
   - provider の family key を `connectionId`（int → String）から `sessionId`（UUID）に変更する

2. **TerminalScreen をタブ対応に改修する**: `lib/features/terminal/terminal_screen.dart`
   - 画面上部にタブバーを追加する
     ```dart
     TabBar(
       tabs: sessions.map((s) => Tab(
         child: Row(children: [
           Text(s.label),
           IconButton(icon: Icon(Icons.close), onPressed: () => removeSession(s.sessionId)),
         ]),
       )).toList(),
     )
     ```
   - 各タブは `IndexedStack` で保持する（非アクティブタブも widget tree に残し、接続を維持）
   - 「+」タブボタンで接続選択ダイアログを表示し、新しいセッションを追加
   - タブの並び替え（ドラッグ）は将来対応（この Step ではスキップ）

3. **Provider の family key を sessionId に変更する**:
   - `terminalConnectionProvider` の family key: `connectionId` → `sessionId`
   - `tmuxProvider` の family key: 同様
   - `fileBrowserProvider` の family key: 同様
   - `TerminalConnectionNotifier.connect()` に `connectionId` を渡して DB から接続情報をロードする
   - 全ての `ref.read/watch(provider(connectionId))` を `ref.read/watch(provider(sessionId))` に更新

4. **ルーティングを変更する**: `lib/app.dart`
   - `/terminal/{connectionId}` → `/terminal` に変更（セッションは内部で管理）
   - ConnectionListScreen からのタップ時: `SessionManagerNotifier.addSession(connectionId)` を呼び、TerminalScreen に遷移（既に開いている場合はタブ追加のみ）

5. **接続一覧からの遷移を修正する**: `lib/features/connections/connection_list_screen.dart`
   - タップ時の処理:
     ```dart
     onTap: () {
       ref.read(sessionManagerProvider.notifier).addSession(connection.id);
       Navigator.of(context).pushNamedAndRemoveUntil('/terminal', (route) => route.isFirst);
     }
     ```
   - 既に TerminalScreen が表示中なら、新しいタブを追加して切替えるだけ

6. **Provider の keepAlive**:
   - 各 `TerminalConnectionNotifier` に `ref.keepAlive()` を追加（タブ切替時に provider が破棄されないようにする）
   - `SessionManagerNotifier.removeSession()` で明示的に provider を invalidate する

7. **テストを更新する**:
   - 既存の `terminal_screen_test.dart` をタブ対応に更新
   - `session_manager_test.dart` を新規作成: セッション追加・削除・切替のテスト

### Codex レビュー

```bash
codex exec --full-auto "マルチセッション（タブ）対応の実装をレビューしてください。(1) SessionManager のセッション管理が正しいか、(2) IndexedStack でタブ切替時に接続が維持されるか、(3) Provider の family key 変更（connectionId→sessionId）に漏れがないか、(4) タブ追加・削除時のリソース管理（provider invalidate, SSH切断）が正しいか、(5) 既存テストとの互換性。問題があれば修正してください。変更対象: lib/features/terminal/**, lib/features/connections/**, lib/app.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 5: 結合テスト & 動作確認

全修正の統合確認を行う。

1. `~/flutter/bin/flutter analyze` がエラーなしで通ることを確認する
2. `~/flutter/bin/flutter test` で全テストがパスすることを確認する
3. `~/flutter/bin/flutter build apk --debug` でビルドが成功することを確認する
4. 以下のテストケースを追加・更新する:
   - `test/features/tmux/tmux_provider_test.dart`: `\r` 送信、exit code null ハンドリング、タイマー制御
   - `test/features/terminal/terminal_connection_provider_test.dart`: 自動再接続ロジック
   - `test/features/terminal/session_manager_test.dart`: マルチセッション管理
5. 手動テストシナリオ（APK を Android 実機にインストールして確認）:
   - 接続一覧からターミナルを開ける
   - 複数のタブを開いて切替えられる
   - タブを閉じると SSH 接続が切断される
   - tmux 画面を開閉してもクラッシュしない（`_dependents.isEmpty` エラーなし）
   - tmux セッションの attach/detach が正しく動作する
   - バックグラウンドに移行し、復帰後に自動再接続される
   - WiFi→モバイル切替後も自動再接続される

### Codex レビュー

```bash
codex exec --full-auto "Phase 5 の全修正を統合レビューしてください。(1) ~/flutter/bin/flutter analyze がクリーンか、(2) ~/flutter/bin/flutter test で全テストがパスするか、(3) マルチセッション・tmux修正・自動再接続の相互影響で問題がないか。問題があれば修正してください。変更対象: lib/**, test/** のみ。"
```

---

## Expected Outcome

- `_dependents.isEmpty` assertion エラーが発生しない
- tmux セッションの attach/detach/create/kill が正しく動作する
- バックグラウンド復帰後に自動再接続される（最大3回リトライ）
- ネットワーク切替時にも自動再接続される（ConnectivityMonitor 統合）
- 複数のターミナルタブを同時に開ける
- タブ切替時に接続が維持される（IndexedStack）
- タブを閉じると SSH 接続が適切にクリーンアップされる
- 全ての既存テストが引き続きパスする

## 制約

- 既存の Phase 1〜4 の機能を壊さないこと
- Flutter SDK は `~/flutter/bin/flutter` をフルパスで使用すること
- `android/app/build.gradle` の `minSdk: 24`, `compileSdk: 36` を維持すること
- タブの並び替え（ドラッグ&ドロップ）はこの Phase では実装しない
- セッション情報は永続化しない（アプリ再起動でタブはリセット）
- Provider の family key 変更は全ファイルに影響するため、漏れがないよう注意すること
