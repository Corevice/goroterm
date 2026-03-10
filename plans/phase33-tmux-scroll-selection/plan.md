---
goal: "Phase 33 - tmux スクロール・選択修正 + リリースビルドのネットワーク接続エラー修正"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
  - ~/flutter/bin/flutter build apk --release
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 33: tmux スクロール・選択修正 + リリースビルド接続エラー修正

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題

1. tmux セッション内で **画面のスワイプスクロールができない**
2. tmux セッション内で **テキスト選択（長押し → コピー）ができない**
3. **リリース（本番）ビルドをインストールするとネットワーク接続エラーで何も接続できない**

Phase 23/25 でボタンベースの PgUp/PgDn は追加済みだが、タッチジェスチャーは未修正。

---

## 根本原因分析

### 原因 1: tmux mouse mode がオフのとき、スワイプが arrow keys に変換される

xterm パッケージの `TerminalScrollGestureHandler` の動作:
1. alt buffer（tmux, vim, less）では `InfiniteScrollView`（`Scrollable`）でスワイプをキャプチャ
2. `_sendScrollEvent()` → `terminal.mouseInput(wheelUp/wheelDown)` を呼ぶ
3. tmux の mouse mode がオフ（デフォルト）→ `mouseInput()` は `false` を返す
4. `simulateScroll: true`（デフォルト）→ フォールバックで `terminal.keyInput(TerminalKey.arrowUp/arrowDown)` を送信
5. tmux では矢印キーはペイン移動やカーソル移動 → **スクロールにならない**

```dart
// xterm の scroll_handler.dart:86-99
void _sendScrollEvent(bool up) {
  final handled = widget.terminal.mouseInput(
    up ? TerminalMouseButton.wheelUp : TerminalMouseButton.wheelDown,
    TerminalMouseButtonState.down, position,
  );
  if (!handled && widget.simulateScroll) {
    widget.terminal.keyInput(
      up ? TerminalKey.arrowUp : TerminalKey.arrowDown,  // ← tmux では無意味
    );
  }
}
```

### 原因 2: tmux mouse mode をオンにすれば解決するが、デフォルトはオフ

`tmux set-option mouse on` を設定すれば:
- `mouseInput(wheelUp/wheelDown)` が tmux に転送され、スクロールが動作する
- `mouseInput(left, down/up)` でクリック操作も tmux に転送される

しかしアプリ側では tmux mouse mode を自動設定していない。

### 原因 3: tmux mouse mode がオンだとテキスト選択が競合する

tmux mouse mode がオンの場合:
- `onTapDown`（タップ直後）で `mouseEvent(left, down)` が tmux に送信される
- `onLongPressStart`（500ms 後）で `selectWord()` が xterm レベルで呼ばれる
- **tmux の選択と xterm の選択が同時に発生する**

また、`onSingleTapUp` で `mouseEvent(left, up)` が tmux に送信されるが、tmux が処理すると `handled = true` となり、外部コールバック（`onTapUp` → `_hideToolbar()`）が **抑制される**。

---

## 修正方針

### Fix 1: tmux セッションに attach するときに自動で mouse mode をオンにする

`attachSession()` で tmux attach する際に、事前に `tmux set-option -t <session> mouse on` を実行する。
これにより:
- スワイプスクロール → `mouseInput(wheelUp/Down)` → tmux がスクロール処理 → **動作する**
- セッションレベル設定なのでユーザーのグローバル tmux.conf には影響しない

### Fix 2: 「選択モード」トグルで tmux マウスイベントの競合を回避する

QuickActionBar に「選択モード」トグルボタンを追加:
- オフ（通常）: タップ/スワイプが tmux に転送される → スクロールやクリックが動作
- オン（選択モード）: `TerminalController` の `PointerInput.tap` を無効化 → tmux にマウスイベントが送信されない → 長押しで xterm ネイティブのテキスト選択 → ツールバー表示 → システムクリップボードにコピー → 選択モード自動解除

### Fix 3: `simulateScroll: false` を設定

