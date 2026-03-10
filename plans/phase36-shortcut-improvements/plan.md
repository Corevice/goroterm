---
goal: "Phase 36 - Claude コマンドショートカット追加 + 矢印キーのスクロール中誤発火修正"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 36: Claude コマンドショートカット追加 + 矢印キーのスクロール中誤発火修正

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題

1. **Claude コマンドのショートカットがない** — `claude` CLI を起動するボタンが Quick Action Bar にない。C-c、C-d、C-j のように素早くアクセスできるショートカットが欲しい。
2. **矢印ボタンがスクロール中に誤発火する** — Quick Action Bar を横スクロールしようとすると、矢印ボタン（`_RepeatableActionButton`）が `Listener.onPointerDown` で即座に発火してしまい、意図しない矢印キー入力が送信される。

---

## 修正方針

### 問題 1: Claude コマンドショートカット

- Quick Action Bar に Claude Code アイコン付きのボタンを追加
- ボタン押下で `claude\r`（claude + Enter）をターミナルにテキスト入力
- アイコンは `Icons.auto_awesome`（AI/スパークルアイコン）を使用
- C-c, C-d, C-j の並びの後に配置

### 問題 2: 矢印キーの誤発火防止

現在の `_RepeatableActionButton` は `Listener.onPointerDown` で**即座に** `onPressed` を呼び出す。
`SingleChildScrollView` で横スクロールしようとしても、指が矢印ボタン上に触れた瞬間に発火してしまう。

**修正:** ポインタダウン後に**水平移動を検知したらキャンセル**する。
- `onPointerDown`: 位置を記録するだけで、まだ `onPressed` を呼ばない
- `onPointerMove`: 横方向に一定量（8px）動いたらスクロールと判定 → キャンセル
- 縦方向の移動 or 動きなしで一定時間（150ms）経過 → ボタン押下と判定して `onPressed` 発火 + リピート開始

---

## 実装手順

### ステップ 1: Claude コマンドショートカットボタンの追加

**ファイル:** `lib/widgets/quick_action_bar.dart`

`QuickActionBar` に新しいコールバックを追加し、C-j の後に Claude ボタンを配置する。

```dart
// BEFORE (QuickActionBar クラスのコンストラクタ):
class QuickActionBar extends StatelessWidget {
  const QuickActionBar({
    super.key,
    required this.onKeyPressed,
    required this.onTextInput,
    this.onImagePaste,
    this.onClipboardPaste,
    this.onScrollToTop,
    this.onScrollToBottom,
    this.onPageUp,
    this.onPageDown,
    this.isSelectMode = false,
    this.onToggleSelectMode,
  });

  final void Function(TerminalKey key, {bool ctrl}) onKeyPressed;
  final void Function(String text) onTextInput;
  final VoidCallback? onImagePaste;
  final VoidCallback? onClipboardPaste;
  final VoidCallback? onScrollToTop;
  final VoidCallback? onScrollToBottom;
  final VoidCallback? onPageUp;
  final VoidCallback? onPageDown;
  final bool isSelectMode;
  final VoidCallback? onToggleSelectMode;

// AFTER:
class QuickActionBar extends StatelessWidget {
  const QuickActionBar({
    super.key,
    required this.onKeyPressed,
    required this.onTextInput,
    this.onImagePaste,
    this.onClipboardPaste,
    this.onScrollToTop,
    this.onScrollToBottom,
    this.onPageUp,
    this.onPageDown,
    this.isSelectMode = false,
    this.onToggleSelectMode,
    this.onClaudeCommand,
  });

  final void Function(TerminalKey key, {bool ctrl}) onKeyPressed;
  final void Function(String text) onTextInput;
  final VoidCallback? onImagePaste;
  final VoidCallback? onClipboardPaste;
  final VoidCallback? onScrollToTop;
  final VoidCallback? onScrollToBottom;
  final VoidCallback? onPageUp;
  final VoidCallback? onPageDown;
  final bool isSelectMode;
  final VoidCallback? onToggleSelectMode;
  final VoidCallback? onClaudeCommand;
```

```dart
// BEFORE (build メソッド内、C-j ボタンの後):
              _ActionButton(
                label: 'C-j',
                onPressed: () => onKeyPressed(TerminalKey.keyJ, ctrl: true),
              ),
              const SizedBox(width: 8),

// AFTER:
              _ActionButton(
                label: 'C-j',
                onPressed: () => onKeyPressed(TerminalKey.keyJ, ctrl: true),
              ),
              if (onClaudeCommand != null)
                _ActionButton(
                  icon: Icons.auto_awesome,
                  onPressed: onClaudeCommand!,
                ),
              const SizedBox(width: 8),
```

---

### ステップ 2: terminal_screen.dart で onClaudeCommand を接続

**ファイル:** `lib/features/terminal/terminal_screen.dart`

`_TerminalTabContentState.build` 内の `QuickActionBar` に `onClaudeCommand` を追加する。

