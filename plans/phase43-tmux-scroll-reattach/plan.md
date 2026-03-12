---
goal: "Phase 43 - tmux セッション内スクロール/選択修正 + 全タブ tmux リアタッチ"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 43: tmux セッション内スクロール/選択修正 + 全タブ tmux リアタッチ

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題

### 問題 1: tmux セッション一覧からタブを開いた後、スクロールや文字選択が効かない

tmux ドロワーからセッションを選択してタブを開いた場合に、
ターミナル内でのタッチスクロールや文字選択が正常に動作しない。
手動で `tmux attach` を入力した場合は問題ない。

**原因分析:**

tmux ドロワーは `Scaffold.endDrawer` として実装されている。
ドロワーが閉じた後に以下の問題が発生する可能性がある:

1. **フォーカスが戻らない**: ドロワーが開いている間、Flutter はドロワーにフォーカスを移す。
   ドロワーが閉じたとき、`_focusNode.requestFocus()` は `didUpdateWidget` で
   `isActive` が変わったときのみ呼ばれる。既に active だったタブでドロワーを開閉した場合、
   `isActive` は変わらないためフォーカスが戻らない。

2. **新しいタブの場合**: `addTmuxSession` で新しいタブが作成されると、
   `isActive` は `true` で作成される。`didUpdateWidget` は `oldWidget.isActive = false`
   （初期値）→ `widget.isActive = true` で発火するが、ドロワーの `Navigator.pop()`
   アニメーション中に `requestFocus` が競合する可能性がある。

3. **既存タブに切り替えの場合**: `findSessionByTmux` で既存タブが見つかると
   `setActiveSession` のみ呼ばれる。この場合も同じフォーカス問題。

### 問題 2: アプリ復帰時の tmux リアタッチが開いているタブでしか動作しない

アプリ復帰時に `checkConnection()` は全セッションに対して呼ばれるが、
`_autoReattachTmux` は 500ms の固定 delay で `tmux attach` を送信する。

全タブが同時に reconnect → 全タブが同時に 500ms 後に `tmux attach` を送信すると:
- SSH サーバーが複数の同時接続を処理する間にシェル初期化の遅延が生じる
- 一部のタブでは 500ms 後にまだシェルが ready でなく、`tmux attach` コマンドが
  ログイン処理中（.bashrc 実行中等）に流れてしまい、コマンドとして認識されない
- アクティブなタブは SSH サーバーが最初に処理するため成功しやすい

---

## 修正方針

### 問題 1 の修正: ドロワー閉じた後にフォーカスを明示的に戻す

`_attachTmuxSession` でドロワーが閉じた後、少し遅延してからアクティブタブの
`_focusNode` にフォーカスを要求する。

また、`onEndDrawerChanged` (ドロワー閉じイベント) でもフォーカスを戻す。

### 問題 2 の修正: シェル ready 待機 + タブごとのリアタッチ遅延

固定 500ms delay ではなく、PTY の stdout からデータが来る（＝シェルが起動した）のを
待ってから `tmux attach` を送信する。タイムアウト付き。

---

## 実装手順

### ステップ 1: ドロワー閉じた後のフォーカス復帰

**ファイル:** `lib/features/terminal/terminal_screen.dart`

`_TerminalScreenState` に `onEndDrawerChanged` を追加して、
endDrawer（tmux ドロワー）が閉じたときにアクティブタブのフォーカスを復帰する。

現在の `Scaffold` には `onEndDrawerChanged` が設定されていないはず。

まず、Scaffold の `onEndDrawerChanged` を確認し、設定する。

```dart
// BEFORE (Scaffold 内、onEndDrawerChanged がない場合):
        endDrawer: activeSession != null
            ? Drawer(

// AFTER:
        onEndDrawerChanged: (isOpened) {
          if (!isOpened) {
            // ドロワーが閉じたらアクティブタブのフォーカスを復帰。
            // ドロワーのアニメーション完了を待つため 300ms 遅延。
            Future.delayed(const Duration(milliseconds: 300), () {
              if (!mounted) return;
              // アクティブタブの _TerminalTabContent にフォーカス復帰を通知。
              // _focusNode は _TerminalTabContent 内なので、setState で
              // isActive の再評価をトリガーする。
              setState(() {});
            });
          }
        },
        endDrawer: activeSession != null
            ? Drawer(
```

