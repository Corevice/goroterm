import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error/app_error.dart';
import 'tmux_provider.dart';
import 'tmux_session_model.dart';

class TmuxManagerScreen extends ConsumerStatefulWidget {
  const TmuxManagerScreen({
    super.key,
    required this.connectionId,
    this.onAttachSession,
  });

  final String connectionId;

  /// Called when the user taps a session to attach.
  /// When provided, this overrides the default inline-attach behavior so the
  /// caller can open a new tab instead. The Drawer is still closed by the
  /// default [_SessionListView] Navigator.pop before this is invoked.
  final void Function(String tmuxSessionName)? onAttachSession;

  @override
  ConsumerState<TmuxManagerScreen> createState() => _TmuxManagerScreenState();
}

class _TmuxManagerScreenState extends ConsumerState<TmuxManagerScreen> {
  AsyncValue<TmuxState> _tmuxState = const AsyncLoading();
  ProviderSubscription<AsyncValue<TmuxState>>? _subscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _subscription = ref.listenManual(
        tmuxProvider(widget.connectionId),
        (_, next) {
          if (mounted) setState(() => _tmuxState = next);
        },
        fireImmediately: true,
      );
    });
  }

  @override
  void dispose() {
    _subscription?.close();
    super.dispose();
  }

  Future<void> _createSession(String name) async {
    if (!mounted) return;
    try {
      await ref
          .read(tmuxProvider(widget.connectionId).notifier)
          .createSession(name);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create session: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey[900],
      child: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: _tmuxState.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => _ErrorView(
                error: e,
                onRetry: () =>
                    ref.invalidate(tmuxProvider(widget.connectionId)),
              ),
              data: (state) => !state.isAvailable
                  ? _NotInstalledView(
                      onRetry: () =>
                          ref.invalidate(tmuxProvider(widget.connectionId)),
                    )
                  : _SessionListView(
                      state: state,
                      canOpenAll: widget.onAttachSession != null,
                      onRefresh: () => ref
                          .read(tmuxProvider(widget.connectionId).notifier)
                          .refresh(),
                      onAttach: (name) {
                        if (widget.onAttachSession != null) {
                          widget.onAttachSession!(name);
                        } else {
                          ref
                              .read(tmuxProvider(widget.connectionId).notifier)
                              .attachSession(name);
                        }
                      },
                      onOpenAll: widget.onAttachSession != null
                          ? () {
                              for (final s in state.sessions) {
                                widget.onAttachSession!(s.name);
                              }
                            }
                          : null,
                      onDelete: (name) => ref
                          .read(tmuxProvider(widget.connectionId).notifier)
                          .killSession(name),
                      onRename: (oldName, newName) => ref
                          .read(tmuxProvider(widget.connectionId).notifier)
                          .renameSession(oldName, newName),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      color: Colors.grey[850],
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.view_list, color: Colors.tealAccent, size: 20),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'tmux Sessions',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.refresh, color: Colors.grey[400], size: 20),
            tooltip: 'Refresh',
            onPressed: () =>
                ref.read(tmuxProvider(widget.connectionId).notifier).refresh(),
          ),
          IconButton(
            icon: const Icon(Icons.add, color: Colors.tealAccent, size: 20),
            tooltip: 'New session',
            onPressed: () => _showCreateDialog(context),
          ),
        ],
      ),
    );
  }

  Future<void> _showCreateDialog(BuildContext context) async {
    final asyncState = ref.read(tmuxProvider(widget.connectionId));
    final existingNames = asyncState.valueOrNull?.sessions
            .map((s) => s.name)
            .toList() ??
        [];

    final controller = TextEditingController();
    String? errorText;
    String currentInput = ''; // onChanged で受け取った表示テキスト（composing 含む）を保持

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: Colors.grey[850],
          title: const Text(
            'New tmux Session',
            style: TextStyle(color: Colors.white),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Session name',
              hintStyle: TextStyle(color: Colors.grey[600]),
              errorText: errorText,
              enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.grey),
              ),
              focusedBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.tealAccent),
              ),
            ),
            onChanged: (v) {
              currentInput = v; // 表示テキスト（composing 含む）を保持
              setDialogState(() {
                errorText = validateTmuxSessionName(v, existingNames);
              });
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: errorText != null
                  ? null
                  : () {
                      // controller.text ではなく onChanged で受け取った
                      // 表示テキストを使う（IME 未確定文字を含む）
                      final name = currentInput.trim();
                      final err =
                          validateTmuxSessionName(name, existingNames);
                      if (err != null) {
                        setDialogState(() => errorText = err);
                        return;
                      }
                      Navigator.of(ctx).pop();
                      _createSession(name);
                    },
              child: const Text(
                'Create',
                style: TextStyle(color: Colors.tealAccent),
              ),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }
}

// ---------------------------------------------------------------------------

class _SessionListView extends StatefulWidget {
  const _SessionListView({
    required this.state,
    required this.canOpenAll,
    required this.onRefresh,
    required this.onAttach,
    required this.onOpenAll,
    required this.onDelete,
    required this.onRename,
  });

  final TmuxState state;
  final bool canOpenAll;
  final Future<void> Function() onRefresh;
  final void Function(String name) onAttach;
  final VoidCallback? onOpenAll;
  final Future<void> Function(String name) onDelete;
  final Future<void> Function(String oldName, String newName) onRename;

  @override
  State<_SessionListView> createState() => _SessionListViewState();
}