tmux mouse mode をオンにするので、`simulateScroll` の arrow key フォールバックは不要。
`false` にすることで、mouse mode オフの状態でも無意味な arrow key 送信を防ぐ。
（`less` や `man` では mouse mode が有効なため `mouseInput` が処理する。有効でないケースでは PgUp/PgDn ボタンで対応。）

---

## 変更対象ファイル

1. `android/app/src/main/AndroidManifest.xml` — 修正（INTERNET パーミッション追加）
2. `lib/features/tmux/tmux_provider.dart` — 修正
3. `lib/features/terminal/terminal_screen.dart` — 修正
4. `lib/widgets/quick_action_bar.dart` — 修正

---

## Step 0: リリースビルドのネットワーク接続エラー修正

### 根本原因

`android.permission.INTERNET` が `android/app/src/main/AndroidManifest.xml` に **宣言されていない**。

`INTERNET` パーミッションは `android/app/src/debug/AndroidManifest.xml` と `android/app/src/profile/AndroidManifest.xml` にのみ存在する（Flutter のデフォルト生成で "required for development" コメント付き）。

Android のマニフェストマージャーは:
- debug ビルド → `main/` + `debug/` をマージ → `INTERNET` あり ✓
- profile ビルド → `main/` + `profile/` をマージ → `INTERNET` あり ✓
- **release ビルド → `main/` のみ（`release/` ディレクトリなし）→ `INTERNET` なし ✗**

結果: release APK には `INTERNET` パーミッションが含まれず、`Socket.connect()` が OS レベルで拒否される。

### ファイル: `android/app/src/main/AndroidManifest.xml`

**before:**
```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />
    <application
```

**after:**
```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />
    <application
```

---

## Step 1: tmux attach 時に mouse mode を自動オンにする

### ファイル: `lib/features/tmux/tmux_provider.dart`

**before:**
```dart
  /// Attaches to a session by writing the command to the PTY channel.
  void attachSession(String name) {
    final connectionState = ref.read(terminalConnectionProvider(arg));
    final terminal = connectionState.terminal;
    if (terminal == null) return;
    final escaped = shellEscape(name);
    terminal.textInput('tmux attach -t $escaped\r');
  }
```

**after:**
```dart
  /// Attaches to a session by writing the command to the PTY channel.
  /// attach 前に mouse mode をオンにし、スワイプスクロールを有効化する。
  void attachSession(String name) {
    final connectionState = ref.read(terminalConnectionProvider(arg));
    final terminal = connectionState.terminal;
    if (terminal == null) return;
    final escaped = shellEscape(name);
    // セッションレベルで mouse mode を有効化（グローバル設定には影響しない）
    // これによりスワイプスクロールが tmux 内で動作する
    _enableTmuxMouse(name);
    terminal.textInput('tmux attach -t $escaped\r');
  }

  /// tmux セッションの mouse mode をオンにする。
  /// exec チャネルで実行するため PTY 出力には影響しない。
  void _enableTmuxMouse(String sessionName) {
    final channelManager = _channelManager;
    if (channelManager == null) return;
    final escaped = shellEscape(sessionName);
    // fire-and-forget: 失敗しても attach 自体に影響しない
    _execCommand(channelManager, 'tmux set-option -t $escaped mouse on')
        .catchError((_) {});
  }
```

同様に `createSession` でも mouse mode を有効化する。

**before:**
```dart
  Future<void> createSession(String name) async {
    if (_isOperating) return;
    _isOperating = true;
    try {
      final channelManager = _channelManager;
      if (channelManager == null) return;
      final escaped = shellEscape(name);
      await _execCommand(channelManager, 'tmux new-session -d -s $escaped');
    } finally {
      _isOperating = false;
      await _safeRefresh();
    }
  }
```

**after:**
```dart
  Future<void> createSession(String name) async {
    if (_isOperating) return;
    _isOperating = true;
    try {
      final channelManager = _channelManager;
      if (channelManager == null) return;
      final escaped = shellEscape(name);
      await _execCommand(channelManager, 'tmux new-session -d -s $escaped');
      // 新規セッションの mouse mode を有効化
      await _execCommand(
        channelManager,
        'tmux set-option -t $escaped mouse on',
      ).catchError((_) {});
    } finally {
      _isOperating = false;
      await _safeRefresh();
    }
  }
```

