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
