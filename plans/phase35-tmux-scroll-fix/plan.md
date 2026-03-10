---
goal: "Phase 35 - tmux タッチスクロール修正（xterm nested Scrollable バイパス）"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 35: tmux タッチスクロール修正（xterm nested Scrollable バイパス）

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題

tmux セッション内で **タッチスワイプによるスクロールが動作しない**。

Phase 33 で以下の対策を実施したが効果がなかった:
- `simulateScroll: false` 設定
- `tmux set-option mouse on` による tmux マウスモード有効化
- 選択モード切替の追加

## 根本原因

xterm 4.0.0 の **nested Scrollable アーキテクチャ**が原因。

### xterm の alt buffer 時のウィジェットツリー

```
TerminalGestureHandler (RawGestureDetector: Tap + LongPress + Pan)
  └─ TerminalScrollGestureHandler
       └─ Listener (ポインタ位置キャプチャ)
            └─ InfiniteScrollView (Scrollable #1 — 外側、無限スクロール)
                 └─ scrollback Scrollable #2 (内側、maxScrollExtent=0)
                      └─ RenderTerminal
```

**問題のメカニズム:**

1. `InfiniteScrollView` と scrollback `Scrollable` の両方が `VerticalDragGestureRecognizer` を生成
2. Flutter のジェスチャアリーナでは **内側の Scrollable（scrollback）が勝つ**（ヒットテストターゲットに近いため）
3. alt buffer では scrollback の `maxScrollExtent == 0` → ドラッグジェスチャを**吸収するが実際にはスクロールしない**
4. `InfiniteScrollView` の `_onScroll` コールバックが **一切発火しない**
5. `_sendScrollEvent` → `terminal.mouseInput(wheelUp/wheelDown)` に到達しない
6. tmux マウスモードが ON でも、スクロールイベント自体が生成されないため効果なし

### なぜ xterm パッケージ自体を修正しないのか

- xterm 4.0.0 は pub.dev のパッケージであり、フォークするとメンテナンスコストが高い
- nested Scrollable の問題は xterm 内部アーキテクチャの根本的な設計上の課題
- アプリ側で `Listener` を使って**ジェスチャアリーナをバイパス**する方が安全で保守しやすい

---

## 修正方針

`Listener` ウィジェットを使って **raw ポインタイベントをキャプチャ**し、
xterm の壊れたスクロールパイプラインを完全にバイパスする。

`Listener` は Flutter のジェスチャアリーナに**参加しない**ため、
内側の Scrollable とのジェスチャ競合が発生しない。

### 動作フロー

```
指でスワイプ
  ↓
Listener (onPointerDown/Move/Up) — raw ポインタイベントをキャプチャ
  ↓
terminal.isUsingAltBuffer == true ?
  ├─ YES → ピクセルデルタを行数に変換 → terminal.mouseInput(wheelUp/wheelDown) を直接呼び出し
  └─ NO  → 何もしない（通常のスクロールバック動作に任せる）
  ↓
xterm 内部の Scrollable にもイベントは届くが、
alt buffer では maxScrollExtent=0 で実質的に無動作
```

---

## 実装手順

### ステップ 1: TerminalScrollInterceptor ウィジェットの作成

**新規ファイル:** `lib/widgets/terminal_scroll_interceptor.dart`

このウィジェットは `TerminalView` をラップし、alt buffer 時のタッチスクロールを処理する。

