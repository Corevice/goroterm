import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/utils/shell_utils.dart';

/// Breadcrumb-style path bar.
///
/// - Tapping a segment navigates to that directory.
/// - Long-pressing (or tapping the copy icon) copies the full path to the
///   clipboard and schedules an auto-clear after [autoClearDuration].
class PathBarWidget extends StatefulWidget {
  const PathBarWidget({
    super.key,
    required this.path,
    required this.onNavigate,
    this.autoClearDuration = const Duration(seconds: 30),
  });

  final String path;
  final void Function(String path) onNavigate;
  final Duration autoClearDuration;

  @override
  State<PathBarWidget> createState() => _PathBarWidgetState();
}

class _PathBarWidgetState extends State<PathBarWidget> {
  Timer? _clearTimer;

  @override
  void dispose() {
    _clearTimer?.cancel();
    super.dispose();
  }

  List<String> get _segments {
    if (widget.path == '/') return ['/'];
    final parts = widget.path.split('/').where((s) => s.isNotEmpty).toList();
    return ['/', ...parts];
  }

  String _pathForIndex(int index) {
    if (index == 0) return '/';
    final segments = _segments.sublist(1, index + 1);
    return '/${segments.join('/')}';
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: widget.path));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied: ${widget.path}'),
        duration: const Duration(seconds: 2),
      ),
    );
    _scheduleAutoClear();
  }

  void _scheduleAutoClear() {
    _clearTimer?.cancel();
    _clearTimer = Timer(widget.autoClearDuration, () {
      Clipboard.setData(const ClipboardData(text: ''));
    });
  }

  @override
  Widget build(BuildContext context) {
    final segments = _segments;
    return Container(
      color: Colors.grey[800],
      height: 36,
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: segments.length,
              separatorBuilder: (_, __) => const Padding(
                padding: EdgeInsets.symmetric(horizontal: 2),
                child: Icon(
                  Icons.chevron_right,
                  color: Colors.grey,
                  size: 16,
                ),
              ),
              itemBuilder: (context, index) {
                final label = segments[index];
                final isLast = index == segments.length - 1;
                return GestureDetector(
                  onTap: isLast
                      ? null
                      : () => widget.onNavigate(_pathForIndex(index)),
                  child: Center(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: isLast ? Colors.white : Colors.blue[300],
                        fontSize: 13,
                        decoration: isLast
                            ? TextDecoration.none
                            : TextDecoration.underline,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, color: Colors.grey, size: 18),
            tooltip: 'Copy path',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            onPressed: _copyPath,
          ),
        ],
      ),
    );
  }
}

/// Returns the path after shell-escaping for safe terminal paste.
String shellEscapeForTerminal(String path) => shellQuote(path);
