import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

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
    this.onClaudeContinue,
    this.onVoiceInput,
    this.isListening = false,
    this.onToggleKeyboard,
    this.keyboardOpen = false,
  });

  final void Function(TerminalKey key, {bool ctrl, bool shift}) onKeyPressed;
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
  final VoidCallback? onClaudeContinue;
  final VoidCallback? onVoiceInput;
  final bool isListening;

  /// Toggle the soft keyboard. When provided, a dedicated keyboard button is
  /// rendered as the **leftmost** action so the user controls keyboard
  /// visibility explicitly (avoids tab-open layout flash and improves
  /// long-press copy/paste reliability).
  final VoidCallback? onToggleKeyboard;
  final bool keyboardOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey[850],
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              if (onToggleKeyboard != null) ...[
                _KeyboardToggleButton(
                  isOpen: keyboardOpen,
                  onPressed: onToggleKeyboard!,
                ),
                const SizedBox(width: 8),
              ],
              if (onClaudeCommand != null)
                _ActionButton(
                  icon: Icons.auto_awesome,
                  onPressed: onClaudeCommand!,
                ),
              if (onClaudeContinue != null)
                _ActionButton(
                  icon: Icons.history,
                  onPressed: onClaudeContinue!,
                ),
              _ActionButton(
                label: 'C-j',
                onPressed: () => onKeyPressed(TerminalKey.keyJ, ctrl: true),
              ),
              _ActionButton(
                label: 'Esc',
                onPressed: () => onKeyPressed(TerminalKey.escape),
              ),
              const SizedBox(width: 8),
              _RepeatableActionButton(
                icon: Icons.arrow_upward,
                onPressed: () => onKeyPressed(TerminalKey.arrowUp),
              ),
              _RepeatableActionButton(
                icon: Icons.arrow_back,
                onPressed: () => onKeyPressed(TerminalKey.arrowLeft),
              ),
              _RepeatableActionButton(
                icon: Icons.arrow_forward,
                onPressed: () => onKeyPressed(TerminalKey.arrowRight),
              ),
              _RepeatableActionButton(
                icon: Icons.arrow_downward,
                onPressed: () => onKeyPressed(TerminalKey.arrowDown),
              ),
              const SizedBox(width: 8),
              if (onImagePaste != null) ...[
                _ActionButton(
                  icon: Icons.attach_file,
                  onPressed: onImagePaste!,
                ),
              ],
              if (onClipboardPaste != null) ...[
                _ActionButton(
                  icon: Icons.content_paste,
                  onPressed: onClipboardPaste!,
                ),
              ],
              if (onVoiceInput != null) ...[
                _ActionButton(
                  icon: isListening ? Icons.mic : Icons.mic_none,
                  onPressed: onVoiceInput!,
                ),
              ],
              if (onImagePaste != null || onClipboardPaste != null || onVoiceInput != null)
                const SizedBox(width: 8),
              _ActionButton(
                label: 'C-c',
                onPressed: () => onKeyPressed(TerminalKey.keyC, ctrl: true),
              ),
              _ActionButton(
                label: 'C-d',
                onPressed: () => onKeyPressed(TerminalKey.keyD, ctrl: true),
              ),
              _ActionButton(
                label: 'Tab',
                onPressed: () => onKeyPressed(TerminalKey.tab),
              ),
              _ActionButton(
                label: 'S-Tab',
                onPressed: () => onKeyPressed(TerminalKey.backtab, shift: true),
              ),
              _ActionButton(
                icon: Icons.keyboard_return,
                onPressed: () => onKeyPressed(TerminalKey.enter),
              ),
              _ActionButton(
                label: 'Ctrl',
                onPressed: () => _showCtrlMenu(context),
              ),
              const SizedBox(width: 8),
              _ActionButton(
                icon: Icons.vertical_align_top,
                onPressed: onScrollToTop ?? () {},
              ),
              _ActionButton(
                icon: Icons.vertical_align_bottom,
                onPressed: onScrollToBottom ?? () {},
              ),
              _ActionButton(
                label: 'PgUp',
                onPressed: onPageUp ?? () {},
              ),
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
              if (onToggleSelectMode != null) const SizedBox(width: 8),
              _ActionButton(
                label: '/',
                onPressed: () => onTextInput('/'),
              ),
              _ActionButton(
                label: '-',
                onPressed: () => onTextInput('-'),
              ),
              _ActionButton(
                label: '|',
                onPressed: () => onTextInput('|'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showCtrlMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (context) {
        // Derive keys from the map to avoid two lists drifting out of sync.
        // The map's insertion order defines the display order.
        final keys = _ctrlKeyMap.keys.toList();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: keys.map((key) {
                return ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey[800],
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                    onKeyPressed(
                      _terminalKeyFromChar(key),
                      ctrl: true,
                    );
                  },
                  child: Text('Ctrl+$key'),
                );
              }).toList(),
            ),
          ),
        );
      },
    );
  }

  // Insertion order defines the display order in the Ctrl menu.
  static const Map<String, TerminalKey> _ctrlKeyMap = {
    'C': TerminalKey.keyC,
    'D': TerminalKey.keyD,
    'J': TerminalKey.keyJ,
    'Z': TerminalKey.keyZ,
    'A': TerminalKey.keyA,
    'E': TerminalKey.keyE,
    'L': TerminalKey.keyL,
    'R': TerminalKey.keyR,
    'K': TerminalKey.keyK,
    'U': TerminalKey.keyU,
    'W': TerminalKey.keyW,
  };

  TerminalKey _terminalKeyFromChar(String char) =>
      _ctrlKeyMap[char] ?? TerminalKey.keyA;
}