```dart
// BEFORE: このファイルは存在しない

// AFTER:
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

/// xterm 4.0.0 の nested Scrollable アーキテクチャをバイパスして、
/// alt buffer（tmux 等）でのタッチスクロールを実現するウィジェット。
///
/// [Listener] を使って raw ポインタイベントをキャプチャし、
/// ジェスチャアリーナに参加せずにスクロールイベントを生成する。
class TerminalScrollInterceptor extends StatefulWidget {
  const TerminalScrollInterceptor({
    super.key,
    required this.terminal,
    required this.child,
  });

  final Terminal terminal;
  final Widget child;

  @override
  State<TerminalScrollInterceptor> createState() =>
      _TerminalScrollInterceptorState();
}

class _TerminalScrollInterceptorState
    extends State<TerminalScrollInterceptor> {
  // ドラッグ追跡用の状態
  int? _activePointerId;
  double _accumulatedDelta = 0.0;
  Offset _lastPointerPosition = Offset.zero;

  // スクロール判定: 水平スワイプ（タブ切替）との競合を防ぐ
  bool _isVerticalDrag = false;
  bool _directionDecided = false;
  Offset _dragStartPosition = Offset.zero;

  // 1行あたりのピクセル数（フォントサイズに依存）
  // TerminalView の実際の高さと terminal.viewHeight から動的に計算
  double get _lineHeight {
    final viewHeight = widget.terminal.viewHeight;
    if (viewHeight <= 0) return 20.0; // フォールバック
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return 20.0;
    return renderBox.size.height / viewHeight;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: widget.child,
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    // マウスイベントは無視（タッチのみ処理）
    if (event.kind != PointerDeviceKind.touch) return;
    // alt buffer でなければ無視
    if (!widget.terminal.isUsingAltBuffer) return;

    _activePointerId = event.pointer;
    _accumulatedDelta = 0.0;
    _lastPointerPosition = event.localPosition;
    _dragStartPosition = event.localPosition;
    _isVerticalDrag = false;
    _directionDecided = false;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _activePointerId) return;
    if (!widget.terminal.isUsingAltBuffer) {
      _reset();
      return;
    }

    // 方向判定: 最初の移動で縦 vs 横を決定
    if (!_directionDecided) {
      final dx = (event.localPosition.dx - _dragStartPosition.dx).abs();
      final dy = (event.localPosition.dy - _dragStartPosition.dy).abs();
      // 十分な移動量がないと判定しない（閾値: 10px）
      if (dx < 10 && dy < 10) return;
      _directionDecided = true;
      _isVerticalDrag = dy > dx;
      if (!_isVerticalDrag) {
        _reset();
        return;
      }
    }

    if (!_isVerticalDrag) return;

    final dy = event.localPosition.dy - _lastPointerPosition.dy;
    _lastPointerPosition = event.localPosition;
    _accumulatedDelta += dy;

    final lineHeight = _lineHeight;
    // 蓄積されたデルタが 1 行分を超えたらスクロールイベントを送信
    while (_accumulatedDelta.abs() >= lineHeight) {
      final isUp = _accumulatedDelta < 0;
      _accumulatedDelta += isUp ? lineHeight : -lineHeight;

      // ポインタ位置からセル座標を概算
      final cellX = max(0, (event.localPosition.dx / (lineHeight * 0.6)).floor());
      final cellY = max(0, (event.localPosition.dy / lineHeight).floor());
      final cellOffset = CellOffset(cellX, cellY);

      widget.terminal.mouseInput(
        isUp ? TerminalMouseButton.wheelUp : TerminalMouseButton.wheelDown,
        TerminalMouseButtonState.down,
        cellOffset,
      );
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer == _activePointerId) {
      _reset();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _activePointerId) {
      _reset();
    }
  }

  void _reset() {
    _activePointerId = null;
    _accumulatedDelta = 0.0;
    _isVerticalDrag = false;
    _directionDecided = false;
  }
}
```

**設計上のポイント:**
- `Listener` を使うことでジェスチャアリーナに参加しない → 内側の Scrollable との競合なし
- タッチイベントのみ処理（マウスは xterm のデフォルト動作に任せる）
- 水平スワイプとの方向判定（10px 閾値）でタブ切替ジェスチャとの競合を防止
- ピクセルデルタを行数に変換して `terminal.mouseInput()` を直接呼び出し
- セル座標は概算値（tmux のスクロールでは位置は重要でない）
- `isUsingAltBuffer` が false の場合は一切干渉しない（通常のスクロールバック動作を維持）

---

### ステップ 2: terminal_screen.dart に TerminalScrollInterceptor を組み込む

**ファイル:** `lib/features/terminal/terminal_screen.dart`

`TerminalView` を `TerminalScrollInterceptor` でラップする。

