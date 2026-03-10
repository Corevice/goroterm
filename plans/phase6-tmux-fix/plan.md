---
goal: "Phase 6 - tmux完全修正 & 再接続改善: provider依存解消・セパレータ修正・Terminal保持"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 6: tmux 完全修正 & 再接続改善

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

## 背景

Phase 5 で `ref.watch` → `ref.read` + `ref.listen` に変更したが、`AsyncNotifier.build()` 内で `ref.listen` を呼ぶこと自体が `_dependents.isEmpty` assertion を引き起こすため、根本的な解決になっていない。加えて以下の問題が残存:

- tmux セッション一覧が表示されない（セパレータ `\x1F` が SSH exec チャネルで正しく伝わらない）
- 再接続時に Terminal オブジェクトが再作成され、スクロールバック履歴が消える
- tmux 操作（createSession 等）が fire-and-forget でエラーが握り潰される

スクリーンショット: `tmp/20260308_02/Screenshot_20260308-224156.png`

---

## Step 1: `_dependents.isEmpty` assertion の根本修正

### 問題の本質

`TmuxNotifier` と `FileBrowserNotifier` は `FamilyAsyncNotifier` であり、`build()` メソッド内で `ref.watch()` も `ref.listen()` も使うと Flutter framework の `_dependents.isEmpty` assertion が発火する。これは Riverpod の `AsyncNotifier` の制約で、`build()` 内で他の provider への依存を直接登録すると、rebuild 時に listener の二重登録が起き、InheritedWidget の破棄順序が崩れる。

### 解決方針

`TmuxNotifier` と `FileBrowserNotifier` が `terminalConnectionProvider` の `channelManager` に依存する構造を、**provider 間の直接依存をなくす**方向で修正する。

### 実装

1. `lib/features/tmux/tmux_provider.dart` を修正する:
   - `build()` から `ref.read(terminalConnectionProvider(...))` と `ref.listen(...)` を**両方とも削除**する
   - 代わりに、`channelManager` を**外部から注入する**パターンに変更:
     ```dart
     class TmuxNotifier extends FamilyAsyncNotifier<TmuxState, String> {
       SshChannelManager? _channelManager;

       /// TerminalScreen から channelManager を受け取る
       void setChannelManager(SshChannelManager? channelManager) {
         if (_channelManager == channelManager) return;
         _channelManager = channelManager;
         if (channelManager != null) {
           ref.invalidateSelf();
         } else {
           state = const AsyncValue.data(TmuxState.notConnected());
         }
       }

       @override
       Future<TmuxState> build(String arg) async {
         final channelManager = _channelManager;
         if (channelManager == null) {
           return const TmuxState.notConnected();
         }
         return _checkAvailability(channelManager);
       }
       // ... 以降のメソッドはそのまま（_channelManager を使う）
     }
     ```
   - `_requireChannelManager()` を `_channelManager` を返すように修正:
     ```dart
     SshChannelManager _requireChannelManager() {
       final cm = _channelManager;
       if (cm == null) throw NetworkError('SSH not connected');
       return cm;
     }
     ```

2. `lib/features/file_browser/file_browser_provider.dart` も同様に修正する:
   - `build()` から `ref.read` / `ref.listen` を削除
   - `setChannelManager(SshChannelManager?)` メソッドを追加
   - `build()` 内では `_channelManager` を使う

3. `lib/features/terminal/terminal_screen.dart` を修正する:
   - `TerminalScreen` （またはタブコンテンツ widget）が `terminalConnectionProvider` を `ref.watch` し、`channelManager` の変化を検知する
   - `channelManager` が変化したら、tmux と file_browser の notifier に `setChannelManager()` を呼ぶ:
     ```dart
     ref.listen(
       terminalConnectionProvider(sessionId).select((s) => s.channelManager),
       (prev, next) {
         ref.read(tmuxProvider(sessionId).notifier).setChannelManager(next);
         ref.read(fileBrowserProvider(sessionId).notifier).setChannelManager(next);
       },
     );
     // 初回設定
     final cm = ref.read(terminalConnectionProvider(sessionId)).channelManager;
     ref.read(tmuxProvider(sessionId).notifier).setChannelManager(cm);
     ref.read(fileBrowserProvider(sessionId).notifier).setChannelManager(cm);
     ```
   - これにより provider 間の直接依存がなくなり、`_dependents.isEmpty` が解消される
   - `ref.listen` は `ConsumerStatefulWidget` の `build()` 内で呼ぶため、widget のライフサイクルに紐づき安全

4. `onEndDrawerChanged` のタイミング問題も解消する:
   - `ref.read(tmuxProvider(...).notifier)` を呼ぶ前に、channelManager が設定済みであることを保証する
   - 設定前に drawer が開かれた場合は何もしない（接続完了を待つ）

### Codex レビュー

