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

/// alt buffer（tmux 等）使用時のタッチスクロールを実現するウィジェット。
///
/// [Listener] で raw ポインタイベントを **監視** するだけで、
/// 子ウィジェット（TerminalView）への伝播は一切妨げない。
/// これにより:
///   - TerminalView の内部タップ処理（キーボード表示）がそのまま動作
///   - テキスト選択も正常に動作
///   - ウィジェットツリーが alt buffer 状態で変化しないためリビルド問題なし
///
/// alt buffer 時は垂直ドラッグを検出して terminal.mouseInput() に変換。
/// xterm 内部の Scrollable は alt buffer では maxScrollExtent=0 のため
/// ドラッグしても何も起きず、本ウィジェットの mouseInput が唯一の効果。
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
  /// テキスト選択モード時に使用。
  final bool disabled;

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
  double get _lineHeight {
    final viewHeight = widget.terminal.viewHeight;
    if (viewHeight <= 0) return 20.0;
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return 20.0;
    return renderBox.size.height / viewHeight;
  }

  @override
  Widget build(BuildContext context) {
    // Listener は子へのイベント伝播を妨げない。
    // TerminalView は通常通り全ポインタイベントを受信する。
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: widget.child,
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    // タッチのみ処理（マウスは無視）
    if (event.kind != PointerDeviceKind.touch) return;
    // 選択モード中はスクロールインターセプトしない
    if (widget.disabled) return;
    // alt buffer でなければ無視（normal buffer は xterm 内部 Scrollable に任せる）
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

    // 方向判定: 最初の十分な移動で縦 vs 横を決定
    if (!_directionDecided) {
      final dx = (event.localPosition.dx - _dragStartPosition.dx).abs();
      final dy = (event.localPosition.dy - _dragStartPosition.dy).abs();
      // 閾値: 10px
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
    // 蓄積デルタが 1 行分を超えたらスクロールイベントを送信
    while (_accumulatedDelta.abs() >= lineHeight) {
      // isUp: アキュムレータ収束用の方向フラグ（変更禁止）
      // _accumulatedDelta > 0 → 指を下にスワイプ → コンテンツを上へ → wheelUp
      // _accumulatedDelta < 0 → 指を上にスワイプ → コンテンツを下へ → wheelDown
      final isUp = _accumulatedDelta < 0;
      _accumulatedDelta += isUp ? lineHeight : -lineHeight;

      // ポインタ位置からセル座標を概算（1-based for protocol）
      final cellX =
          max(1, (event.localPosition.dx / (lineHeight * 0.6)).floor() + 1);
      final cellY = max(1, (event.localPosition.dy / lineHeight).floor() + 1);

      // 方向反転: isUp はアキュムレータ用なので、ホイールイベントは逆にする
      // 指を下にスワイプ(isUp=false) → 上にスクロール(wheelUp=true)
      // 指を上にスワイプ(isUp=true) → 下にスクロール(wheelUp=false)
      final handled = _sendWheelEvent(!isUp, cellX, cellY);
      // tmux のマウスモードが OFF の場合のフォールバック:
      // arrow key を送信（copy mode 内では有効）
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
  /// xterm 4.0.0 の mouseInput() はボタン ID にバグがあるため、
  /// ここで正しいエスケープシーケンスを直接生成する。
  bool _sendWheelEvent(bool isUp, int x, int y) {
    final terminal = widget.terminal;

    // マウスモードが none か clickOnly なら処理しない
    final mouseMode = terminal.mouseMode;
    if (mouseMode == MouseMode.none || mouseMode == MouseMode.clickOnly) {
      return false;
    }

    final buttonId = isUp ? _kWheelUpButton : _kWheelDownButton;
    final reportMode = terminal.mouseReportMode;

    String seq;
    switch (reportMode) {
      case MouseReportMode.sgr:
        // SGR format: \x1b[<button;x;yM
        seq = '\x1b[<$buttonId;$x;${y}M';
        break;
      case MouseReportMode.normal:
      case MouseReportMode.utf:
        // Normal/UTF format: \x1b[M + char(32+button) + char(32+x) + char(32+y)
        final btn = String.fromCharCode(32 + buttonId);
        final col = String.fromCharCode(32 + x);
        final row = String.fromCharCode(32 + y);
        seq = '\x1b[M$btn$col$row';
        break;
      case MouseReportMode.urxvt:
        // URxvt format: \x1b[button;x;yM
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
  }
}
