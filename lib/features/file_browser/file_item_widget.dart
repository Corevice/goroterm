import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

import '../../core/utils/format_utils.dart';
import 'file_browser_provider.dart';

/// Displays a single file or directory row with contextual actions.
class FileItemWidget extends StatelessWidget {
  const FileItemWidget({
    super.key,
    required this.item,
    required this.currentPath,
    required this.onTap,
    required this.onPasteToTerminal,
    required this.onPreview,
    required this.onDownload,
    required this.onDelete,
    required this.onRename,
  });

  final SftpName item;
  final String currentPath;
  final VoidCallback onTap;
  final void Function(String path) onPasteToTerminal;
  final void Function(String path) onPreview;
  final void Function(String path) onDownload;
  final void Function(String path, bool isDirectory) onDelete;
  final void Function(String oldPath, String currentName) onRename;

  String get _absolutePath {
    if (currentPath == '/') return '/${ item.filename}';
    return '$currentPath/${item.filename}';
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _fileIcon(item),
      title: Text(
        item.filename,
        style: const TextStyle(color: Colors.white),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: _subtitle(item),
      onTap: onTap,
      onLongPress: () => _showContextMenu(context),
    );
  }

  Widget _fileIcon(SftpName item) {
    final color = item.attr.isDirectory ? Colors.amber : Colors.grey[400]!;
    final icon = _iconForItem(item);
    return Icon(icon, color: color, size: 28);
  }

  IconData _iconForItem(SftpName item) {
    if (item.attr.isDirectory) return Icons.folder;
    if (item.attr.isSymbolicLink) return Icons.link;
    final name = item.filename.toLowerCase();
    if (_isImage(name)) return Icons.image;
    if (_isText(name)) return Icons.description;
    if (_isArchive(name)) return Icons.archive;
    if (_isCode(name)) return Icons.code;
    return Icons.insert_drive_file;
  }

  bool _isImage(String name) =>
      name.endsWith('.png') ||
      name.endsWith('.jpg') ||
      name.endsWith('.jpeg') ||
      name.endsWith('.gif') ||
      name.endsWith('.svg') ||
      name.endsWith('.webp');

  bool _isText(String name) =>
      name.endsWith('.txt') ||
      name.endsWith('.md') ||
      name.endsWith('.log') ||
      name.endsWith('.csv') ||
      name.endsWith('.json') ||
      name.endsWith('.yaml') ||
      name.endsWith('.yml') ||
      name.endsWith('.xml') ||
      name.endsWith('.ini') ||
      name.endsWith('.conf') ||
      name.endsWith('.cfg');

  bool _isArchive(String name) =>
      name.endsWith('.zip') ||
      name.endsWith('.tar') ||
      name.endsWith('.gz') ||
      name.endsWith('.bz2') ||
      name.endsWith('.xz') ||
      name.endsWith('.7z') ||
      name.endsWith('.rar');

  bool _isCode(String name) =>
      name.endsWith('.dart') ||
      name.endsWith('.py') ||
      name.endsWith('.js') ||
      name.endsWith('.ts') ||
      name.endsWith('.go') ||
      name.endsWith('.rs') ||
      name.endsWith('.c') ||
      name.endsWith('.cpp') ||
      name.endsWith('.h') ||
      name.endsWith('.java') ||
      name.endsWith('.sh') ||
      name.endsWith('.bash') ||
      name.endsWith('.zsh');

  bool _isPreviewable(SftpName item) =>
      item.attr.isFile && (_isText(item.filename) || _isCode(item.filename));

  Widget? _subtitle(SftpName item) {
    final parts = <String>[];
    if (!item.attr.isDirectory) {
      parts.add(humanReadableSize(item.attr.size));
    }
    parts.add(permissionString(item.attr.mode));
    if (item.attr.modifyTime != null) {
      final dt = DateTime.fromMillisecondsSinceEpoch(
        item.attr.modifyTime! * 1000,
      );
      parts.add(
          '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}');
    }
    if (parts.isEmpty) return null;
    return Text(
      parts.join('  '),
      style: TextStyle(color: Colors.grey[500], fontSize: 11),
    );
  }

  void _showContextMenu(BuildContext context) {
    final path = _absolutePath;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (ctx) {
        final l = AppLocalizations.of(context);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.copy, color: Colors.white),
                title: Text(
                  l.copyPath,
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  Clipboard.setData(ClipboardData(text: path));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(l.copiedPath(path)),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.terminal, color: Colors.white),
                title: Text(
                  l.pasteToTerminal,
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  onPasteToTerminal(path);
                },
              ),
              if (_isPreviewable(item))
                ListTile(
                  leading: const Icon(Icons.visibility, color: Colors.white),
                  title: Text(
                    l.preview,
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    onPreview(path);
                  },
                ),
              if (item.attr.isFile)
                ListTile(
                  leading: const Icon(Icons.download, color: Colors.white),
                  title: Text(
                    l.download,
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    onDownload(path);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline,
                    color: Colors.white),
                title: Text(
                  l.rename,
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  onRename(path, item.filename);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: Text(
                  l.delete,
                  style: const TextStyle(color: Colors.red),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  onDelete(path, item.attr.isDirectory);
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