---

## Step 2: `simulateScroll: false` + 選択モードトグル

### ファイル: `lib/features/terminal/terminal_screen.dart`

#### 2-1. 選択モードの状態管理を `_TerminalTabContentState` に追加

**before (class 冒頭):**
```dart
class _TerminalTabContentState extends ConsumerState<_TerminalTabContent>
    with AutomaticKeepAliveClientMixin {
  final _terminalController = TerminalController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  OverlayEntry? _toolbarOverlay;
  Timer? _toolbarAutoHideTimer;
  ProviderSubscription<SshChannelManager?>? _channelManagerSubscription;
```

**after:**
```dart
class _TerminalTabContentState extends ConsumerState<_TerminalTabContent>
    with AutomaticKeepAliveClientMixin {
  final _terminalController = TerminalController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  OverlayEntry? _toolbarOverlay;
  Timer? _toolbarAutoHideTimer;
  ProviderSubscription<SshChannelManager?>? _channelManagerSubscription;
  bool _isSelectMode = false;
```

#### 2-2. 選択モードの切り替えメソッド

`_hideToolbar()` メソッドの直後に追加:

```dart
  void _toggleSelectMode() {
    setState(() {
      _isSelectMode = !_isSelectMode;
      if (_isSelectMode) {
        // 選択モード: tmux へのマウスイベント転送を無効化
        // → 長押しで xterm ネイティブのテキスト選択が動作
        _terminalController.setPointerInputs({});
      } else {
        // 通常モード: タップイベントを tmux に転送
        _terminalController.setPointerInputs({PointerInput.tap});
        _terminalController.clearSelection();
        _hideToolbar();
      }
    });
  }

  void _exitSelectMode() {
    if (!_isSelectMode) return;
    setState(() {
      _isSelectMode = false;
      _terminalController.setPointerInputs({PointerInput.tap});
    });
  }
```

#### 2-3. 選択完了時に自動で選択モードを解除

`_onSelectionChanged` を修正:

**before:**
```dart
  void _onSelectionChanged() {
    if (_terminalController.selection != null) {
      _showToolbar();
    } else {
      _hideToolbar();
    }
  }
```

**after:**
```dart
  void _onSelectionChanged() {
    if (_terminalController.selection != null) {
      _showToolbar();
    } else {
      _hideToolbar();
      // 選択がクリアされたら選択モードを自動解除
      _exitSelectMode();
    }
  }
```

#### 2-4. `TerminalView` に `simulateScroll: false` を追加

**before:**
```dart
                  child: TerminalView(
                    connectionState.terminal!,
                    controller: _terminalController,
                    focusNode: _focusNode,
                    autofocus: true,
                    autoResize: true,
                    deleteDetection: true,
                    textScaler: TextScaler.linear(fontSize / 14.0),
                    scrollController: _scrollController,
                    onTapUp: (_, __) {
                      if (_terminalController.selection == null) {
                        _hideToolbar();
                      }
                    },
```

**after:**
```dart
                  child: TerminalView(
                    connectionState.terminal!,
                    controller: _terminalController,
                    focusNode: _focusNode,
                    autofocus: true,
                    autoResize: true,
                    deleteDetection: true,
                    simulateScroll: false,
                    textScaler: TextScaler.linear(fontSize / 14.0),
                    scrollController: _scrollController,
                    onTapUp: (_, __) {
                      if (_terminalController.selection == null) {
                        _hideToolbar();
                      }
                    },
```

#### 2-5. QuickActionBar に選択モードトグルを渡す

**before:**
```dart
        QuickActionBar(
          onKeyPressed: (key, {bool ctrl = false}) {
            connectionState.terminal?.keyInput(key, ctrl: ctrl);
          },
          onTextInput: (text) {
            connectionState.terminal?.textInput(text);
          },
          onImagePaste: connectionState.terminal != null ? _pasteImage : null,
          onClipboardPaste: connectionState.terminal != null
```