/// Shared base for tap-style bar buttons:
/// Padding > Material (rounded) > InkWell > constrained Container.
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.child,
    required this.onPressed,
    this.color,
  });

  final Widget child;
  final VoidCallback onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: color ?? Colors.grey[800],
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onPressed,
          child: Container(
            constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _KeyboardToggleButton extends StatelessWidget {
  const _KeyboardToggleButton({
    required this.isOpen,
    required this.onPressed,
  });

  final bool isOpen;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _BarButton(
      onPressed: onPressed,
      color: isOpen ? Colors.blue[700] : Colors.grey[800],
      child: Icon(
        isOpen ? Icons.keyboard_hide : Icons.keyboard,
        size: 18,
        color: Colors.white,
      ),
    );
  }
}

class _SelectModeButton extends StatelessWidget {
  const _SelectModeButton({
    required this.isActive,
    required this.onPressed,
  });

  final bool isActive;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _BarButton(
      onPressed: onPressed,
      color: isActive ? Colors.blue[700] : Colors.grey[800],
      child: Icon(
        Icons.text_fields,
        size: 18,
        color: isActive ? Colors.white : Colors.white70,
      ),
    );
  }
}

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
  Timer? _activationTimer;
  bool _isPressed = false;
  bool _isCancelled = false;
  Offset? _downPosition;

  // 水平スクロール判定の閾値（px）
  static const _scrollThreshold = 8.0;
  // ボタン押下と判定するまでの遅延（長押しリピート開始）
  static const _activationDelay = Duration(milliseconds: 80);

  void _onPointerDown(PointerDownEvent event) {
    _downPosition = event.position;
    _isCancelled = false;
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
    if (dx > _scrollThreshold) {
      _cancel();
    }
  }

  void _startRepeat() {
    setState(() => _isPressed = true);
    widget.onPressed();
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
    final wasPendingActivation = _activationTimer?.isActive ?? false;
    _activationTimer?.cancel();
    _activationTimer = null;
    _repeatTimer?.cancel();
    _repeatTimer = null;
    _downPosition = null;
    // タイマー発火前の短いタップでも 1 回キー送信する。
    // _isCancelled（スクロール操作）の場合は送信しない。
    // _isPressed が false = まだ _startRepeat が呼ばれていない = タップが短い
    if (wasPendingActivation && !_isCancelled && !_isPressed && mounted) {
      widget.onPressed();
    }
    if (mounted) {
      setState(() => _isPressed = false);
    }
  }

  @override
  void deactivate() {
    // deactivate はビルドフェーズ中に呼ばれる場合があるため setState() 不可。
    // タイマーをキャンセルし、_isPressed を直接リセットして再活性化時のビジュアルを正す。
    _activationTimer?.cancel();
    _activationTimer = null;
    _repeatTimer?.cancel();
    _repeatTimer = null;
    _isPressed = false;
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

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    this.label,
    this.icon,
    required this.onPressed,
  }) : assert(label != null || icon != null, 'Either label or icon must be provided');

  final String? label;
  final IconData? icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _BarButton(
      onPressed: onPressed,
      child: icon != null
          ? Icon(icon, size: 18, color: Colors.white)
          : Text(
              label!,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
              ),
            ),
    );
  }
}

