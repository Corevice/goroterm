---
goal: "Phase 9 - 根本修正: タブ再接続・過剰再接続・tmuxクラッシュ・ダウンロードUX"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 9: 根本修正

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

## 背景

Phase 4〜8 で多くの修正を重ねたが、実機テストで以下が依然として発生する。ここではコードを完全に読んだ上で、**真の根本原因**を特定し、確実に動作する修正を行う。

### 残存バグ一覧

1. **別タブを開くと既存タブが再接続されゼロからになる**
2. **少し放置すると全セッション（tmux含む）が再接続される**
3. **tmux の Rename/Create で赤いエラー画面（操作自体は成功）**
4. **ファイルダウンロードが端末に保存されない（共有シート経由のみ）**

---

## 根本原因分析

### Bug 1 & 2 共通: 過剰再接続の真の原因

`connectivity_plus` パッケージの `onConnectivityChanged` は、Android の実機で**非常に頻繁に**発火する。WiFi の強度変化、画面 OFF/ON、省電力モードの切替え等で `[ConnectivityResult.none]` → `[ConnectivityResult.wifi]` が瞬間的に繰り返される。

現在の `ConnectivityMonitor` は初期値が `connected` になっているが、`onConnectivityChanged` ストリームの最初のイベント自体が問題。Android では画面を少し暗くするだけで `none` → `wifi` が発火し、`ref.listen` の `prev == disconnected && next == connected` 条件を満たしてしまう。

**さらに重要**: `_TerminalTabContent` の各インスタンスが `WidgetsBindingObserver` として `didChangeAppLifecycleState(resumed)` を監視している。Android で画面が一瞬暗くなるだけで `inactive` → `resumed` が発生し、**全タブの** `checkConnection()` が呼ばれる。`checkConnection()` は `_sshService!.isConnected` で判定するが、dartssh2 の `isClosed` は TCP ソケットが閉じた場合のみ `true` になる。ソケットが生きていれば再接続はスキップされるはず。

**しかし実際にはソケットが閉じている**。これは SSH keepalive（30秒）が原因。Android がバックグラウンドでネットワークソケットをサスペンドし、keepalive パケットが送れなくなると、dartssh2 が接続をクローズする。`client.done` が発火し、`_onDisconnected()` が呼ばれ、`_autoReconnect()` が走る。

**Bug 1 の固有原因**: 新タブを追加すると `TerminalScreen`（`ConsumerWidget`）が rebuild される。`TerminalScreen.build()` の中で `ref.watch(terminalConnectionProvider(activeSession.sessionId))` を呼んでいる（line 40-41）。これはアクティブタブの provider のみ watch しているが、`IndexedStack` の children リスト再生成により Flutter のレンダリングパイプラインが走り、非アクティブタブの `build()` も呼ばれる（`IndexedStack` は全子要素を layout する）。その際 `ref.watch(terminalConnectionProvider(widget.sessionId))` が各タブで発火し、もし provider の状態が変わっていれば全タブが更新される。

### Bug 3: tmux Create/Rename で赤いエラー画面

コードを読むと、`_createSession` / `renameSession` は try-catch 済みで `_safeRefresh()` を使っている。しかし **`TmuxManagerScreen.build()` が `ref.watch(tmuxProvider(widget.connectionId))` している**（line 34）。`_safeRefresh()` が `state = AsyncData(...)` で状態を更新すると、`TmuxManagerScreen` が rebuild される。問題は **`_safeRefresh()` の実行前に `createSession` 内の `_execCommand` が例外を投げる場合**。

`_execCommand` は `exitCode != null && exitCode != 0` の場合に `TmuxError` を投げる。しかし `_createSession` で catch しているので UI には来ないはず。**実際には `asyncState.when(error:)` で赤い画面が出ている**ということは、`tmuxProvider` の `state` が `AsyncError` になっている。これは:

- `setChannelManager(null)` が呼ばれた場合（line 26: `state = AsyncData(TmuxState(availability: TmuxNotInstalled()))`）→ これはエラー画面ではない
- `_initializeState` の catch ブロック（line 40-42: `state = AsyncError(e, st)`）→ **これ**

つまり: `createSession` → `_safeRefresh()` の**途中で** connectivity 変化により再接続が走り → `setChannelManager(null)` → `setChannelManager(newCM)` → `_initializeState(newCM)` が走り → SSH コマンドが失敗して `AsyncError` になる。

### Bug 4: ファイルダウンロードが保存されない

