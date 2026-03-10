---
goal: "Phase 24 - tmux セッション CWD でファイル一覧を開く + 矢印ボタンの感度改善"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 24: tmux CWD + 矢印ボタン感度

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題 1: tmux セッション使用中にファイル一覧がホームディレクトリで開かれる

### 根本原因

`navigateToInitialDirectory()` は `channelManager.getShellCwd()` を呼ぶが、`getShellCwd()` の `$PPID` 方式は **この SSH 接続の sshd プロセスの直接の子シェル**の CWD を取得する。

tmux を使用している場合のプロセスツリー:

```
sshd (この SSH 接続の sshd)
  └── bash (ログインシェル — tmux attach を実行したシェル)
        └── tmux: client
              （tmux サーバーは別プロセス）
                └── bash (tmux ペイン内のシェル — ユーザーが実際に操作中)
```

`$PPID` 方式で見つかるのは「ログインシェル（`tmux attach` を実行したシェル）」の CWD であり、これはユーザーが最初に接続した場所（通常はホームディレクトリ）のまま。**tmux ペイン内のシェルの CWD** は sshd の孫プロセスなので `$PPID` では見つからない。

フォールバックの `tail -1` 方式も、tmux ペインのシェルを正しく選べる保証がない。

### 修正方針

tmux がアクティブな場合は、**tmux の `display-message` コマンド**で現在のペインの CWD を直接取得する:

```bash
tmux display-message -p -t <session-name> '#{pane_current_path}'
```

これは tmux サーバーが管理しているペイン情報から CWD を返すので、プロセスツリーの探索が不要で確実。

実装:
1. `SshChannelManager` に `getTmuxPaneCwd(String sessionName)` メソッドを追加
2. `FileBrowserNotifier.navigateToInitialDirectory()` で、tmux セッション名が分かる場合は `getTmuxPaneCwd()` を優先的に呼ぶ
3. tmux セッション名は `SessionInfo` に既に保持されている（`tmuxSessionName` フィールド）

### tmux セッション名の伝達

現在の `navigateToInitialDirectory()` には tmux セッション名の情報がない。`FileBrowserNotifier` に tmux セッション名を渡す手段が必要。

**方法**: `navigateToInitialDirectory()` にオプションパラメータ `tmuxSessionName` を追加し、`TerminalScreen` の `onDrawerChanged` で呼び出す際に渡す。`activeSession.tmuxSessionName` から取得可能。

---

## 問題 2: 矢印ボタンの感度が低い（特に長押し後）

### 根本原因分析

`_RepeatableActionButton` の現在の実装には複数の問題がある:

#### 2a. `onTapDown`/`onTapUp` と `SingleChildScrollView` の競合

矢印ボタンは `SingleChildScrollView(scrollDirection: Axis.horizontal)` の中にある。Flutter のジェスチャーアリーナでは、指がわずかに水平にずれると `SingleChildScrollView` がスクロールを開始し、`GestureDetector` に `onTapCancel` が通知される。これにより:
- 軽くタップしたつもりが `onTapCancel` で中断される
- 長押し中に指がわずかにずれるとリピートが止まる

#### 2b. `onTapDown` のジェスチャー認識遅延

`GestureDetector` の `onTapDown` は、Flutter がタップ vs ドラッグ vs ロングプレスを判定するために数フレーム（約 20ms）遅延する場合がある。`SingleChildScrollView` との競合があるとさらに遅延する。

#### 2c. 長押し後の「死んだ」感覚

長押し終了後に素早く再タップすると、`onTapUp` → `onTapDown` の間に Flutter のジェスチャーアリーナが再初期化されるため、体感的に反応が鈍くなることがある。

#### 2d. 視覚フィードバックの欠如

`_RepeatableActionButton` は `GestureDetector` を直接使っており、`InkWell` のようなリプルエフェクトがない。押している実感がないため、ボタンが反応していないように感じる。

### 修正方針

`GestureDetector` の `onTapDown`/`onTapUp` の代わりに、より低レベルな `Listener` ウィジェットを使う。`Listener` は Flutter のジェスチャーアリーナを経由せず、PointerDown/PointerUp イベントを直接受け取るため:
- `SingleChildScrollView` との競合が発生しない
- ジェスチャー判定の遅延がない
- 指のわずかなずれでキャンセルされない

さらに:
- 押下状態のビジュアルフィードバック（背景色変更）を追加
- リピート開始の初回遅延を 300ms → 200ms に短縮
- リピート間隔を 50ms のまま維持（20 回/秒で十分）

---

## 実装手順

### 手順 1: SshChannelManager に tmux ペイン CWD 取得メソッドを追加

ファイル: `lib/core/ssh/ssh_channel_manager.dart`