```bash
codex exec --full-auto "TmuxNotifier と FileBrowserNotifier の provider 依存修正をレビューしてください。(1) build() 内に ref.watch / ref.read / ref.listen が一切ないこと（terminalConnectionProvider への依存がないこと）、(2) setChannelManager() による注入パターンが正しく動作すること、(3) TerminalScreen 側の ref.listen で channelManager 変化が正しく伝播されること、(4) 既存テストが壊れないこと。問題があれば修正してください。変更対象: lib/features/tmux/tmux_provider.dart, lib/features/file_browser/file_browser_provider.dart, lib/features/terminal/terminal_screen.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 2: tmux セッション一覧の修正（セパレータ問題）

### 問題の本質

`_fetchSessions` が `\x1F`（ASCII Unit Separator、制御文字）をフィールドセパレータとして使っているが、この制御文字が SSH exec チャネルを通過する際に一部のシェルや SSH 実装で正しく伝わらず、`tmux list-sessions -F` の出力が解析不能になる。

### 実装

1. `lib/features/tmux/tmux_provider.dart` の `_fetchSessions` を修正する:
   - セパレータを制御文字 `\x1F` から**表示可能な文字列**に変更する
   - セッション名やウィンドウ数に含まれない安全な区切り文字を使う: `|||`（パイプ3つ）
     ```dart
     static const _sep = '|||';

     Future<List<TmuxSession>> _fetchSessions(SshChannelManager channelManager) async {
       final formatCmd =
           "tmux list-sessions -F "
           "'#{session_name}${_sep}#{session_windows}${_sep}"
           "#{session_attached}${_sep}#{session_created}'";
       final (output, exitCode) = await _runCommand(channelManager, formatCmd);
       // ...
     }
     ```
   - `line.split(_sep)` の結果を検証する（長さが4でない場合はスキップ）
   - デバッグログを追加: パースに失敗した行を `debugPrint` に出す

2. `_runCommand` のエラーハンドリングを改善する:
   - `stderr` も取得する（現在は `stdout` のみ）:
     ```dart
     Future<(String output, String error, int? exitCode)> _runCommand(
         SshChannelManager channelManager, String command) async {
       final session = await channelManager.executeCommand(command);
       final stdoutChunks = await session.stdout.toList();
       final stderrChunks = await session.stderr.toList();
       await session.done;
       final output = utf8.decode(stdoutChunks.expand((c) => c).toList());
       final error = utf8.decode(stderrChunks.expand((c) => c).toList());
       return (output, error, session.exitCode);
     }
     ```
   - `_checkAvailability` と `_fetchSessions` を更新して `error` も処理する

3. `tmux list-sessions` が「no server running」エラーを返す場合の処理:
   - exit code 1 + stderr に "no server running" を含む場合は `TmuxState.noSessions()` を返す（tmux はインストールされているがサーバーが起動していない状態）
   - `TmuxState` に `noSessions` バリアントを追加する（既にあればスキップ）

### Codex レビュー

```bash
codex exec --full-auto "tmux セッション一覧のセパレータ修正をレビューしてください。(1) セパレータが '|||' に変更されているか、(2) _runCommand が stderr も返すようになっているか、(3) tmux list-sessions のエラーケース（no server running、セッション0件）が正しく処理されるか、(4) セッション名にパイプ文字が含まれる場合の処理。問題があれば修正してください。変更対象: lib/features/tmux/tmux_provider.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 3: 再接続時の Terminal オブジェクト保持

### 問題の本質

`_autoReconnect()` は `existingTerminal` を正しく渡しているが、`reconnect()` メソッド（手動再接続ボタン）は `existingTerminal` を渡していないため、手動再接続時にスクロールバック履歴が消える。また、バックグラウンド復帰→自動再接続の場合も、`_cleanup()` が呼ばれるルートを通ると Terminal が失われる可能性がある。

### 実装

1. `lib/features/terminal/terminal_connection_provider.dart` の `reconnect()` を修正する:
   ```dart
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
       state = state.copyWith(
         status: ConnectionStatus.connected,
         terminal: terminal,
         errorMessage: null,
       );
     } catch (e) {
       state = state.copyWith(
         status: ConnectionStatus.disconnected,
         terminal: existingTerminal, // 失敗しても Terminal は保持
         errorMessage: e.toString(),
       );
     }
   }
   ```

2. `_autoReconnect()` も同様に、失敗時に `existingTerminal` を `state` に維持する:
   ```dart
   // リトライ全失敗後
   state = state.copyWith(
     status: ConnectionStatus.disconnected,
     terminal: existingTerminal, // 履歴を保持したまま切断状態に
     errorMessage: 'Reconnection failed after $maxRetries attempts',
   );
   ```

3. 再接続成功時にターミナルに区切り線を表示する:
   ```dart
   if (existingTerminal != null) {
     existingTerminal.write('\r\n\x1B[33m--- Reconnected ---\x1B[0m\r\n');
   }
   ```
   （`\x1B[33m` は黄色、`\x1B[0m` はリセット）

4. `_cleanup()` が Terminal を破棄しないことを確認する:
   - `_cleanup()` の中で `state` をリセットしている箇所があれば、`terminal` フィールドは維持する

### Codex レビュー

