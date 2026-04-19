import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/database.dart';
import '../../core/update/in_app_update_service.dart';
import '../terminal/session_manager.dart';
import 'connection_provider.dart';

class ConnectionListScreen extends ConsumerStatefulWidget {
  const ConnectionListScreen({super.key});

  @override
  ConsumerState<ConnectionListScreen> createState() =>
      _ConnectionListScreenState();
}

class _ConnectionListScreenState extends ConsumerState<ConnectionListScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      InAppUpdateService.checkAndPromptUpdate();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      InAppUpdateService.checkAndPromptUpdate();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final connectionsAsync = ref.watch(connectionListProvider);
    final activeSessions = ref.watch(
      sessionManagerProvider.select((s) => s.sessions.length),
    );

    return Scaffold(
      appBar: AppBar(
        title: Semantics(
          header: true,
          child: Text(l.sshConnections),
        ),
        actions: [
          Semantics(
            button: true,
            label: l.settings,
            child: IconButton(
              icon: const Icon(Icons.settings),
              tooltip: l.settings,
              onPressed: () => Navigator.of(context).pushNamed('/settings'),
            ),
          ),
        ],
      ),
      body: connectionsAsync.when(
        data: (connections) {
          final list = connections.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.terminal, size: 64, color: Colors.grey[600]),
                      const SizedBox(height: 16),
                      Text(
                        l.noConnectionsYet,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(l.tapPlusToAddConnection),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: connections.length,
                  itemBuilder: (context, index) {
                    final conn = connections[index];
                    return _ConnectionTile(connection: conn);
                  },
                );

          if (activeSessions == 0) return list;

          return Column(
            children: [
              _ResumeTerminalBanner(tabCount: activeSessions),
              Expanded(child: list),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(l.errorPrefix(error.toString()))),
      ),
      floatingActionButton: Semantics(
        button: true,
        label: l.addNewSshConnection,
        child: FloatingActionButton(
          onPressed: () {
            Navigator.of(context).pushNamed('/connection/edit');
          },
          tooltip: l.addConnection,
          child: const Icon(Icons.add),
        ),
      ),
    );
  }
}

class _ResumeTerminalBanner extends StatelessWidget {
  const _ResumeTerminalBanner({required this.tabCount});

  final int tabCount;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Material(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: InkWell(
        onTap: () => Navigator.of(context).pushNamed('/terminal'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.terminal),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l.resumeTerminalTabs(tabCount),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectionTile extends ConsumerWidget {
  const _ConnectionTile({required this.connection});

  final Connection connection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        child: const Icon(Icons.dns),
      ),
      title: Text(
        connection.label.isNotEmpty ? connection.label : connection.host,
      ),
      subtitle: Text('${connection.username}@${connection.host}:${connection.port}'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        final label = connection.label.isNotEmpty
            ? connection.label
            : connection.host;
        ref.read(sessionManagerProvider.notifier).addSession(
              connectionId: connection.id,
              label: label,
            );
        Navigator.of(context).pushNamed('/terminal');
      },
      onLongPress: () {
        showModalBottomSheet(
          context: context,
          builder: (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.edit),
                  title: Text(l.edit),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.of(context).pushNamed(
                      '/connection/edit/${connection.id}',
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete, color: Colors.red),
                  title:
                      Text(l.delete, style: const TextStyle(color: Colors.red)),
                  onTap: () {
                    Navigator.pop(context);
                    _confirmDelete(context, ref);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.deleteConnection),
        content: Text(
          l.deleteConnectionConfirm(
            connection.label.isNotEmpty ? connection.label : connection.host,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () {
              ref
                  .read(connectionListProvider.notifier)
                  .deleteConnection(connection.id);
              Navigator.pop(context);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l.delete),
          ),
        ],
      ),
    );
  }
}