```dart
/// tmux セッションのアクティブペインの CWD を取得する。
/// tmux がインストールされていない場合や対象セッションが存在しない場合は null。
Future<String?> getTmuxPaneCwd(String tmuxSessionName) async {
  try {
    final escaped = tmuxSessionName.replaceAll("'", r"'\''");
    final session = await client.execute(
      "tmux display-message -p -t '$escaped' '#{pane_current_path}' 2>/dev/null",
    );
    final output = await session.stdout
        .cast<List<int>>()
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 5), onTimeout: () => '');
    final cwd = output.trim();
    if (cwd.isNotEmpty && cwd.startsWith('/')) {
      return cwd;
    }
  } catch (_) {
    // tmux が使えない場合は null
  }
  return null;
}
```

`import 'dart:convert'` が既に import されていることを確認。

### 手順 2: navigateToInitialDirectory に tmux セッション名パラメータを追加

ファイル: `lib/features/file_browser/file_browser_provider.dart`

変更前:
```dart
Future<void> navigateToInitialDirectory() async {
  final sftp = _sftp;
  if (sftp == null) return;

  // まず PTY シェルの CWD を取得する（best-effort: Linux のみ）
  final channelManager = _channelManager;
  if (channelManager != null) {
    try {
      final cwd = await channelManager.getShellCwd();
      // getShellCwd() は非同期のため、結果が返る前に channelManager が
      // 差し替わっている可能性がある（再接続等）。stale result を無視する。
      if (cwd != null && cwd.isNotEmpty && _channelManager == channelManager) {
        await navigateTo(cwd);
        return;
      }
    } catch (_) {
      // CWD 取得失敗 → ホームディレクトリにフォールバック
    }
  }

  // フォールバック: ホームディレクトリ
  try {
    final home = await sftp.absolute('.');
    if (home.isNotEmpty) {
      await navigateTo(home);
    }
  } catch (_) {
    // If resolution fails, leave the current path unchanged.
  }
}
```

変更後:
```dart
Future<void> navigateToInitialDirectory({String? tmuxSessionName}) async {
  final sftp = _sftp;
  if (sftp == null) return;

  final channelManager = _channelManager;
  if (channelManager != null) {
    try {
      String? cwd;

      // tmux セッション内の場合は tmux コマンドで CWD を取得（最も正確）
      if (tmuxSessionName != null && tmuxSessionName.isNotEmpty) {
        cwd = await channelManager.getTmuxPaneCwd(tmuxSessionName);
      }

      // tmux CWD が取れなかった場合は /proc ベースのフォールバック
      cwd ??= await channelManager.getShellCwd();

      if (cwd != null && cwd.isNotEmpty && _channelManager == channelManager) {
        await navigateTo(cwd);
        return;
      }
    } catch (_) {
      // CWD 取得失敗 → ホームディレクトリにフォールバック
    }
  }

  // フォールバック: ホームディレクトリ
  try {
    final home = await sftp.absolute('.');
    if (home.isNotEmpty) {
      await navigateTo(home);
    }
  } catch (_) {
    // If resolution fails, leave the current path unchanged.
  }
}
```

### 手順 3: TerminalScreen で tmux セッション名を渡す

ファイル: `lib/features/terminal/terminal_screen.dart`

`onDrawerChanged` コールバックで tmux セッション名を渡す。

変更前:
```dart
onDrawerChanged: (isOpened) {
  if (isOpened) {
    ref
        .read(fileBrowserProvider(activeSession.sessionId).notifier)
        .navigateToInitialDirectory();
  }
},
```

変更後:
```dart
onDrawerChanged: (isOpened) {
  if (isOpened) {
    ref
        .read(fileBrowserProvider(activeSession.sessionId).notifier)
        .navigateToInitialDirectory(
          tmuxSessionName: activeSession.tmuxSessionName,
        );
  }
},
```

`activeSession` は `SessionInfo` 型で、`tmuxSessionName` フィールド（`String?`）を持っている。tmux セッションでないタブの場合は `null` が渡されるため、従来の `getShellCwd()` が使われる。

### 手順 4: 矢印ボタンの感度改善（Listener ベースに変更）

ファイル: `lib/widgets/quick_action_bar.dart`

`_RepeatableActionButton` を `Listener` ベースに書き換え:

変更前:
```dart
class _RepeatableActionButton extends StatefulWidget {
  const _RepeatableActionButton({
    required this.icon,
    required this.onPressed,
  });

  final IconData icon;
  final VoidCallback onPressed;

  @override
  State<_RepeatableActionButton> createState() =>
      _RepeatableActionButtonState();
}

class _RepeatableActionButtonState extends State<_RepeatableActionButton> {
  Timer? _repeatTimer;

  void _startRepeat() {
    widget.onPressed(); // 即座に1回発火
    _repeatTimer?.cancel();
    // 初回遅延 300ms 後、50ms 間隔でリピート
    _repeatTimer = Timer(const Duration(milliseconds: 300), () {
      _repeatTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (!mounted) {
          _stopRepeat();
          return;
        }
        widget.onPressed();
      });
    });
  }

  void _stopRepeat() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
  }

  @override
  void deactivate() {
    _stopRepeat();
    super.deactivate();
  }

  @override
  void dispose() {
    _repeatTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: Colors.grey[800],
        borderRadius: BorderRadius.circular(4),
        child: GestureDetector(
          onTapDown: (_) => _startRepeat(),
          onTapUp: (_) => _stopRepeat(),
          onTapCancel: _stopRepeat,
          child: Container(
            constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Icon(widget.icon, size: 18, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
```

変更後:
```dart
class _RepeatableActionButton extends StatefulWidget {
  const _RepeatableActionButton({
    required this.icon,
    required this.onPressed,
  });

  final IconData icon;
  final VoidCallback onPressed;

  @override
  State<_RepeatableActionButton> createState() =>
      _RepeatableActionButtonState();
}

class _RepeatableActionButtonState extends State<_RepeatableActionButton> {
  Timer? _repeatTimer;
  bool _isPressed = false;

  void _startRepeat() {
    setState(() => _isPressed = true);
    widget.onPressed(); // 即座に1回発火
    _repeatTimer?.cancel();
    // 初回遅延 200ms 後、50ms 間隔でリピート
    _repeatTimer = Timer(const Duration(milliseconds: 200), () {
      _repeatTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (!mounted) {
          _stopRepeat();
          return;
        }
        widget.onPressed();
      });
    });
  }

  void _stopRepeat() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
    if (mounted) {
      setState(() => _isPressed = false);
    }
  }

  @override
  void deactivate() {
    _stopRepeat();
    super.deactivate();
  }

  @override
  void dispose() {
    _repeatTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Listener(
        // Listener はジェスチャーアリーナを経由しないため、
        // SingleChildScrollView との競合が発生しない。
        // PointerDown/PointerUp イベントを直接受け取る。
        onPointerDown: (_) => _startRepeat(),
        onPointerUp: (_) => _stopRepeat(),
        onPointerCancel: (_) => _stopRepeat(),
        child: Container(
          constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: _isPressed ? Colors.grey[600] : Colors.grey[800],
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(widget.icon, size: 18, color: Colors.white),
        ),
      ),
    );
  }
}
```

**主な変更点**:
1. `GestureDetector` → `Listener`: ジェスチャーアリーナ不使用で即時反応
2. `Material` ラッパー削除: `Listener` は `InkWell` 不要なので `Container` の `decoration` で背景色を管理
3. `_isPressed` 状態: 押下中は背景色を `grey[600]` に変更（視覚フィードバック）
4. 初回遅延: 300ms → 200ms（よりキビキビした反応）
5. `onPointerCancel`: `Listener` のキャンセルハンドラ

**注意**: `Listener` は `SingleChildScrollView` のスクロールを阻害しない。`Listener` は `HitTestBehavior.deferToChild`（デフォルト）で動作し、ポインターイベントを「聞く」だけでジェスチャーを「消費」しない。ただし、矢印ボタン上でのスクロールは効かなくなる（ボタンが小さいため実用上問題なし）。

---

## テストへの影響

- `getTmuxPaneCwd()`: 新規メソッド。既存テストに影響なし。`ssh_channel_manager_test.dart` に新テスト追加を検討
- `navigateToInitialDirectory(tmuxSessionName:)`: オプションパラメータ追加のため既存の呼び出しに影響なし。`file_browser_provider_test.dart` で tmux CWD テスト追加を検討
- `_RepeatableActionButton`: `GestureDetector` → `Listener` に変更。`quick_action_bar_test.dart` でタップ系テストが `find.byType(GestureDetector)` を使っていれば更新が必要

## 実装順序

1. `lib/core/ssh/ssh_channel_manager.dart`:
   - `getTmuxPaneCwd()` メソッド追加
2. `lib/features/file_browser/file_browser_provider.dart`:
   - `navigateToInitialDirectory()` に `tmuxSessionName` パラメータ追加
   - tmux CWD 取得を優先する分岐追加
3. `lib/features/terminal/terminal_screen.dart`:
   - `onDrawerChanged` で `tmuxSessionName` を渡す
4. `lib/widgets/quick_action_bar.dart`:
   - `_RepeatableActionButton` を `Listener` ベースに書き換え
   - 視覚フィードバック追加
   - 初回遅延を 200ms に短縮
5. テスト確認・修正
6. `~/flutter/bin/flutter analyze`
7. `~/flutter/bin/flutter test`
8. `~/flutter/bin/flutter build apk --debug`
