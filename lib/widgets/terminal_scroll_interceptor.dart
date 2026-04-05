import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

// xterm 4.0.0 のバグ: wheelUp.id=68, wheelDown.id=69 だが、
// X11 マウスプロトコルの正しい値は wheelUp=64, wheelDown=65。
// tmux はボタン ID 68/69 を認識しないため mouseInput() でのスクロールが効かない。
// このファイルでは正しいエスケープシーケンスを直接生成して送信する。
const _kWheelUpButton = 64;
const _kWheelDownButton = 65;

/// alt buffer（tmux 等）使用時のスクロールを実現するウィジェット。
///
/// タッチスクロール: [Listener] で raw ポインタイベントを監視し変換。
/// マウスホイール/トラックパッド: [PointerSignalResolver] で xterm 内部の
/// InfiniteScrollView より先にイベントを獲得し、正しい wheel event を送信。
class TerminalScrollInterceptor extends StatefulWidget {
  const TerminalScrollInterceptor({
    super.key,
    required this.terminal,
    required this.child,
    this.disabled = false,
  });

  final Terminal terminal;
  final Widget child;

  /// true の場合、スクロールインターセプトを無効化する。
  final bool disabled;

  @override
  State<TerminalScrollInterceptor> createState() =>
      _TerminalScrollInterceptorState();
}

