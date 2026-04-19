import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/error/app_error.dart';
import '../../core/utils/shell_utils.dart';
import '../terminal/terminal_connection_provider.dart';
import 'file_browser_provider.dart';
import 'file_item_widget.dart';
import 'file_preview_screen.dart';
import 'path_bar_widget.dart';

class FileBrowserScreen extends ConsumerWidget {
  const FileBrowserScreen({super.key, required this.connectionId});

  final String connectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(fileBrowserProvider(connectionId));

    return Container(
      color: Colors.grey[900],
      child: Column(
        children: [
          _Header(connectionId: connectionId),
          Expanded(
            child: asyncState.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => _ErrorView(
                error: e,
                onRetry: () =>
                    ref.invalidate(fileBrowserProvider(connectionId)),
              ),
              data: (state) => _BrowserBody(
                connectionId: connectionId,
                state: state,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.connectionId});

  final String connectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(fileBrowserProvider(connectionId));
    final state = asyncState.valueOrNull;
    final l = AppLocalizations.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          color: Colors.grey[850],
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              const Icon(Icons.folder_open, color: Colors.amber, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.fileBrowser,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (state != null) ...[
                IconButton(
                  icon: Icon(
                    state.showHidden
                        ? Icons.visibility
                        : Icons.visibility_off,
                    color: Colors.grey[400],
                    size: 20,
                  ),
                  tooltip:
                      state.showHidden ? l.hideDotfiles : l.showDotfiles,
                  onPressed: () =>
                      ref.read(fileBrowserProvider(connectionId).notifier)
                          .toggleHidden(),
                ),
                IconButton(
                  icon: Icon(Icons.upload_file,
                      color: Colors.grey[400], size: 20),
                  tooltip: l.uploadFile,
                  onPressed: () => _pickAndUploadFile(context, ref),
                ),
                IconButton(
                  icon: Icon(Icons.refresh, color: Colors.grey[400], size: 20),
                  tooltip: l.refresh,
                  onPressed: () =>
                      ref.read(fileBrowserProvider(connectionId).notifier)
                          .refresh(),
                ),
              ],
            ],
          ),
        ),
        if (state != null)
          PathBarWidget(
            path: state.currentPath,
            onNavigate: (path) =>
                ref.read(fileBrowserProvider(connectionId).notifier)
                    .navigateTo(path),
          ),
      ],
    );
  }

  Future<void> _pickAndUploadFile(BuildContext context, WidgetRef ref) async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.path == null) return;

    try {
      await ref
          .read(fileBrowserProvider(connectionId).notifier)
          .uploadFile(file.path!);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).uploadFailed(e.toString()))),
        );
      }
    }
  }
}

class _BrowserBody extends ConsumerWidget {
  const _BrowserBody({
    required this.connectionId,
    required this.state,
  });

  final String connectionId;
  final FileBrowserState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(fileBrowserProvider(connectionId).notifier);
    final connectionState =
        ref.read(terminalConnectionProvider(connectionId));
    final terminal = connectionState.terminal;
    final l = AppLocalizations.of(context);

    final downloading = state.downloadProgress != null;
    final downloaded = state.downloadedFilePath != null;
    final hasDownloadError = state.downloadError != null;
    final uploading = state.uploadProgress != null;
    final uploaded = state.uploadCompleteFile != null;

    final visibleItems = state.visibleItems;