```bash
codex exec --full-auto "再接続時の Terminal 保持修正をレビューしてください。(1) reconnect() が existingTerminal を _connectCore に渡しているか、(2) _autoReconnect() が失敗時にも Terminal を state に保持しているか、(3) _cleanup() が Terminal を破棄していないか、(4) 再接続成功時の区切り線表示が正しいか。問題があれば修正してください。変更対象: lib/features/terminal/terminal_connection_provider.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 4: tmux 操作のエラーハンドリング改善

### 問題の本質

`TmuxManagerScreen` が `createSession`, `killSession`, `renameSession` を `await` なしの fire-and-forget で呼んでおり、エラーが発生してもユーザーに通知されない。さらに、未処理の Future 例外がアプリをクラッシュさせる可能性がある。

### 実装

1. `lib/features/tmux/tmux_manager_screen.dart` を修正する:
   - 全ての tmux 操作呼び出しに `await` と `try-catch` を追加する
   - エラー時は `ScaffoldMessenger.of(context).showSnackBar()` で通知する
   - 操作中はローディング表示を出す

   ```dart
   Future<void> _createSession(String name) async {
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

2. `_showCreateDialog` のコールバックを修正する:
   ```dart
   onPressed: () async {
     Navigator.of(dialogContext).pop();
     await _createSession(controller.text.trim());
   },
   ```

3. `_confirmDelete` のコールバックも同様に修正する

4. 各操作ボタンにローディング状態を追加する:
   - `_isOperating` フラグを `State` に追加
   - 操作中はボタンを無効化し、CircularProgressIndicator を表示

### Codex レビュー

```bash
codex exec --full-auto "tmux 操作のエラーハンドリング改善をレビューしてください。(1) createSession/killSession/renameSession の呼び出しが await されているか、(2) try-catch でエラーが SnackBar に表示されるか、(3) 操作中のローディング表示が正しいか、(4) ダイアログ dismiss 後の mounted チェックが適切か。問題があれば修正してください。変更対象: lib/features/tmux/tmux_manager_screen.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 5: 結合テスト & 動作確認

1. `~/flutter/bin/flutter analyze` がエラーなしで通ることを確認する
2. `~/flutter/bin/flutter test` で全テストがパスすることを確認する
3. `~/flutter/bin/flutter build apk --debug` でビルドが成功することを確認する
4. 以下のテストを追加・更新する:
   - `test/features/tmux/tmux_provider_test.dart`:
     - `setChannelManager` で channelManager 注入後に `build()` が正しく動作すること
     - セパレータ `|||` でのパースが正しく動作すること
     - `_runCommand` の stderr 処理
   - `test/features/terminal/terminal_connection_provider_test.dart`:
     - `reconnect()` が `existingTerminal` を保持すること
     - `_autoReconnect()` 失敗時も Terminal が保持されること
5. 手動テストシナリオ（APK を Android 実機にインストール）:
   - tmux ドロワーを開閉してもクラッシュしない（`_dependents.isEmpty` 解消）
   - tmux セッション一覧に既存セッションが表示される
   - tmux セッションの作成・削除・attach・detach が動作する
   - バックグラウンドから復帰後、ターミナル履歴が保持されている
   - 手動「再接続」ボタンでも履歴が保持される
   - ネットワーク切替（WiFi→モバイル）後に自動再接続される

### Codex レビュー

```bash
codex exec --full-auto "Phase 6 の全修正を統合レビューしてください。(1) ~/flutter/bin/flutter analyze がクリーンか、(2) ~/flutter/bin/flutter test で全テストがパスするか、(3) provider 依存チェーンに ref.watch/ref.listen が残っていないこと（tmux/file_browser の build 内）、(4) セパレータが '|||' に統一されていること、(5) reconnect() が existingTerminal を渡していること。問題があれば修正してください。変更対象: lib/**, test/** のみ。"
```

---

## Expected Outcome

- tmux ドロワーの開閉でアプリがクラッシュしない（`_dependents.isEmpty` assertion が完全に解消）
- tmux セッション一覧にサーバー上の既存セッションが正しく表示される
- tmux セッションの作成・削除・リネーム・attach・detach が全て動作する
- tmux 操作失敗時にエラーメッセージが SnackBar で表示される
- バックグラウンド復帰・手動再接続の両方で Terminal のスクロールバック履歴が保持される
- 再接続成功時に「--- Reconnected ---」が黄色で表示される
- 全ての既存テストが引き続きパスする

## 制約

- 既存の Phase 1〜5 の機能を壊さないこと
- Flutter SDK は `~/flutter/bin/flutter` をフルパスで使用すること
- `android/app/build.gradle` の `minSdk: 24`, `compileSdk: 36` を維持すること
- `TmuxNotifier.build()` と `FileBrowserNotifier.build()` の中で `ref.watch` / `ref.read` / `ref.listen` で `terminalConnectionProvider` に依存してはならない（これが `_dependents.isEmpty` の根本原因）
- セパレータはセッション名に含まれにくい `|||` を使用する（`\x1F` は SSH exec チャネルで破損するため使用禁止）