```dart
// BEFORE (terminal_screen.dart 内の _TerminalTabContentState.build の TerminalView 部分):
        Expanded(
          child: connectionState.terminal != null
              ? ClipRect(
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
                    theme: const TerminalTheme(
                      // ... theme settings ...
                    ),
                  ),
                )
              : const Center(
                  child: CircularProgressIndicator(),
                ),
        ),

// AFTER:
        Expanded(
          child: connectionState.terminal != null
              ? ClipRect(
                  child: TerminalScrollInterceptor(
                    terminal: connectionState.terminal!,
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
                      theme: const TerminalTheme(
                        // ... theme settings（変更なし） ...
                      ),
                    ),
                  ),
                )
              : const Center(
                  child: CircularProgressIndicator(),
                ),
        ),
```

**import 追加:**

```dart
// BEFORE (terminal_screen.dart の import セクション末尾):
import '../../widgets/terminal_selection_toolbar.dart';

// AFTER:
import '../../widgets/terminal_selection_toolbar.dart';
import '../../widgets/terminal_scroll_interceptor.dart';
```

---

### ステップ 3: mouseInput の戻り値ハンドリングとフォールバック

`terminal.mouseInput()` は tmux がマウスモードを宣言していない場合 `false` を返す。
Phase 33 で `tmux set-option mouse on` を設定しているため通常は `true` を返すが、
フォールバックとして arrow key 送信を追加する。

**ステップ 1 の `_onPointerMove` 内のスクロール送信部分を修正:**

```dart
// BEFORE (_TerminalScrollInterceptorState._onPointerMove 内の while ループ):
      widget.terminal.mouseInput(
        isUp ? TerminalMouseButton.wheelUp : TerminalMouseButton.wheelDown,
        TerminalMouseButtonState.down,
        cellOffset,
      );

// AFTER:
      final handled = widget.terminal.mouseInput(
        isUp ? TerminalMouseButton.wheelUp : TerminalMouseButton.wheelDown,
        TerminalMouseButtonState.down,
        cellOffset,
      );
      // tmux がマウスモードを宣言していない場合のフォールバック:
      // arrow key を送信してスクロールを試みる
      if (!handled) {
        widget.terminal.keyInput(
          isUp ? TerminalKey.arrowUp : TerminalKey.arrowDown,
        );
      }
```

**注意:** ステップ 1 のコードにこの修正を含めて最初から正しいコードを書くこと。
ステップ 1 とステップ 3 は同じファイルへの変更なので、最終的なコードで作成すること。

---

### ステップ 4: テストの追加

**新規ファイル:** `test/widgets/terminal_scroll_interceptor_test.dart`