**after:**
```dart
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
          onClipboardPaste: connectionState.terminal != null
```

---

## Step 3: QuickActionBar に選択モードボタンを追加

### ファイル: `lib/widgets/quick_action_bar.dart`

#### 3-1. パラメータ追加

**before:**
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

**after:**
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
```

#### 3-2. ボタン追加（PgDn の後、画像ペーストの前）

**before:**
```dart
              _ActionButton(
                label: 'PgDn',
                onPressed: onPageDown ?? () {},
              ),
              const SizedBox(width: 8),
              if (onImagePaste != null) ...[
```

**after:**
```dart
              _ActionButton(
                label: 'PgDn',
                onPressed: onPageDown ?? () {},
              ),
              const SizedBox(width: 8),
              if (onToggleSelectMode != null)
                _SelectModeButton(
                  isActive: isSelectMode,
                  onPressed: onToggleSelectMode!,
                ),
              if (onToggleSelectMode != null)
                const SizedBox(width: 8),
              if (onImagePaste != null) ...[
```

#### 3-3. `_SelectModeButton` ウィジェットを追加（ファイル末尾）

```dart
class _SelectModeButton extends StatelessWidget {
  const _SelectModeButton({
    required this.isActive,
    required this.onPressed,
  });

  final bool isActive;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: isActive ? Colors.blue[700] : Colors.grey[800],
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onPressed,
          child: Container(
            constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Icon(
              Icons.text_fields,
              size: 18,
              color: isActive ? Colors.white : Colors.white70,
            ),
          ),
        ),
      ),
    );
  }
}
```

---

## 動作フロー

### スクロール（修正後）

```
ユーザーがスワイプ
  └─ InfiniteScrollView の Scrollable が drag を捕捉
       └─ _onScroll → _sendScrollEvent
            └─ terminal.mouseInput(wheelUp/Down)
                 ├─ tmux mouse mode ON（自動設定済み）→ tmux がスクロール処理 ✓
                 └─ tmux mouse mode OFF → mouseInput = false → simulateScroll = false → 何もしない
                      （PgUp/PgDn ボタンを使用）
```

### テキスト選択（修正後）

```
ユーザーが選択モードボタンをタップ
  └─ _isSelectMode = true
       └─ PointerInput.tap を無効化（tmux にマウスイベントが送られない）
            └─ ユーザーが長押し
                 └─ LongPressGestureRecognizer が勝利（競合なし）
                      └─ selectWord() → _onSelectionChanged → _showToolbar
                           └─ 「コピー」ボタン → システムクリップボードにコピー
                                └─ 選択クリア → 選択モード自動解除
```

---

## 検証手順

1. `~/flutter/bin/flutter analyze` — 静的解析エラーなし
2. `~/flutter/bin/flutter test` — 既存テスト全パス
3. `~/flutter/bin/flutter build apk --release` — **リリースビルド**成功
4. リリースビルドの INTERNET パーミッション確認:
   ```bash
   # ビルド後の APK に INTERNET パーミッションが含まれていることを確認
   ~/android-sdk/build-tools/*/aapt dump permissions build/app/outputs/flutter-apk/app-release.apk | grep INTERNET
   ```
5. 実機テスト（リリースビルド）:
   - **リリース APK をインストール → SSH 接続が成功する**（最重要）
   - tmux セッションを作成 → attach → **スワイプでスクロールできる**
   - tmux セッション内で出力をスクロールバック → **上下にスムーズにスクロール**
   - 選択モードボタン（Aa アイコン）をタップ → ボタンが青くハイライト
   - テキストを長押し → **xterm の選択ハイライトが表示される**
   - ツールバーの「コピー」→ **システムクリップボードにコピーされる**
   - コピー後 → **選択モードが自動的に解除される**
   - 選択モード解除後 → **スワイプスクロールが再び動作する**
   - 通常のシェル（tmux 外）→ **スワイプスクロール（スクロールバック）が従来通り動作する**
   - less / man コマンド → **PgUp/PgDn ボタンでスクロール可能**