class _SessionListViewState extends State<_SessionListView> {
  @override
  Widget build(BuildContext context) {
    if (widget.state.sessions.isEmpty) {
      return const Center(
        child: Text(
          'No sessions.\nTap + to create one.',
          style: TextStyle(color: Colors.grey),
          textAlign: TextAlign.center,
        ),
      );
    }

    final showOpenAll =
        widget.canOpenAll && widget.state.sessions.length > 1;

    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: ListView.builder(
        itemCount: widget.state.sessions.length + (showOpenAll ? 1 : 0),
        itemBuilder: (context, index) {
          if (showOpenAll && index == 0) {
            return _OpenAllButton(
              count: widget.state.sessions.length,
              onPressed: () {
                widget.onOpenAll?.call();
                Navigator.of(context).pop();
              },
            );
          }
          final sessionIdx = showOpenAll ? index - 1 : index;
          final session = widget.state.sessions[sessionIdx];
          return _SessionCard(
            session: session,
            onAttach: () {
              widget.onAttach(session.name);
              Navigator.of(context).pop();
            },
            onDelete: () => _confirmDelete(session.name),
            onRename: () => _showRenameDialog(session.name),
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[850],
        title: const Text(
          'Delete Session',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'Kill session "$name"? This will close all windows.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Kill',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      try {
        await widget.onDelete(name);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to kill session: $e')),
          );
        }
      }
    }
  }

  Future<void> _showRenameDialog(String oldName) async {
    final existingNames = widget.state.sessions
        .map((s) => s.name)
        .where((n) => n != oldName)
        .toList();

    final controller = TextEditingController(text: oldName);
    String? errorText;
    String currentInput = oldName; // 初期値を現在の名前に設定

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: Colors.grey[850],
          title: const Text(
            'Rename Session',
            style: TextStyle(color: Colors.white),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'New name',
              hintStyle: TextStyle(color: Colors.grey[600]),
              errorText: errorText,
              enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.grey),
              ),
              focusedBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.tealAccent),
              ),
            ),
            onChanged: (v) {
              currentInput = v; // 表示テキスト（composing 含む）を保持
              setDialogState(() {
                errorText = validateTmuxSessionName(v, existingNames);
              });
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: errorText != null
                  ? null
                  : () {
                      // controller.text ではなく onChanged で受け取った
                      // 表示テキストを使う（IME 未確定文字を含む）
                      final newName = currentInput.trim();
                      final err =
                          validateTmuxSessionName(newName, existingNames);
                      if (err != null) {
                        setDialogState(() => errorText = err);
                        return;
                      }
                      Navigator.of(ctx).pop();
                      _doRename(oldName, newName);
                    },
              child: const Text(
                'Rename',
                style: TextStyle(color: Colors.tealAccent),
              ),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }

  Future<void> _doRename(String oldName, String newName) async {
    if (!mounted) return;
    try {
      await widget.onRename(oldName, newName);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to rename session: $e')),
        );
      }
    }
  }
}

// ---------------------------------------------------------------------------

class _OpenAllButton extends StatelessWidget {
  const _OpenAllButton({required this.count, required this.onPressed});

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.open_in_new, size: 18),
        label: Text('Open all $count sessions'),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.tealAccent,
          side: BorderSide(color: Colors.tealAccent.withValues(alpha: 0.5)),
          minimumSize: const Size.fromHeight(40),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _SessionCard extends StatelessWidget {
  const _SessionCard({
    required this.session,
    required this.onAttach,
    required this.onDelete,
    required this.onRename,
  });

  final TmuxSession session;
  final VoidCallback onAttach;
  final VoidCallback onDelete;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: Key('tmux_session_${session.name}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        color: Colors.red[900],
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        onDelete();
        return false; // Handle deletion via dialog
      },
      child: Card(
        color: Colors.grey[850],
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: ListTile(
          leading: _statusBadge(session.isAttached),
          title: Text(
            session.name,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w500,
            ),
          ),
          subtitle: Text(
            '${session.windowCount} window${session.windowCount == 1 ? '' : 's'}'
            ' · ${_formatDate(session.createdAt)}',
            style: TextStyle(color: Colors.grey[500], fontSize: 12),
          ),
          trailing: IconButton(
            icon: Icon(Icons.edit, color: Colors.grey[400], size: 18),
            tooltip: 'Rename',
            onPressed: onRename,
          ),
          onTap: onAttach,
        ),
      ),
    );
  }

  Widget _statusBadge(bool attached) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: attached ? Colors.green : Colors.grey,
        shape: BoxShape.circle,
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}';
  }
}

// ---------------------------------------------------------------------------

class _NotInstalledView extends StatelessWidget {
  const _NotInstalledView({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.terminal, color: Colors.grey, size: 48),
          const SizedBox(height: 16),
          const Text(
            'tmux is not installed',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Install tmux on your server:',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 12),
          _InstallCommand(label: 'Debian/Ubuntu', cmd: 'sudo apt install tmux'),
          _InstallCommand(label: 'macOS', cmd: 'brew install tmux'),
          _InstallCommand(label: 'RHEL/Fedora', cmd: 'sudo dnf install tmux'),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Check again'),
          ),
        ],
      ),
    );
  }
}

class _InstallCommand extends StatelessWidget {
  const _InstallCommand({required this.label, required this.cmd});

  final String label;
  final String cmd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(color: Colors.grey[400], fontSize: 11),
            ),
          ),
          Expanded(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black38,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                cmd,
                style: const TextStyle(
                  color: Color(0xFF9CDCFE),
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = error is NetworkError
        ? 'SSH not connected'
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
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