class _TerminalScrollInterceptorState
    extends State<TerminalScrollInterceptor> {
  // ドラッグ追跡用の状態（タッチ用）
  int? _activePointerId;
  double _accumulatedDelta = 0.0;
  Offset _lastPointerPosition = Offset.zero;

  // スクロール判定: 水平スワイプ（タブ切替）との競合を防ぐ
  bool _isVerticalDrag = false;
  bool _directionDecided = false;
  Offset _dragStartPosition = Offset.zero;

  // マウスホイール用アキュムレータ
  double _wheelAccumulator = 0.0;

  // 長押し判定との競合防止:
  // ポインタダウンから一定時間（_kLongPressDelay）以内に十分な移動がなければ
  // 長押しと判断してスクロールを無効化する。
  // Timer を使用することで tester.pump() によるテストが可能になる。
  static const _kLongPressDelay = Duration(milliseconds: 300);
  Timer? _longPressTimer;
  bool _longPressActivated = false;

  // 1行あたりのピクセル数（フォントサイズに依存）
  double get _lineHeight {
    final viewHeight = widget.terminal.viewHeight;
    if (viewHeight <= 0) return 20.0;
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return 20.0;
    return renderBox.size.height / viewHeight;
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // NotificationListener で内部 Scrollable の通知をキャッチして
    // alt buffer 中は握りつぶし、代わりに正しい wheel event を送る。
    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        onPointerSignal: _onPointerSignal,
        child: widget.child,
      ),
    );
  }

  /// xterm 内部 InfiniteScrollView の ScrollNotification を監視。
  /// alt buffer 中のスクロールを正しい wheel event に変換する。
  bool _onScrollNotification(ScrollNotification notification) {
    if (widget.disabled) return false;
    if (!widget.terminal.isUsingAltBuffer) {
      // alt buffer 外では積算値をクリアしておき、次回 alt buffer 入場時を
      // クリーンな状態から開始する（残留デルタによる誤スクロール防止）。
      _wheelAccumulator = 0.0;
      return false;
    }

    if (notification is ScrollUpdateNotification) {
      final dy = notification.scrollDelta ?? 0.0;
      if (dy == 0) return true;

      final lineHeight = _lineHeight;
      _wheelAccumulator += dy;

      // InfiniteScrollView はセル座標を提供しないので中央を使用。
      // renderBox の取得とセル座標計算はループ中に変化しないため外に出す。
      final renderBox = context.findRenderObject() as RenderBox?;
      final w = renderBox?.size.width ?? 400;
      final h = renderBox?.size.height ?? 300;
      final cellX = max(1, (w / 2 / (lineHeight * 0.6)).floor() + 1);
      final cellY = max(1, (h / 2 / lineHeight).floor() + 1);

      while (_wheelAccumulator.abs() >= lineHeight) {
        final isUp = _wheelAccumulator < 0;
        _wheelAccumulator += isUp ? lineHeight : -lineHeight;

        final handled = _sendWheelEvent(isUp, cellX, cellY);
        if (!handled) {
          widget.terminal.keyInput(
            isUp ? TerminalKey.arrowUp : TerminalKey.arrowDown,
          );
        }
      }
    }
    // true を返して内部の scroll を消費（visual scroll を防止）
    return true;
  }

  /// マウスホイール / トラックパッドスクロール。
  /// alt buffer 使用中は PointerSignalResolver に登録して
  /// xterm 内部の InfiniteScrollView より先にイベントを獲得する。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (widget.disabled) return;

    // Listener.onPointerSignal はデスクトップでは
    // 内部 Scrollable が先に resolve するため呼ばれないことがある。
    // 実際のスクロール処理は _onScrollNotification で行う。

    if (!widget.terminal.isUsingAltBuffer) return;

    // PointerSignalResolver で先に登録し、xterm 内部の Scrollable に勝つ
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (PointerSignalEvent resolvedEvent) {
        _handleWheelScroll(resolvedEvent as PointerScrollEvent);
      },
    );
  }

  void _handleWheelScroll(PointerScrollEvent event) {
    final dy = event.scrollDelta.dy;
    if (dy == 0) return;

    final lineHeight = _lineHeight;
    _wheelAccumulator += dy;

    while (_wheelAccumulator.abs() >= lineHeight) {
      final isUp = _wheelAccumulator < 0;
      _wheelAccumulator += isUp ? lineHeight : -lineHeight;

      final cellX =
          max(1, (event.localPosition.dx / (lineHeight * 0.6)).floor() + 1);
      final cellY =
          max(1, (event.localPosition.dy / lineHeight).floor() + 1);

      final handled = _sendWheelEvent(isUp, cellX, cellY);
      if (!handled) {
        widget.terminal.keyInput(
          isUp ? TerminalKey.arrowUp : TerminalKey.arrowDown,
        );
      }
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    // タッチのみ処理（マウスは無視）
    if (event.kind != PointerDeviceKind.touch) return;
    if (widget.disabled) return;
    if (!widget.terminal.isUsingAltBuffer) return;

    _activePointerId = event.pointer;
    _accumulatedDelta = 0.0;
    _lastPointerPosition = event.localPosition;
    _dragStartPosition = event.localPosition;
    _isVerticalDrag = false;
    _directionDecided = false;
    _longPressActivated = false;
    _longPressTimer?.cancel();
    _longPressTimer = Timer(_kLongPressDelay, () {
      _longPressActivated = true;
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _activePointerId) return;
    if (!widget.terminal.isUsingAltBuffer) {
      _reset();
      return;
    }

    // 方向 / 長押し判定（_directionDecided が true になるまで毎 move で評価）
    if (!_directionDecided) {
      final dx = (event.localPosition.dx - _dragStartPosition.dx).abs();
      final dy = (event.localPosition.dy - _dragStartPosition.dy).abs();

      // 十分な移動がないまま長押し時間が経過 → テキスト選択モードと判断して無効化
      if (_longPressActivated && dx + dy < 20) {
        _reset();
        return;
      }

      // 縦 vs 横の判定: 十分な移動量に達したら方向を確定
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
    while (_accumulatedDelta.abs() >= lineHeight) {
      final isUp = _accumulatedDelta < 0;
      _accumulatedDelta += isUp ? lineHeight : -lineHeight;

      final cellX =
          max(1, (event.localPosition.dx / (lineHeight * 0.6)).floor() + 1);
      final cellY = max(1, (event.localPosition.dy / lineHeight).floor() + 1);

      final handled = _sendWheelEvent(!isUp, cellX, cellY);
      if (!handled) {
        widget.terminal.keyInput(
          !isUp ? TerminalKey.arrowUp : TerminalKey.arrowDown,
        );
      }
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

  /// 正しいボタン ID でマウスホイールイベントを送信する。
  bool _sendWheelEvent(bool isUp, int x, int y) {
    final terminal = widget.terminal;

    final mouseMode = terminal.mouseMode;
    if (mouseMode == MouseMode.none || mouseMode == MouseMode.clickOnly) {
      return false;
    }

    final buttonId = isUp ? _kWheelUpButton : _kWheelDownButton;
    final reportMode = terminal.mouseReportMode;

    String seq;
    switch (reportMode) {
      case MouseReportMode.sgr:
        seq = '\x1b[<$buttonId;$x;${y}M';
        break;
      case MouseReportMode.normal:
      case MouseReportMode.utf:
        final btn = String.fromCharCode(32 + buttonId);
        final col = String.fromCharCode(32 + x);
        final row = String.fromCharCode(32 + y);
        seq = '\x1b[M$btn$col$row';
        break;
      case MouseReportMode.urxvt:
        seq = '\x1b[${32 + buttonId};$x;${y}M';
        break;
    }

    terminal.onOutput?.call(seq);
    return true;
  }

  void _reset() {
    _activePointerId = null;
    _accumulatedDelta = 0.0;
    _isVerticalDrag = false;
    _directionDecided = false;
    _wheelAccumulator = 0.0;
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _longPressActivated = false;
  }
}
