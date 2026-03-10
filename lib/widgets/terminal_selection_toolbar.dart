import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

class TerminalSelectionToolbar extends StatelessWidget {
  const TerminalSelectionToolbar({
    super.key,
    required this.terminal,
    required this.controller,
    required this.onPaste,
    required this.onDismiss,
  });

  final Terminal terminal;
  final TerminalController controller;
  final void Function(String text) onPaste;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final hasSelection = controller.selection != null;
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      color: Colors.grey[800],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
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
      ),
    );
  }

  void _handleCopy(BuildContext context) {
    final selection = controller.selection;
    if (selection == null) return;
    final text = terminal.buffer.getText(selection);
    Clipboard.setData(ClipboardData(text: text));
    controller.clearSelection();
    onDismiss();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('コピーしました'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  Future<void> _handlePaste(BuildContext context) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      onPaste(data.text!);
    }
    controller.clearSelection();
    onDismiss();
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: Colors.white),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