ただし、上記の `setState` だけでは `_TerminalTabContent.didUpdateWidget` が
`isActive` の変化なしでは `requestFocus` を呼ばない。

代わりに、`_TerminalTabContent` にドロワーが閉じたことを通知する仕組みを追加する。

**より簡単なアプローチ:** `_TerminalTabContentState` で `onEndDrawerChanged` を検知し、
ドロワーが閉じたらフォーカスを要求する。

`_TerminalScreenState` に通知用の `ValueNotifier` を追加:

```dart
// BEFORE (_TerminalScreenState 内):
  final _scaffoldKey = GlobalKey<ScaffoldState>();

// AFTER:
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _drawerClosedNotifier = ValueNotifier<int>(0);
```

`Scaffold.onEndDrawerChanged`:

```dart
// Scaffold 内に追加:
        onEndDrawerChanged: (isOpened) {
          if (!isOpened) {
            _drawerClosedNotifier.value++;
          }
        },
```

`_TerminalTabContent` に notifier を渡す:

```dart
// BEFORE:
              .map((s) => _TerminalTabContent(
                    key: ValueKey(s.sessionId),
                    sessionId: s.sessionId,
                    connectionId: s.connectionId,
                    isActive: s.sessionId == managerState.activeSessionId,
                    tmuxSessionName: s.tmuxSessionName,
                  ))

// AFTER:
              .map((s) => _TerminalTabContent(
                    key: ValueKey(s.sessionId),
                    sessionId: s.sessionId,
                    connectionId: s.connectionId,
                    isActive: s.sessionId == managerState.activeSessionId,
                    tmuxSessionName: s.tmuxSessionName,
                    drawerClosedNotifier: _drawerClosedNotifier,
                  ))
```

`_TerminalTabContent` にフィールド追加:

```dart
// BEFORE:
  final String? tmuxSessionName;

// AFTER:
  final String? tmuxSessionName;
  final ValueNotifier<int>? drawerClosedNotifier;
```

`_TerminalTabContentState` で notifier を listen:

```dart
// BEFORE (initState 内):
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _channelManagerSubscription = ref.listenManual(

// AFTER:
    widget.drawerClosedNotifier?.addListener(_onDrawerClosed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _channelManagerSubscription = ref.listenManual(
```

```dart
// BEFORE (dispose 内):
    _channelManagerSubscription?.close();

// AFTER:
    widget.drawerClosedNotifier?.removeListener(_onDrawerClosed);
    _channelManagerSubscription?.close();
```

```dart
// _TerminalTabContentState に新メソッド追加:
  void _onDrawerClosed() {
    // ドロワーが閉じた後、アクティブタブならフォーカスを要求。
    // ドロワーのアニメーション完了後（300ms）にフォーカスを取る。
    if (!widget.isActive) return;
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted && widget.isActive) {
        _focusNode.requestFocus();
      }
    });
  }
```

---

### ステップ 2: tmux リアタッチをシェル ready 待機に変更

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

固定 500ms delay → PTY stdout からの出力を検知してからコマンド送信に変更。
シェルのプロンプト表示（`.bashrc` 完了のシグナル）を待つことで確実にコマンドが実行される。

```dart
// BEFORE:
  /// tmux タブの場合、再接続後に自動で tmux セッションにリアタッチする。
  void _autoReattachTmux(Terminal terminal) {
    if (_tmuxSessionName == null) return;
    AppLogger.instance.log('[SSH][$arg] auto-reattach tmux: $_tmuxSessionName');
    final escaped = _tmuxSessionName!.replaceAll("'", r"'\''");
    // 少し待ってからアタッチ（シェルの起動を待つ）
    Future.delayed(const Duration(milliseconds: 500), () {
      terminal.textInput("tmux attach -t '$escaped'\r");
    });
  }

// AFTER:
  /// tmux タブの場合、再接続後に自動で tmux セッションにリアタッチする。
  /// PTY の stdout からデータを受信するまで待機してからコマンドを送信する。
  /// これによりシェルの初期化（.bashrc 等）が完了してから attach する。
  void _autoReattachTmux(Terminal terminal) {
    if (_tmuxSessionName == null) return;
    AppLogger.instance.log('[SSH][$arg] auto-reattach tmux: $_tmuxSessionName');
    final escaped = _tmuxSessionName!.replaceAll("'", r"'\''");
    final cmd = "tmux attach -t '$escaped'\r";

    // stdout からデータが来たらシェルが ready と判断。
    // _stdoutSubscription は _connectCore で設定済み。
    // 500ms の最小待機 + 最大 5 秒のタイムアウト。
    Future<void>.delayed(const Duration(milliseconds: 500), () async {
      // 500ms 後に最初のチェック: 既にデータが来ていれば即座に送信
      if (_outputBuffer.isNotEmpty || !(_sshService?.isConnected ?? false)) {
        terminal.textInput(cmd);
        return;
      }

      // まだデータが来ていない場合、100ms ごとにチェック（最大 4.5 秒追加）
      for (var i = 0; i < 45; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (_outputBuffer.isNotEmpty || !(_sshService?.isConnected ?? false)) {
          break;
        }
      }
      // タイムアウトしてもコマンドを送信（最善の努力）
      terminal.textInput(cmd);
    });
  }
```