```dart
// BEFORE (QuickActionBar の呼び出し部分):
        QuickActionBar(
          onKeyPressed: (key, {bool ctrl = false}) {
            connectionState.terminal?.keyInput(key, ctrl: ctrl);
          },
          onTextInput: (text) {
            connectionState.terminal?.textInput(text);
          },
          isSelectMode: _isSelectMode,
          onToggleSelectMode: _toggleSelectMode,
          onImagePaste: connectionState.terminal != null ? _pasteImage : null,

// AFTER:
        QuickActionBar(
          onKeyPressed: (key, {bool ctrl = false}) {
            connectionState.terminal?.keyInput(key, ctrl: ctrl);
          },
          onTextInput: (text) {
            connectionState.terminal?.textInput(text);
          },
          isSelectMode: _isSelectMode,
          onToggleSelectMode: _toggleSelectMode,
          onClaudeCommand: connectionState.terminal != null
              ? () => connectionState.terminal?.textInput('claude\r')
              : null,
          onImagePaste: connectionState.terminal != null ? _pasteImage : null,
```

---

### ステップ 3: _RepeatableActionButton の誤発火防止

**ファイル:** `lib/widgets/quick_action_bar.dart`

`_RepeatableActionButton` のポインタ処理を修正し、横スクロールと区別する。

```dart
// BEFORE (_RepeatableActionButtonState 全体):
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
    // deactivate はビルドフェーズ中に呼ばれる場合があるため setState() 不可。
    // タイマーのみキャンセルし、_isPressed はリセットしない。
    _repeatTimer?.cancel();
    _repeatTimer = null;
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

// AFTER:
class _RepeatableActionButtonState extends State<_RepeatableActionButton> {
  Timer? _repeatTimer;
  Timer? _activationTimer;
  bool _isPressed = false;
  bool _isCancelled = false;
  Offset? _downPosition;

  // 水平スクロール判定の閾値（px）
  static const _scrollThreshold = 8.0;
  // ボタン押下と判定するまでの遅延（ms）
  static const _activationDelay = Duration(milliseconds: 150);

  void _onPointerDown(PointerDownEvent event) {
    _downPosition = event.position;
    _isCancelled = false;
    // 即座には発火せず、遅延後に発火する
    _activationTimer?.cancel();
    _activationTimer = Timer(_activationDelay, () {
      if (!_isCancelled && mounted) {
        _startRepeat();
      }
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_isCancelled) return;
    if (_downPosition == null) return;
    final dx = (event.position.dx - _downPosition!.dx).abs();
    // 横方向に閾値以上動いたらスクロールと判定 → キャンセル
    if (dx > _scrollThreshold) {
      _cancel();
    }
  }

  void _startRepeat() {
    setState(() => _isPressed = true);
    widget.onPressed(); // 判定確定後に1回発火
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

  void _cancel() {
    _isCancelled = true;
    _activationTimer?.cancel();
    _activationTimer = null;
    _stopRepeat();
  }

  void _stopRepeat() {
    _activationTimer?.cancel();
    _activationTimer = null;
    _repeatTimer?.cancel();
    _repeatTimer = null;
    _downPosition = null;
    if (mounted) {
      setState(() => _isPressed = false);
    }
  }

  @override
  void deactivate() {
    _activationTimer?.cancel();
    _activationTimer = null;
    _repeatTimer?.cancel();
    _repeatTimer = null;
    super.deactivate();
  }

  @override
  void dispose() {
    _activationTimer?.cancel();
    _repeatTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: (_) => _stopRepeat(),
        onPointerCancel: (_) => _cancel(),
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

**修正のポイント:**
- `onPointerDown` で**即座に発火しない**。代わりに位置を記録し、150ms のタイマーを開始
- `onPointerMove` で**横方向に 8px 以上**動いたらスクロールと判定してキャンセル
- タイマー完了まで横移動がなければボタン押下と判定して発火 + リピート開始
- `onPointerCancel` でもキャンセル処理を実行

---

## 変更ファイル一覧

| ファイル | 変更内容 |
|---------|---------|
| `lib/widgets/quick_action_bar.dart` | Claude ボタン追加 + `_RepeatableActionButton` 誤発火防止 |
| `lib/features/terminal/terminal_screen.dart` | `onClaudeCommand` コールバック接続 |

---

## 検証項目

1. `~/flutter/bin/flutter analyze` — 静的解析エラーなし
2. `~/flutter/bin/flutter test` — 全テスト通過
3. `~/flutter/bin/flutter build apk --debug` — デバッグビルド成功
4. **手動テスト（デバイス）:**
   - Claude ボタン（✨アイコン）をタップすると `claude` コマンドが実行される
   - Claude ボタンが C-j の右隣に表示される
   - Quick Action Bar を横スクロールしても矢印キーが誤発火しない
   - 矢印ボタンを意図的にタップすると正常に動作する（150ms 遅延はほぼ気にならない）
   - 矢印ボタンを長押しするとリピート動作が正常に動作する
