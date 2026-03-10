---
goal: "Phase 25 - tmux 内でのスクロール + 文字選択コピー&ペースト対応"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 25: tmux 内スクロール + コピー&ペースト

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題 1: tmux に入っている状態でスクロールできない

### 根本原因

xterm パッケージの `TerminalScrollGestureHandler` は、代替バッファ（alt buffer）使用中にスクロールジェスチャーを以下のように変換する:

1. `terminal.mouseInput(wheelUp/wheelDown)` を呼ぶ
2. tmux が **`set -g mouse on`** を設定していれば、tmux がマウスホイールイベントを受け取ってスクロールする → **この場合は動く**
3. tmux がマウスモードを有効にしていなければ `mouseInput` は `false` を返す
4. `simulateScroll: true`（デフォルト）により、矢印キー（`arrowUp`/`arrowDown`）が送信される
5. tmux の通常モードでは矢印キーはスクロールではなくペイン移動等に使われる → **スクロールにならない**

さらに、Phase 23 で追加した `QuickActionBar` のスクロールボタン（`onScrollToTop`/`onScrollToBottom`）は `_scrollController.animateTo()` を使っているが、alt buffer では `maxScrollExtent == 0`（スクロールバックバッファがない）のため**何も起きない**。

### 修正方針

#### 1a. スクロールボタンを alt buffer 対応にする

`QuickActionBar` のスクロールボタンの動作を分岐:
- **通常バッファ**: 従来通り `_scrollController.animateTo()` でスクロールバック先頭/末尾に移動
- **代替バッファ（tmux 等）**: `terminal.keyInput(TerminalKey.pageUp)` / `terminal.keyInput(TerminalKey.pageDown)` を送信

tmux では PageUp キーで自動的にコピーモードに入ってスクロールバックを閲覧できる。PageDown でスクロールダウン。これはマウスモードの設定に依存しない。

#### 1b. QuickActionBar に Page Up / Page Down ボタンを追加

常時表示のスクロールボタンに加えて、明示的な PgUp / PgDn ボタンを追加する。tmux 以外の TUI アプリ（less, man 等）でも有用。

---

## 問題 2: tmux に入っている状態で文字選択・コピーと長押し貼り付けができない

### 根本原因分析

xterm パッケージのジェスチャーハンドラの動作を詳しく調査した結果:

#### 長押し選択（`selectWord`）は**実は動く**

`TerminalGestureHandler.onLongPressStart()` は alt buffer チェックなしで常に `renderTerminal.selectWord()` を呼ぶ。つまり、tmux 内でも長押しすればワード選択が発生し、`TerminalController` の selection が更新され、`_onSelectionChanged` → `_showToolbar()` が呼ばれてフローティングツールバーが表示されるはず。

#### しかし tmux のマウスモードと干渉する

tmux で `set -g mouse on` が設定されている場合:

1. **`onTapDown`** で `renderTerminal.mouseEvent(left, down)` が呼ばれ、tmux にマウス押下イベントが送信される
2. tmux はこれを受けてペイン選択やテキスト選択を開始する
3. その後 **`onLongPressStart`** で xterm の `selectWord()` が呼ばれ、Flutter レベルの選択が行われる
4. tmux とxterm の両方で選択状態が発生し、UI が混乱する

#### ツールバーがタップで閉じない

`TerminalView` の `onTapUp` コールバックは xterm 内部で `_tapUp()` を通じて呼ばれるが、tmux のマウスモードが有効な場合 `mouseInput()` が `true` を返すため、**`onTapUp` コールバックが suppressed される**（`forceCallback` が `false`）。結果、ツールバーの `_hideToolbar()` が発動しない。

#### 貼り付け（ペースト）

`QuickActionBar` のペーストボタン（`onClipboardPaste`）は `terminal.paste()` を呼ぶが、これは正常に動作する。tmux は標準入力として受け取る。問題はフローティングツールバーの貼り付けボタンに到達できないこと（ツールバーが閉じないか、そもそも表示タイミングの問題）。

### 修正方針

#### 2a. ツールバーの表示を `_onSelectionChanged` のみに依存しない

現在のツールバーは `TerminalController` の selection 変更リスナーに依存しているが、これだけでは tmux での使い勝手が悪い。

**追加**: ターミナル画面をダブルタップしたときにもツールバーを表示する。xterm の `onDoubleTapDown` は alt buffer でも `selectWord()` を呼ぶので、ダブルタップでも選択+ツールバーが出る。この動線は `onLongPressStart` と同じで既に動くはず。