**注意:** `_outputBuffer` はメインイソレートの `StringBuffer` で、stdout chunk が来ると
データが蓄積される。`_flushOutput` が 16ms タイマーで定期的にクリアするので、
チェック時点で `isNotEmpty` ならシェルが何か出力した（プロンプトや MOTD）ことを意味する。

ただし、`_outputBuffer` は `_flushOutput` でクリアされるため、reconnect 後の最初のチェック時に
既にクリアされている可能性がある。

**より確実なアプローチ:** reconnect 時にフラグを設ける。

```dart
// BEFORE (フィールド):
  String? _tmuxSessionName;

// AFTER:
  String? _tmuxSessionName;
  bool _shellOutputReceived = false;
```

```dart
// BEFORE (_connectCore 内、stdout subscription):
    _stdoutSubscription = session.stdout.listen((data) {
      _outputBuffer.write(utf8.decode(data, allowMalformed: true));
      _flushTimer ??= Timer(
        const Duration(milliseconds: 16),
        () => _flushOutput(terminal),
      );
    });

// AFTER:
    _shellOutputReceived = false;
    _stdoutSubscription = session.stdout.listen((data) {
      _shellOutputReceived = true;
      _outputBuffer.write(utf8.decode(data, allowMalformed: true));
      _flushTimer ??= Timer(
        const Duration(milliseconds: 16),
        () => _flushOutput(terminal),
      );
    });
```

```dart
// _autoReattachTmux を修正:
  void _autoReattachTmux(Terminal terminal) {
    if (_tmuxSessionName == null) return;
    AppLogger.instance.log('[SSH][$arg] auto-reattach tmux: $_tmuxSessionName');
    final escaped = _tmuxSessionName!.replaceAll("'", r"'\''");
    final cmd = "tmux attach -t '$escaped'\r";

    // シェルが ready（stdout に何か出力した）になるまで待機。
    // 最小 300ms + 最大 5 秒のタイムアウト。
    Future<void>.delayed(const Duration(milliseconds: 300), () async {
      for (var i = 0; i < 47; i++) {
        if (_shellOutputReceived) break;
        if (!(_sshService?.isConnected ?? false)) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      AppLogger.instance.log('[SSH][$arg] sending tmux attach (shellReady=$_shellOutputReceived)');
      terminal.textInput(cmd);
    });
  }
```

---

### ステップ 3: `_startConnection` 内の tmux attach も同じ待機ロジックに統一

**ファイル:** `lib/features/terminal/terminal_screen.dart`

`_startConnection` 内の初回 tmux attach も固定 500ms delay。
notifier 側の `_autoReattachTmux` と同じ待機ロジックに統一する。

ただし、`_startConnection` は widget 側にあり、`_shellOutputReceived` フラグは
notifier 側にある。notifier に公開メソッドを追加する。

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

```dart
// _TerminalConnectionNotifier に追加:
  /// シェルが stdout に何か出力したかどうか。
  /// tmux attach のタイミング判定に使用。
  bool get shellOutputReceived => _shellOutputReceived;
```

**ファイル:** `lib/features/terminal/terminal_screen.dart`

