import 'package:flutter/material.dart';

/// tmux タブで表示する補助行。モバイルキーボードからは押しづらい
/// `Ctrl-B` プレフィックス + 後続キーをワンタップで送れるようにする。
///
/// 各ボタンは `\x02` (Ctrl-B) + 続くキーをまとめて `onSend` に渡す。
/// prefix を単独で送るボタンも置いてあるので、ここに無い操作 (window-select
/// 数字キーなど) はユーザーが続けて自分で入力できる。
class TmuxPrefixBar extends StatelessWidget {
  const TmuxPrefixBar({super.key, required this.onSend});

  /// terminal にバイト列を送る関数。
  /// 通常は `(text) => terminal.textInput(text)`。
  final void Function(String text) onSend;

  /// tmux デフォルトの prefix キー (Ctrl-B = ASCII 0x02)。
  static const String _prefix = '\x02';

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey[900],
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: SafeArea(
        top: false,
        bottom: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _PrefixButton(
                label: 'C-b',
                tooltip: 'Send Ctrl-B (prefix)',
                onPressed: () => onSend(_prefix),
              ),
              const SizedBox(width: 8),
              _PrefixButton(
                label: 'Detach',
                tooltip: 'Ctrl-B d',
                onPressed: () => onSend('${_prefix}d'),
              ),
              _PrefixButton(
                label: 'Copy',
                tooltip: 'Ctrl-B [ (copy-mode)',
                onPressed: () => onSend('$_prefix['),
              ),
              _PrefixButton(
                label: 'New',
                tooltip: 'Ctrl-B c (new-window)',
                onPressed: () => onSend('${_prefix}c'),
              ),
              _PrefixButton(
                label: '◀',
                tooltip: 'Ctrl-B p (previous-window)',
                onPressed: () => onSend('${_prefix}p'),
              ),
              _PrefixButton(
                label: '▶',
                tooltip: 'Ctrl-B n (next-window)',
                onPressed: () => onSend('${_prefix}n'),
              ),
              _PrefixButton(
                label: 'Wins',
                tooltip: 'Ctrl-B w (list-windows)',
                onPressed: () => onSend('${_prefix}w'),
              ),
              _PrefixButton(
                label: 'Rename',
                tooltip: 'Ctrl-B , (rename-window)',
                onPressed: () => onSend('$_prefix,'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrefixButton extends StatelessWidget {
  const _PrefixButton({
    required this.label,
    required this.onPressed,
    this.tooltip,
  });

  final String label;
  final String? tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final button = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: Colors.indigo[700],
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onPressed,
          child: Container(
            constraints: const BoxConstraints(minWidth: 44, minHeight: 32),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ),
      ),
    );
    final t = tooltip;
    if (t == null) return button;
    return Tooltip(message: t, child: button);
  }
}