#### 2b. ツールバーをタップ以外でも閉じられるようにする

`onTapUp` が suppressed される問題の回避策:

1. **タイマーベースの自動非表示**: ツールバー表示から 5 秒後に自動的に閉じる
2. **TerminalController の selection 変更リスナーで null 検知**: selection がクリアされたら（tmux がマウスイベントを処理して xterm の selection が無効になった場合等）ツールバーを閉じる

`_onSelectionChanged` を以下のように変更:

```dart
void _onSelectionChanged() {
  if (_terminalController.selection != null) {
    _showToolbar();
  } else {
    _hideToolbar();
  }
}
```

これにより、selection がクリアされた時点でツールバーが消える。

#### 2c. ツールバーに「閉じる」ボタンを追加

ツールバーが閉じられない最悪のケースに備えて、明示的な「×」ボタンを追加。

---

## 実装手順

### 手順 1: QuickActionBar にコールバック追加とスクロール分岐

ファイル: `lib/widgets/quick_action_bar.dart`

#### 1a. コンストラクタに `onPageUp` / `onPageDown` を追加

変更前:
```dart
class QuickActionBar extends StatelessWidget {
  const QuickActionBar({
    super.key,
    required this.onKeyPressed,
    required this.onTextInput,
    this.onImagePaste,
    this.onClipboardPaste,
    this.onScrollToTop,
    this.onScrollToBottom,
  });

  final void Function(TerminalKey key, {bool ctrl}) onKeyPressed;
  final void Function(String text) onTextInput;
  final VoidCallback? onImagePaste;
  final VoidCallback? onClipboardPaste;
  final VoidCallback? onScrollToTop;
  final VoidCallback? onScrollToBottom;
```

変更後:
```dart
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
  });

  final void Function(TerminalKey key, {bool ctrl}) onKeyPressed;
  final void Function(String text) onTextInput;
  final VoidCallback? onImagePaste;
  final VoidCallback? onClipboardPaste;
  final VoidCallback? onScrollToTop;
  final VoidCallback? onScrollToBottom;
  final VoidCallback? onPageUp;
  final VoidCallback? onPageDown;
```

#### 1b. ボタンの追加

スクロールボタンの隣に PgUp / PgDn ボタンを追加:

既存のスクロールボタンの後:
```dart
_ActionButton(
  icon: Icons.vertical_align_top,
  onPressed: onScrollToTop ?? () {},
),
_ActionButton(
  icon: Icons.vertical_align_bottom,
  onPressed: onScrollToBottom ?? () {},
),
```

追加:
```dart
if (onPageUp != null || onPageDown != null) ...[
  _ActionButton(
    label: 'PgUp',
    onPressed: onPageUp ?? () {},
  ),
  _ActionButton(
    label: 'PgDn',
    onPressed: onPageDown ?? () {},
  ),
],
```

### 手順 2: スクロールボタンの alt buffer 対応

ファイル: `lib/features/terminal/terminal_screen.dart`

`QuickActionBar` のスクロールコールバックを変更。`terminal.isUsingAltBuffer` で分岐。

変更前:
```dart
onScrollToTop: () {
  if (_scrollController.hasClients &&
      _scrollController.position.maxScrollExtent > 0) {
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }
},
onScrollToBottom: () {
  if (_scrollController.hasClients) {
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }
},
```

変更後:
```dart
onScrollToTop: () {
  final terminal = connectionState.terminal;
  if (terminal != null && terminal.isUsingAltBuffer) {
    // alt buffer（tmux 等）: PageUp を送信
    // tmux では PageUp でコピーモードに入りスクロールバック閲覧
    terminal.keyInput(TerminalKey.pageUp);
  } else if (_scrollController.hasClients &&
      _scrollController.position.maxScrollExtent > 0) {
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }
},
onScrollToBottom: () {
  final terminal = connectionState.terminal;
  if (terminal != null && terminal.isUsingAltBuffer) {
    // alt buffer（tmux 等）: PageDown を送信
    terminal.keyInput(TerminalKey.pageDown);
  } else if (_scrollController.hasClients) {
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }
},
onPageUp: () {
  connectionState.terminal?.keyInput(TerminalKey.pageUp);
},
onPageDown: () {
  connectionState.terminal?.keyInput(TerminalKey.pageDown);
},
```