```dart
// BEFORE (_startConnection 内):
    // Auto-attach tmux session after connection is established.
    if (widget.tmuxSessionName != null && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final terminal =
          ref.read(terminalConnectionProvider(widget.sessionId)).terminal;
      if (terminal != null) {
        final escaped =
            widget.tmuxSessionName!.replaceAll("'", r"'\''");
        terminal.textInput("tmux attach -t '$escaped'\r");
      }
    }

// AFTER:
    // Auto-attach tmux session after connection is established.
    if (widget.tmuxSessionName != null && mounted) {
      final notifier =
          ref.read(terminalConnectionProvider(widget.sessionId).notifier);
      // シェルが ready になるまで待機（最小 300ms + 最大 5 秒）
      await Future<void>.delayed(const Duration(milliseconds: 300));
      for (var i = 0; i < 47 && mounted; i++) {
        if (notifier.shellOutputReceived) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!mounted) return;
      final terminal =
          ref.read(terminalConnectionProvider(widget.sessionId)).terminal;
      if (terminal != null) {
        final escaped =
            widget.tmuxSessionName!.replaceAll("'", r"'\''");
        terminal.textInput("tmux attach -t '$escaped'\r");
      }
    }
```

---

### ステップ 4: `_cleanupConnections` で `_shellOutputReceived` をリセット

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

```dart
// BEFORE (_cleanupConnections 内):
  void _cleanupConnections() {
    AppLogger.instance.log('[SSH][$arg] cleaning up connections');
    _keepAliveFailCount = 0;

// AFTER:
  void _cleanupConnections() {
    AppLogger.instance.log('[SSH][$arg] cleaning up connections');
    _keepAliveFailCount = 0;
    _shellOutputReceived = false;
```

---

## 変更ファイル一覧

| ファイル | 変更内容 |
|---------|---------|
| `lib/features/terminal/terminal_screen.dart` | `_drawerClosedNotifier` 追加、`Scaffold.onEndDrawerChanged` でフォーカス復帰通知、`_TerminalTabContent` に `drawerClosedNotifier` 追加、`_onDrawerClosed` ハンドラ追加、`_startConnection` の tmux attach をシェル ready 待機に変更 |
| `lib/features/terminal/terminal_connection_provider.dart` | `_shellOutputReceived` フラグ追加、`_autoReattachTmux` をシェル ready 待機に変更、`shellOutputReceived` getter 追加、`_cleanupConnections` でフラグリセット |

---

## 検証項目

1. `~/flutter/bin/flutter analyze` — 静的解析エラーなし
2. `~/flutter/bin/flutter test` — 全テスト通過
3. `~/flutter/bin/flutter build apk --debug` — デバッグビルド成功
4. **手動テスト（デバイス）:**
   - tmux ドロワーからセッションを開く → ターミナル内でスクロールが動作すること
   - tmux ドロワーからセッションを開く → 選択モードボタン → テキスト選択が動作すること
   - tmux ドロワーから既存タブに切り替え → スクロール/選択が動作すること
   - 通常の SSH タブでドロワーを開閉 → スクロールが引き続き動作すること
   - 2 つ以上の tmux タブを開く → バックグラウンド → 復帰 → 全タブで tmux リアタッチされること
   - ログに `sending tmux attach (shellReady=true)` が全タブで表示されること
   - 初回 tmux 接続（ドロワーから新規タブ）でも attach コマンドが正常に送信されること

---

## 技術的補足

### なぜ固定 500ms delay では不十分か

SSH 接続確立後のシェル初期化には以下のステップがある:
1. PTY チャネル open
2. サーバー側でシェルプロセス起動
3. `.bashrc` / `.zshrc` 等のログインスクリプト実行
4. MOTD (Message of the Day) 表示
5. プロンプト表示

ステップ 2-5 の所要時間はサーバー負荷によって変わる。
1 台のサーバーに対して複数の SSH 接続を同時に開くと、
サーバー側のプロセス起動がキュー待ちになり、シェル初期化が遅延する。
アクティブなタブの接続が先に処理されるため、そのタブでは 500ms で十分だが、
バックグラウンドタブでは間に合わない。

`_shellOutputReceived` フラグは stdout にデータが来た = シェルが何かを出力した =
少なくともシェルプロセスが起動したことを示す。この時点で `tmux attach` を送信すれば
シェルがコマンドを受け付ける状態にある。

### なぜフォーカスが重要か

Flutter の `TerminalView` はフォーカスがないとキーボード入力を受け付けない。
また、`TerminalScrollInterceptor` は `Listener` (raw pointer events) を使うため
フォーカスとは無関係にスクロールは動作するはず。

しかし、`TerminalView` 内部の `GestureDetector` がフォーカスの有無に応じて
テキスト選択のジェスチャー認識を有効/無効にしている可能性がある。
ドロワーが閉じた後にフォーカスを明示的に戻すことで、全入力が正常に動作する。