```dart
// BEFORE: このファイルは存在しない

// AFTER:
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'package:terminal_ssh_app/widgets/terminal_scroll_interceptor.dart';

void main() {
  group('TerminalScrollInterceptor', () {
    late Terminal terminal;

    setUp(() {
      terminal = Terminal(maxLines: 100);
    });

    testWidgets('renders child widget', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TerminalScrollInterceptor(
            terminal: terminal,
            child: const SizedBox(width: 300, height: 400),
          ),
        ),
      );

      expect(find.byType(TerminalScrollInterceptor), findsOneWidget);
      expect(find.byType(SizedBox), findsOneWidget);
    });

    testWidgets('does not intercept when not in alt buffer', (tester) async {
      // terminal は初期状態で main buffer
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: terminal,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      // タッチジェスチャを実行しても alt buffer でないのでインターセプトしない
      final center = tester.getCenter(find.byType(TerminalScrollInterceptor));
      final gesture = await tester.startGesture(center, kind: PointerDeviceKind.touch);
      await gesture.moveBy(const Offset(0, -100));
      await gesture.up();
      await tester.pump();

      // エラーなく完了すれば OK
    });

    testWidgets('does not intercept mouse events even in alt buffer', (tester) async {
      // alt buffer に切り替え
      terminal.write('\x1B[?1049h');

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: terminal,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      // マウスイベントは無視される
      final center = tester.getCenter(find.byType(TerminalScrollInterceptor));
      final gesture = await tester.startGesture(center, kind: PointerDeviceKind.mouse);
      await gesture.moveBy(const Offset(0, -100));
      await gesture.up();
      await tester.pump();

      // エラーなく完了すれば OK
    });

    testWidgets('intercepts vertical touch in alt buffer', (tester) async {
      // mouseInput の呼び出しを追跡
      final mouseEvents = <TerminalMouseButton>[];
      terminal.write('\x1B[?1049h'); // alt buffer に切り替え
      // マウスモードを有効にして mouseInput が true を返すようにする
      terminal.write('\x1B[?1000h'); // X11 mouse mode on

      // mouseInput の結果を追跡するため onOutput を監視
      final outputs = <String>[];
      final origTerminal = Terminal(
        maxLines: 100,
        onOutput: (data) {
          outputs.add(data);
        },
      );
      origTerminal.write('\x1B[?1049h');
      origTerminal.write('\x1B[?1000h');

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: origTerminal,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      // 垂直スワイプを実行
      final center = tester.getCenter(find.byType(TerminalScrollInterceptor));
      final gesture = await tester.startGesture(center, kind: PointerDeviceKind.touch);
      // 方向判定閾値(10px)を超えて、さらに複数行分スクロール
      await gesture.moveBy(const Offset(0, -80));
      await gesture.up();
      await tester.pump();

      // mouseInput が呼ばれてエスケープシーケンスが出力されるはず
      expect(outputs.isNotEmpty, isTrue);
    });

    testWidgets('ignores horizontal swipe in alt buffer', (tester) async {
      terminal.write('\x1B[?1049h');
      terminal.write('\x1B[?1000h');

      final outputs = <String>[];
      final testTerminal = Terminal(
        maxLines: 100,
        onOutput: (data) {
          outputs.add(data);
        },
      );
      testTerminal.write('\x1B[?1049h');
      testTerminal.write('\x1B[?1000h');

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: testTerminal,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      // 水平スワイプ（タブ切替用）は無視されるべき
      final center = tester.getCenter(find.byType(TerminalScrollInterceptor));
      final gesture = await tester.startGesture(center, kind: PointerDeviceKind.touch);
      await gesture.moveBy(const Offset(100, 0)); // 横方向
      await gesture.up();
      await tester.pump();

      // 水平スワイプではスクロールイベントが生成されない
      expect(outputs.isEmpty, isTrue);
    });
  });
}
```

---

## 変更ファイル一覧

| ファイル | 変更内容 |
|---------|---------|
| `lib/widgets/terminal_scroll_interceptor.dart` | **新規作成** — Listener ベースのスクロールインターセプター |
| `lib/features/terminal/terminal_screen.dart` | TerminalView を TerminalScrollInterceptor でラップ + import 追加 |
| `test/widgets/terminal_scroll_interceptor_test.dart` | **新規作成** — インターセプターのユニットテスト |

---

## 検証項目

1. `~/flutter/bin/flutter analyze` — 静的解析エラーなし
2. `~/flutter/bin/flutter test` — 全テスト通過
3. `~/flutter/bin/flutter build apk --debug` — デバッグビルド成功
4. **手動テスト（デバイス）:**
   - tmux セッション内でタッチスワイプによるスクロールが動作する
   - tmux 外（通常シェル）のスクロールバックが正常に動作する
   - 水平スワイプによるタブ切替が正常に動作する
   - テキスト選択（選択モード）が正常に動作する
   - 外付けマウスのスクロールが正常に動作する

---

## 技術的補足

### なぜ Listener が安全か

- `Listener` は Flutter のジェスチャアリーナに**参加しない**
- raw ポインタイベント（`PointerDownEvent`, `PointerMoveEvent` 等）を直接受け取る
- 同じイベントは引き続き xterm 内部の `Scrollable` にも届くが、alt buffer では `maxScrollExtent=0` のため実質的に無動作
- ジェスチャの「横取り」ではなく「並行処理」であるため、タップ・長押し等の他のジェスチャに影響しない

### tmux マウスモードとの関係

- Phase 33 で `tmux set-option -t <session> mouse on` を設定済み
- マウスモード ON の場合: `terminal.mouseInput(wheelUp/wheelDown)` が `true` を返し、マウスエスケープシーケンスを送信 → tmux がスクロール処理
- マウスモード OFF の場合: `mouseInput()` が `false` を返し、フォールバックとして `keyInput(arrowUp/arrowDown)` を送信
