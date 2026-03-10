import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'file_browser_provider.dart';

/// Previews a remote text file (up to 1 MB).
class FilePreviewScreen extends ConsumerStatefulWidget {
  const FilePreviewScreen({
    super.key,
    required this.connectionId,
    required this.remotePath,
    required this.filename,
  });

  final String connectionId;
  final String remotePath;
  final String filename;

  @override
  ConsumerState<FilePreviewScreen> createState() => _FilePreviewScreenState();
}

class _FilePreviewScreenState extends ConsumerState<FilePreviewScreen> {
  static const _maxBytes = 1024 * 1024; // 1 MB

  String? _content;
  String? _error;
  bool _loading = true;
  bool _truncated = false;

  @override
  void initState() {
    super.initState();
    _loadFile();
  }

  Future<void> _loadFile() async {
    try {
      final bytes = await ref
          .read(fileBrowserProvider(widget.connectionId).notifier)
          .readFileBytes(widget.remotePath, maxBytes: _maxBytes);

      // Check if truncated by comparing to file size hint.
      // We used the stat-based length in readFileBytes, so if bytes.length
      // equals _maxBytes exactly the file was likely truncated.
      final truncated = bytes.length >= _maxBytes;

      final text = utf8.decode(bytes, allowMalformed: true);
      if (mounted) {
        setState(() {
          _content = text;
          _truncated = truncated;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _copyContent() async {
    if (_content == null) return;
    await Clipboard.setData(ClipboardData(text: _content!));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Content copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        title: Text(
          widget.filename,
          style: const TextStyle(fontSize: 14),
        ),
        backgroundColor: Colors.grey[900],
        actions: [
          if (_content != null)
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copy content',
              onPressed: _copyContent,
            ),
          if (!_loading)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Reload',
              onPressed: () {
                setState(() {
                  _loading = true;
                  _content = null;
                  _error = null;
                });
                _loadFile();
              },
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        if (_truncated)
          Container(
            width: double.infinity,
            color: Colors.orange[900],
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: const Text(
              'File truncated at 1 MB',
              style: TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        Expanded(
          child: _CodeView(content: _content!),
        ),
      ],
    );
  }
}

/// Scrollable code view with line numbers.
class _CodeView extends StatelessWidget {
  const _CodeView({required this.content});

  final String content;

  @override
  Widget build(BuildContext context) {
    final lines = content.split('\n');
    final lineNumWidth = lines.length.toString().length;

    return SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: IntrinsicWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: List.generate(lines.length, (i) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: (lineNumWidth * 9.0) + 12,
                    padding: const EdgeInsets.only(right: 8),
                    alignment: Alignment.centerRight,
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 12,
                        fontFamily: 'monospace',
                        height: 1.5,
                      ),
                    ),
                  ),
                  Container(
                    width: 1,
                    height: 18,
                    color: Colors.grey[800],
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                  Text(
                    lines[i],
                    style: const TextStyle(
                      color: Color(0xFFD4D4D4),
                      fontSize: 12,
                      fontFamily: 'monospace',
                      height: 1.5,
                    ),
                  ),
                ],
              );
            }),
          ),
        ),
      ),
    );
  }
}