**注意**: `terminal.keyInput(TerminalKey.pageUp)` が xterm 4.0.0 で使えるか確認が必要。使えない場合は `terminal.textInput('\x1b[5~')` で Page Up のエスケープシーケンスを直接送信する。

### 手順 3: ツールバーの表示/非表示ロジック改善

ファイル: `lib/features/terminal/terminal_screen.dart`

#### 3a. `_onSelectionChanged` で selection クリア時にもツールバーを閉じる

変更前:
```dart
void _onSelectionChanged() {
  if (_terminalController.selection != null) {
    _showToolbar();
  }
}
```

変更後:
```dart
void _onSelectionChanged() {
  if (_terminalController.selection != null) {
    _showToolbar();
  } else {
    _hideToolbar();
  }
}
```

#### 3b. ツールバーの自動非表示タイマー

`_showToolbar()` にタイマーを追加。5 秒間操作がなければ自動的に閉じる。

状態変数を追加:
```dart
Timer? _toolbarAutoHideTimer;
```

`_showToolbar()` を変更:
```dart
void _showToolbar() {
  _hideToolbar();
  _toolbarAutoHideTimer?.cancel();
  // 5 秒後に自動で閉じる
  _toolbarAutoHideTimer = Timer(const Duration(seconds: 5), () {
    _hideToolbar();
  });
  final overlay = Overlay.of(context);
  _toolbarOverlay = OverlayEntry(
    // ... 既存のコード
  );
  overlay.insert(_toolbarOverlay!);
}
```

`_hideToolbar()` を変更:
```dart
void _hideToolbar() {
  _toolbarAutoHideTimer?.cancel();
  _toolbarAutoHideTimer = null;
  _toolbarOverlay?.remove();
  _toolbarOverlay = null;
}
```

`dispose()` にタイマーのキャンセルを追加:
```dart
_toolbarAutoHideTimer?.cancel();
```

### 手順 4: ToolbarSelectionToolbar に「閉じる」ボタンを追加

ファイル: `lib/widgets/terminal_selection_toolbar.dart`

変更前:
```dart
child: Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    if (hasSelection)
      _ToolbarButton(
        icon: Icons.copy,
        label: 'コピー',
        onPressed: () => _handleCopy(context),
      ),
    _ToolbarButton(
      icon: Icons.paste,
      label: '貼り付け',
      onPressed: () => _handlePaste(context),
    ),
  ],
),
```

変更後:
```dart
child: Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    if (hasSelection)
      _ToolbarButton(
        icon: Icons.copy,
        label: 'コピー',
        onPressed: () => _handleCopy(context),
      ),
    _ToolbarButton(
      icon: Icons.paste,
      label: '貼り付け',
      onPressed: () => _handlePaste(context),
    ),
    _ToolbarButton(
      icon: Icons.close,
      label: '閉じる',
      onPressed: () {
        controller.clearSelection();
        onDismiss();
      },
    ),
  ],
),
```

---

## テストへの影響

- `QuickActionBar`: `onPageUp`/`onPageDown` パラメータ追加（optional）。既存テストに影響なし
- `_onSelectionChanged` の変更: selection null 時の `_hideToolbar()` 追加。ツールバーテストがあれば更新必要
- `TerminalSelectionToolbar`: 「閉じる」ボタン追加。既存テストに影響する可能性あり
- `_toolbarAutoHideTimer`: `dispose` でのキャンセル確認
- `terminal.keyInput(TerminalKey.pageUp)`: xterm 4.0.0 で使えるか確認が必要。使えない場合は `textInput('\x1b[5~')` で代替

## 実装順序

1. `lib/widgets/quick_action_bar.dart`:
   - `onPageUp` / `onPageDown` パラメータ追加
   - PgUp / PgDn ボタン追加
2. `lib/widgets/terminal_selection_toolbar.dart`:
   - 「閉じる」ボタン追加
3. `lib/features/terminal/terminal_screen.dart`:
   - `onScrollToTop`/`onScrollToBottom` を alt buffer 分岐に変更
   - `onPageUp`/`onPageDown` コールバック接続
   - `_onSelectionChanged` で selection null 時にツールバーを閉じる
   - `_toolbarAutoHideTimer` 追加（5 秒自動非表示）
   - `dispose` にタイマーキャンセル追加
4. テスト確認・修正
5. `~/flutter/bin/flutter analyze`
6. `~/flutter/bin/flutter test`
7. `~/flutter/bin/flutter build apk --debug`