    return Column(
      children: [
        if (downloading)
          LinearProgressIndicator(
            value: state.downloadProgress,
            backgroundColor: Colors.grey[800],
          ),
        if (downloaded)
          MaterialBanner(
            backgroundColor: Colors.green[900],
            content: Text(
              l.downloadCompleted(p.basename(state.downloadedFilePath!)),
              style: const TextStyle(color: Colors.white, fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              TextButton(
                onPressed: notifier.clearDownloadNotification,
                child: Text(l.ok, style: const TextStyle(color: Colors.white)),
              ),
            ],
          ),
        if (hasDownloadError)
          MaterialBanner(
            backgroundColor: Colors.red[900],
            content: Text(
              l.downloadError(state.downloadError!),
              style: const TextStyle(color: Colors.white, fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              TextButton(
                onPressed: notifier.clearDownloadError,
                child: Text(l.ok, style: const TextStyle(color: Colors.white)),
              ),
            ],
          ),
        if (uploading)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.uploadingPercent((state.uploadProgress! * 100).round()),
                  style: TextStyle(color: Colors.grey[400], fontSize: 12),
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: state.uploadProgress,
                  backgroundColor: Colors.grey[800],
                  color: Colors.tealAccent,
                ),
              ],
            ),
          ),
        if (uploaded)
          MaterialBanner(
            backgroundColor: Colors.teal[900],
            content: Text(
              l.uploadCompleted(state.uploadCompleteFile!),
              style: const TextStyle(color: Colors.white, fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              TextButton(
                onPressed: notifier.clearUploadNotification,
                child: Text(l.ok, style: const TextStyle(color: Colors.white)),
              ),
            ],
          ),
        // Back navigation row
        if (state.parentPath != null)
          ListTile(
            leading: const Icon(Icons.arrow_upward, color: Colors.grey),
            title: const Text('..', style: TextStyle(color: Colors.grey)),
            onTap: () => notifier.navigateTo(state.parentPath!),
          ),
        Expanded(
          child: visibleItems.isEmpty
              ? Center(
                  child: Text(
                    l.emptyDirectory,
                    style: const TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  itemCount: visibleItems.length,
                  itemBuilder: (context, index) {
                    final item = visibleItems[index];
                    return FileItemWidget(
                      item: item,
                      currentPath: state.currentPath,
                      onTap: () {
                        if (item.attr.isDirectory) {
                          final newPath = state.currentPath == '/'
                              ? '/${item.filename}'
                              : '${state.currentPath}/${item.filename}';
                          notifier.navigateTo(newPath);
                        }
                      },
                      onPasteToTerminal: (path) {
                        final escaped = shellQuote(path);
                        terminal?.textInput(escaped);
                      },
                      onPreview: (path) {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => FilePreviewScreen(
                              connectionId: connectionId,
                              remotePath: path,
                              filename: item.filename,
                            ),
                          ),
                        );
                      },
                      onDownload: (path) => notifier.downloadFile(path),
                      onDelete: (path, isDir) =>
                          _confirmDelete(context, ref, path, isDir),
                      onRename: (oldPath, currentName) =>
                          _showRenameDialog(context, ref, oldPath, currentName),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    String path,
    bool isDir,
  ) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: Text(
          isDir ? l.deleteDirectoryConfirm : l.deleteFileConfirm,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          p.basename(path),
          style: TextStyle(color: Colors.grey[400]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.delete, style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(fileBrowserProvider(connectionId).notifier)
          .deleteFile(path, isDirectory: isDir);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).deleteFailed(e.toString()))),
        );
      }
    }
  }

  Future<void> _showRenameDialog(
    BuildContext context,
    WidgetRef ref,
    String oldPath,
    String currentName,
  ) async {
    final l = AppLocalizations.of(context);
    final controller = TextEditingController(text: currentName);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: Text(
          l.rename,
          style: const TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: l.newName,
            hintStyle: TextStyle(color: Colors.grey[600]),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(l.rename),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newName == null || newName.isEmpty || newName == currentName) return;

    final dir = p.dirname(oldPath);
    final newPath = '$dir/$newName';
    try {
      await ref
          .read(fileBrowserProvider(connectionId).notifier)
          .renameFile(oldPath, newPath);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).renameFailed(e.toString()))),
        );
      }
    }
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final message = error is NetworkError
        ? l.sshNotConnected
        : error is PermissionError
            ? l.permissionDenied
            : error.toString();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 8),
            Text(
              message,
              style: const TextStyle(color: Colors.red),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(l.retry),
            ),
          ],
        ),
      ),
    );
  }
}