コードを確認すると、`downloadFile()` は一時ファイルにダウンロード → `Share.shareXFiles()` で共有シートを開く。共有シート自体は正しく動作している。ユーザーの期待は「ダウンロードボタンを押したらファイルが端末に保存される」だが、現在は「共有シートで保存先を選ぶ」操作が必要。これは**機能としては正しいが UX が悪い**。

---

## Step 1: connectivity_plus の監視を完全に無効化する

### 方針

`connectivity_plus` による再接続トリガーは Android 実機では有害。SSH の接続状態は `client.done` のみで検知すべき。connectivity の変化は無関係な瞬断を大量に拾うため、**接続の安定性を下げている**。

### 実装

1. `lib/features/terminal/terminal_connection_provider.dart` の `build()` から `ref.listen(connectivityProvider, ...)` を**完全に削除する**:
   ```dart
   @override
   TerminalConnectionState build(String arg) {
     ref.onDispose(_cleanup);
     // ★ connectivityProvider の listen を削除
     // SSH 接続の生死は client.done のみで検知する
     return const TerminalConnectionState();
   }
   ```

2. `_connectivityDebounce` 関連のコードを全て削除する:
   - フィールド `Timer? _connectivityDebounce;` を削除
   - `_cleanupConnections()` 内の `_connectivityDebounce?.cancel();` を削除

3. `lib/core/network/connectivity_monitor.dart` はそのまま残す（将来使う可能性があるため）。ただし `terminal_connection_provider.dart` からは使わない。

4. これにより、再接続は以下の場合のみ発生する:
   - `client.done` が発火（サーバー側が接続を切った、TCP ソケットが閉じた）
   - ユーザーが手動で「Reconnect」ボタンを押した
   - `didChangeAppLifecycleState(resumed)` で `checkConnection()` が呼ばれ、`_sshService!.isConnected` が `false` だった場合

### Codex レビュー

