import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/database.dart';
import '../terminal/session_manager.dart';
import 'connection_provider.dart';

class ConnectionListScreen extends ConsumerWidget {
  const ConnectionListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionsAsync = ref.watch(connectionListProvider);
    final activeSessions = ref.watch(
      sessionManagerProvider.select((s) => s.sessions.length),
    );

    return Scaffold(
      appBar: AppBar(
        title: Semantics(
          header: true,
          child: const Text('SSH Connections'),
        ),
        actions: [
          Semantics(
            button: true,
            label: 'Settings',
            child: IconButton(
              icon: const Icon(Icons.settings),
              tooltip: 'Settings',
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
                        'No connections yet',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      const Text('Tap + to add a new SSH connection'),
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
        error: (error, _) => Center(child: Text('Error: $error')),
      ),
      floatingActionButton: Semantics(
        button: true,
        label: 'Add new SSH connection',
        child: FloatingActionButton(
          onPressed: () {
            Navigator.of(context).pushNamed('/connection/edit');
          },
          tooltip: 'Add connection',
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
    final label =
        'Resume terminal ($tabCount tab${tabCount == 1 ? '' : 's'})';
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
                  label,
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
                  title: const Text('Edit'),
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
                      const Text('Delete', style: TextStyle(color: Colors.red)),
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
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Connection'),
        content: Text(
          'Delete "${connection.label.isNotEmpty ? connection.label : connection.host}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              ref
                  .read(connectionListProvider.notifier)
                  .deleteConnection(connection.id);
              Navigator.pop(context);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