```bash
codex exec --full-auto "terminal_connection_provider.dart から connectivityProvider への依存を完全に削除したことを確認してください。(1) build() 内に ref.listen(connectivityProvider, ...) が存在しないこと、(2) _connectivityDebounce が削除されていること、(3) import 文から connectivity_monitor.dart が削除されていること（他で使っていなければ）。問題があれば修正してください。変更対象: lib/features/terminal/terminal_connection_provider.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 2: didChangeAppLifecycleState の過剰発火を抑制する

### 問題

`_TerminalTabContent` が全タブで `WidgetsBindingObserver` を登録しているため、`resumed` イベントで**全タブの** `checkConnection()` が同時に呼ばれる。さらに、Android では画面の ON/OFF で `inactive → resumed` が頻繁に発生する。

### 実装

1. `_TerminalTabContentState` から `WidgetsBindingObserver` を削除する:
   ```dart
   class _TerminalTabContentState extends ConsumerState<_TerminalTabContent>
       with AutomaticKeepAliveClientMixin {
     // ★ WidgetsBindingObserver を削除
   ```

2. `TerminalScreen` を `ConsumerStatefulWidget` に変更し、**TerminalScreen 側で1つだけ** `WidgetsBindingObserver` を登録する:
   ```dart
   class TerminalScreen extends ConsumerStatefulWidget {
     const TerminalScreen({super.key});
     @override
     ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
   }

   class _TerminalScreenState extends ConsumerState<TerminalScreen>
       with WidgetsBindingObserver {
     @override
     void initState() {
       super.initState();
       WidgetsBinding.instance.addObserver(this);
     }

     @override
     void dispose() {
       WidgetsBinding.instance.removeObserver(this);
       super.dispose();
     }

     @override
     void didChangeAppLifecycleState(AppLifecycleState state) {
       if (state == AppLifecycleState.resumed) {
         // アクティブタブのみ checkConnection する
         final managerState = ref.read(sessionManagerProvider);
         final activeId = managerState.activeSessionId;
         if (activeId != null) {
           ref.read(terminalConnectionProvider(activeId).notifier)
               .checkConnection();
         }
       }
     }

     @override
     Widget build(BuildContext context) {
       // 既存の build() ロジックをここに移動
       // ...
     }
   }
   ```

3. アクティブタブのみ `checkConnection()` を呼ぶことで:
   - 非アクティブタブは不要な再接続が起きない
   - アクティブタブだけ最小限の確認が行われる

4. `checkConnection()` 呼び出しに 1秒 delay を追加する（画面 ON 直後のソケット復旧を待つ）:
   ```dart
   if (state == AppLifecycleState.resumed) {
     // ソケット復旧を少し待ってから確認
     Future.delayed(const Duration(seconds: 1), () {
       if (!mounted) return;
       final managerState = ref.read(sessionManagerProvider);
       final activeId = managerState.activeSessionId;
       if (activeId != null) {
         ref.read(terminalConnectionProvider(activeId).notifier)
             .checkConnection();
       }
     });
   }
   ```

### Codex レビュー

```bash
codex exec --full-auto "WidgetsBindingObserver の修正をレビューしてください。(1) _TerminalTabContentState に WidgetsBindingObserver が存在しないこと、(2) TerminalScreen が ConsumerStatefulWidget で WidgetsBindingObserver を持つこと、(3) didChangeAppLifecycleState でアクティブタブのみ checkConnection を呼ぶこと、(4) 1秒 delay が入っていること。問題があれば修正してください。変更対象: lib/features/terminal/terminal_screen.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 3: tmux Create/Rename のエラー画面を修正する

### 問題の本質

`tmuxProvider` の `state` が `AsyncError` になる原因は `_initializeState()` の catch ブロック。これは `setChannelManager()` 経由で呼ばれるが、再接続が走らなければ（Step 1, 2 で修正済み）発生しにくくなる。

しかし万全を期すため、`_initializeState` のエラーハンドリングも改善する。

### 実装

1. `lib/features/tmux/tmux_provider.dart` の `_initializeState` を修正する:
   - `AsyncError` の代わりに、前回データを維持するか、安全なデフォルト state を設定する:
   ```dart
   Future<void> _initializeState(SshChannelManager channelManager) async {
     // 前回データがあれば AsyncLoading にしない（画面がちらつくのを防ぐ）
     final prev = state.valueOrNull;
     if (prev == null) {
       state = const AsyncLoading();
     }
     try {
       final availability = await _checkAvailability(channelManager);
       if (availability is TmuxNotInstalled) {
         state = AsyncData(TmuxState(availability: availability));
         return;
       }
       final sessions = await _fetchSessions(channelManager);
       state = AsyncData(TmuxState(availability: availability, sessions: sessions));
     } catch (e, st) {
       // ★ AsyncError にしない — 前回データを維持するか、安全な空状態にする
       if (prev != null) {
         state = AsyncData(prev);
       } else {
         state = const AsyncData(TmuxState(availability: TmuxNotInstalled()));
       }
       debugPrint('tmux _initializeState error: $e\n$st');
     }
   }
   ```

2. `refresh()` も同様に `AsyncError` を返さないようにする:
   ```dart
   Future<void> refresh() async {
     final channelManager = _channelManager;
     if (channelManager == null) return; // ★ AsyncError にしない
     // 以下は既存の安全なロジック
     final current = state.valueOrNull;
     if (current == null) {
       _initializeState(channelManager);
       return;
     }
     try {
       final sessions = await _fetchSessions(channelManager);
       state = AsyncData(current.copyWith(sessions: sessions));
     } catch (_) {
       state = AsyncData(current); // エラーでも前回データを維持
     }
   }
   ```

3. `setChannelManager(null)` 時も `AsyncError` にしない（既に対応済み: `AsyncData(TmuxState(availability: TmuxNotInstalled()))` を設定）

4. **`asyncState.when(error:)` の `_ErrorView` を不要にする**:
   - `tmuxProvider` が `AsyncError` を発しなくなるため、`_ErrorView` は理論上到達しなくなる
   - ただし安全のため `_ErrorView` は残しておく（フォールバック）

### Codex レビュー

```bash
codex exec --full-auto "tmux_provider.dart のエラーハンドリング修正をレビューしてください。(1) _initializeState() が AsyncError を state に設定しないこと（前回データ維持 or 安全なデフォルト）、(2) refresh() も AsyncError を設定しないこと、(3) setChannelManager(null) が AsyncData を設定すること、(4) createSession/renameSession が _safeRefresh を使っていること。問題があれば修正してください。変更対象: lib/features/tmux/tmux_provider.dart のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 4: ファイルダウンロード UX の改善

### 問題

現在は「ダウンロード → 共有シート表示」で、ユーザーが共有シートから保存先を選ぶ必要がある。ユーザーの期待は「ダウンロードボタンでファイルが端末に保存される」こと。

### 方針

Android では `MediaStore` API を使って Downloads フォルダに直接保存する。`MediaStore` はアプリの権限に関係なく、アプリが作成するファイルは常に書き込み可能（Scoped Storage でも OK）。

### 実装

1. `lib/features/file_browser/file_browser_provider.dart` の `downloadFile` を修正する:
   ```dart
   import 'dart:io';
   import 'package:flutter/services.dart';

   Future<String> downloadFile(String remotePath) async {
     final sftp = _sftp ?? (throw NetworkError('SFTP not initialized'));
     final current = state.valueOrNull ?? const FileBrowserState();
     final filename = p.basename(remotePath);

     // 一時ファイルにダウンロード
     final tempDir = await getTemporaryDirectory();
     final tempPath = p.join(tempDir.path, filename);
     final tempFile = File(tempPath);
     if (await tempFile.exists()) await tempFile.delete();

     final remoteFile = await sftp.open(remotePath, mode: SftpFileOpenMode.read);
     try {
       final stat = await remoteFile.stat();
       final totalBytes = stat.size ?? 0;

       final sink = tempFile.openWrite();
       try {
         await for (final chunk in remoteFile.read(
           onProgress: (n) {
             if (totalBytes > 0) {
               final cur = state.valueOrNull ?? current;
               state = AsyncData(cur.copyWith(downloadProgress: n / totalBytes));
             }
           },
         )) {
           sink.add(chunk);
         }
       } finally {
         await sink.close();
       }
     } finally {
       await remoteFile.close();
     }

     // Android: Downloads フォルダにコピー（MediaStore 経由）
     String savedPath = tempPath;
     if (Platform.isAndroid) {
       try {
         final downloadsDir = Directory('/storage/emulated/0/Download');
         if (await downloadsDir.exists()) {
           final destPath = p.join(downloadsDir.path, filename);
           final destFile = File(destPath);
           // 同名ファイルが既にあれば番号をつける
           String finalPath = destPath;
           int counter = 1;
           while (await File(finalPath).exists()) {
             final ext = p.extension(filename);
             final base = p.basenameWithoutExtension(filename);
             finalPath = p.join(downloadsDir.path, '$base ($counter)$ext');
             counter++;
           }
           await tempFile.copy(finalPath);
           savedPath = finalPath;
           // MediaStore にスキャンを通知（ファイルマネージャに反映）
           // Android の MediaScannerConnection 相当のため、MethodChannel を使用
         }
       } catch (e) {
         debugPrint('Failed to save to Downloads: $e');
         // フォールバック: 共有シートを開く
         await Share.shareXFiles([XFile(tempPath)], subject: filename);
       }
     } else {
       // iOS: 共有シートを開く
       await Share.shareXFiles([XFile(tempPath)], subject: filename);
     }

     final cur = state.valueOrNull ?? current;
     state = AsyncData(cur.copyWith(
       downloadProgress: null,
       downloadedFilePath: savedPath,
     ));
     return savedPath;
   }
   ```

2. しかし、Android の `/storage/emulated/0/Download` への直接書き込みは **API 30+ (Android 11+) で失敗する可能性がある**。API 30+ では `MANAGE_EXTERNAL_STORAGE` 権限が必要で、Google Play では審査が厳しい。

   **より安全な方法**: `flutter_file_dialog` パッケージを使う。これは Android では `Intent.ACTION_CREATE_DOCUMENT`（SAF = Storage Access Framework）を使い、iOS では `UIDocumentPickerViewController` を使う。ユーザーに保存先フォルダを選ばせる。

3. 最終的な方針（最もシンプルで確実）:
   - `pubspec.yaml` に `flutter_file_dialog: ^3.0.0` を追加
   - `~/flutter/bin/flutter pub get` を実行
   - ダウンロード後に `FlutterFileDialog.saveFile()` を呼ぶ:
     ```dart
     import 'package:flutter_file_dialog/flutter_file_dialog.dart';

     // ダウンロード完了後
     final params = SaveFileDialogParams(
       sourceFilePath: tempPath,
       fileName: filename,
     );
     final savedPath = await FlutterFileDialog.saveFile(params: params);
     ```
   - これにより:
     - Android: システムのファイル保存ダイアログが開く（Downloads がデフォルト）。権限不要
     - iOS: ドキュメントピッカーが開く。権限不要
   - `share_plus` は削除してもよいが、将来のファイル共有用に残しておいてもよい

4. `lib/features/file_browser/file_browser_screen.dart` のダウンロードボタンの UI を修正:
   - SnackBar のメッセージ: `'$filename を保存しました'`（`downloadedFilePath` が null でない場合のみ表示）
   - `Share.shareXFiles` の呼び出しを削除し、`FlutterFileDialog.saveFile` に置き換える

### Codex レビュー

```bash
codex exec --full-auto "ファイルダウンロードの修正をレビューしてください。(1) flutter_file_dialog が pubspec.yaml に追加されていること、(2) downloadFile が一時ファイルにダウンロード後 FlutterFileDialog.saveFile() を呼んでいること、(3) Android/iOS の両方で権限なしで動作すること、(4) share_plus の呼び出しが downloadFile から削除されていること。問題があれば修正してください。変更対象: lib/features/file_browser/**, pubspec.yaml のみ。テスト: ~/flutter/bin/flutter test"
```

---

## Step 5: 結合テスト & 動作確認

1. `~/flutter/bin/flutter analyze` がエラーなしで通ることを確認する
2. `~/flutter/bin/flutter test` で全テストがパスすることを確認する
3. `~/flutter/bin/flutter build apk --debug` でビルドが成功することを確認する
4. テストの更新:
   - `test/features/terminal/terminal_connection_provider_test.dart`:
     - `build()` 内に `connectivityProvider` への listener がないこと
   - `test/features/terminal/terminal_screen_test.dart`:
     - `WidgetsBindingObserver` が TerminalScreen 側にのみ登録されていること
   - `test/features/tmux/tmux_provider_test.dart`:
     - `_initializeState` がエラー時に `AsyncError` を設定しないこと
5. 手動テストシナリオ（APK を Android 実機にインストール）:
   - **タブ追加テスト**: 接続済みのタブがある状態で新タブを開く → 既存タブのターミナルが再接続されない（履歴が消えない）
   - **放置テスト**: 1分間アプリを放置する → 不要な再接続が起きない
   - **画面 OFF/ON テスト**: 画面を OFF にして 5秒後に ON → 再接続が起きない（ソケットが生きていれば）
   - **tmux テスト**: セッション作成・リネーム・削除がエラー画面なしで動作する
   - **ダウンロードテスト**: SFTP でファイルをダウンロード → システムの保存ダイアログが表示される → ファイルマネージャで確認できる
   - **長時間放置テスト**: 5分放置後に操作 → 切断していれば自動再接続（`client.done` ベース）

### Codex レビュー

```bash
codex exec --full-auto "Phase 9 の全修正を統合レビューしてください。(1) terminal_connection_provider.dart に connectivityProvider への listen が存在しないこと、(2) _TerminalTabContentState に WidgetsBindingObserver が存在しないこと、(3) TerminalScreen が ConsumerStatefulWidget で WidgetsBindingObserver を持ち、アクティブタブのみ checkConnection すること、(4) tmux_provider.dart の _initializeState/refresh が AsyncError を state に設定しないこと、(5) downloadFile が FlutterFileDialog.saveFile を使用すること。問題があれば修正してください。変更対象: lib/**, test/** のみ。"
```

---

## Expected Outcome

- 新タブ追加時に既存タブが再接続されない（Terminal 履歴が保持される）
- アプリの放置・画面 OFF/ON で不要な再接続が起きない
- tmux セッションの作成・リネーム・削除がエラー画面なしで動作する
- ファイルダウンロード時にシステムの保存ダイアログが表示され、ファイルが端末に保存される
- SSH 接続は `client.done`（サーバー側切断）のみで切断を検知し、不要な再接続を防ぐ
- `resumed` 時のチェックはアクティブタブのみ、1秒遅延付きで実行される

## 制約

- Flutter SDK は `~/flutter/bin/flutter` をフルパスで使用すること
- `connectivity_plus` の `onConnectivityChanged` を SSH 再接続のトリガーに使用しない（`terminal_connection_provider.dart` から完全に削除）
- `WidgetsBindingObserver` は `TerminalScreen` に1つだけ登録する（`_TerminalTabContent` からは削除）
- `tmuxProvider` は `AsyncError` を state に設定しない（前回データを維持するか安全なデフォルトを使う）
- ファイルダウンロードは `flutter_file_dialog` の `saveFile` を使用する（`share_plus` ではなく）

## 前回までの plan と何が違うか

| 項目 | Phase 8 | Phase 9（今回） |
|------|---------|-----------------|
| connectivity_plus | debounce で緩和 | **完全に削除**（SSH 再接続トリガーから除外） |
| WidgetsBindingObserver | 各タブに登録 | **TerminalScreen に1つだけ** + アクティブタブのみチェック |
| tmux エラー | `_safeRefresh` で緩和 | `_initializeState` と `refresh` が **AsyncError を返さない** |
| ダウンロード | `share_plus` | `flutter_file_dialog`（**システム保存ダイアログ**） |
