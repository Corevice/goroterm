import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/app_logger.dart';

import '../../core/theme/theme_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final fontSize = ref.watch(fontSizeProvider);

    return Scaffold(
      appBar: AppBar(
        title: Semantics(
          header: true,
          child: const Text('Settings'),
        ),
      ),
      body: ListView(
        children: [
          // Theme section
          const _SectionHeader(title: 'Appearance'),
          Semantics(
            label: 'Theme selection',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SegmentedButton<AppThemeMode>(
                segments: const [
                  ButtonSegment(
                    value: AppThemeMode.dark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode),
                  ),
                  ButtonSegment(
                    value: AppThemeMode.light,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode),
                  ),
                  ButtonSegment(
                    value: AppThemeMode.highContrast,
                    label: Text('High Contrast'),
                    icon: Icon(Icons.contrast),
                  ),
                ],
                selected: {themeMode},
                onSelectionChanged: (modes) {
                  if (modes.isNotEmpty) {
                    ref.read(themeModeProvider.notifier).setTheme(modes.first);
                  }
                },
              ),
            ),
          ),

          // Font size section
          const _SectionHeader(title: 'Terminal Font Size'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Size'),
                    Semantics(
                      label: 'Font size: ${fontSize.round()} pt',
                      child: Text(
                        '${fontSize.round()} pt',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                Semantics(
                  label: 'Terminal font size slider',
                  slider: true,
                  value: '${fontSize.round()} pt',
                  child: Slider(
                    value: fontSize,
                    min: 8.0,
                    max: 32.0,
                    divisions: 12,
                    label: '${fontSize.round()} pt',
                    onChanged: (value) {
                      ref.read(fontSizeProvider.notifier).setFontSize(value);
                    },
                  ),
                ),
              ],
            ),
          ),

          const Divider(),

          // Diagnostics section
          const _SectionHeader(title: 'Diagnostics'),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Connection Log'),
            subtitle: const Text('View SSH connection diagnostics'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ConnectionLogScreen(),
                ),
              );
            },
          ),

          const Divider(),

          // About section
          const _SectionHeader(title: 'About'),
          Semantics(
            button: true,
            label: 'Open source licenses',
            child: ListTile(
              leading: const Icon(Icons.article_outlined),
              title: const Text('Open Source Licenses'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                showLicensePage(
                  context: context,
                  applicationName: 'SSH Terminal',
                  applicationVersion: '1.0.0',
                );
              },
            ),
          ),
          Semantics(
            button: true,
            label: 'Privacy policy',
            child: ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('Privacy Policy'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PrivacyPolicyScreen(),
                  ),
                );
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Version'),
            trailing: const Text('1.0.0'),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Privacy Policy Screen
// ---------------------------------------------------------------------------

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Semantics(
          header: true,
          child: const Text('Privacy Policy'),
        ),
      ),
      body: const SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: _PrivacyPolicyContent(),
      ),
    );
  }
}

class _PrivacyPolicyContent extends StatelessWidget {
  const _PrivacyPolicyContent();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Privacy Policy', style: style.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'Last updated: March 2026',
          style: style.bodySmall,
        ),
        const SizedBox(height: 16),
        _Section(
          title: 'Data We Handle',
          body:
              'SSH Terminal handles the following sensitive data on your behalf:\n\n'
              '• SSH private keys and passphrases\n'
              '• SSH passwords (optional)\n'
              '• Known host fingerprints\n'
              '• SSH connection details (host, port, username)\n'
              '• Remote file paths accessed via SFTP',
        ),
        _Section(
          title: 'Data Storage',
          body:
              'All data is stored exclusively on your device:\n\n'
              '• SSH credentials are stored in the device\'s secure storage '
              '(iOS Keychain / Android EncryptedSharedPreferences).\n'
              '• Connection configurations are stored in a local SQLite '
              'database within the app\'s private sandbox.\n'
              '• No data is transmitted to external servers or third parties.\n'
              '• No analytics, telemetry, or crash data is collected.',
        ),
        _Section(
          title: 'Data We Do NOT Collect',
          body:
              'SSH Terminal does NOT:\n\n'
              '• Send any data to Anthropic or any third party\n'
              '• Collect usage analytics\n'
              '• Store SSH session content (commands or output)\n'
              '• Access files outside the app\'s sandbox',
        ),
        _Section(
          title: 'Permissions',
          body:
              '• Network access: Required to connect to SSH servers.\n'
              '• Storage (Android): Required only to save downloaded files '
              'to the device\'s Downloads folder.',
        ),
        _Section(
          title: 'Security',
          body:
              'We use platform-provided secure storage (iOS Keychain / '
              'Android Keystore) to protect your credentials. '
              'Host key verification is performed on every connection '
              'to protect against man-in-the-middle attacks.',
        ),
        _Section(
          title: 'Contact',
          body:
              'If you have questions about this privacy policy, please '
              'open an issue on the project\'s GitHub repository.',
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(body, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Connection Log Screen
// ---------------------------------------------------------------------------

class ConnectionLogScreen extends StatefulWidget {
  const ConnectionLogScreen({super.key});

  @override
  State<ConnectionLogScreen> createState() => _ConnectionLogScreenState();
}

class _ConnectionLogScreenState extends State<ConnectionLogScreen> {
  @override
  Widget build(BuildContext context) {
    final logger = AppLogger.instance;
    final entries = logger.entries;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connection Log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy all logs',
            onPressed: () {
              final text = logger.toText();
              if (text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('No logs to copy')),
                );
                return;
              }
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Copied ${entries.length} log entries'),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear logs',
            onPressed: () {
              logger.clear();
              setState(() {});
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Logs cleared')),
              );
            },
          ),
        ],
      ),
      body: entries.isEmpty
          ? const Center(
              child: Text(
                'No logs yet.\nConnect to an SSH server to see diagnostics.',
                textAlign: TextAlign.center,
              ),
            )
          : ListView.builder(
              reverse: true,
              itemCount: entries.length,
              itemBuilder: (context, index) {
                // reverse: true なので最新が上に来る
                final entry = entries[entries.length - 1 - index];
                final time =
                    '${entry.timestamp.hour.toString().padLeft(2, '0')}:'
                    '${entry.timestamp.minute.toString().padLeft(2, '0')}:'
                    '${entry.timestamp.second.toString().padLeft(2, '0')}';
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                  child: Text(
                    '$time ${entry.message}',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                );
              },
            ),
    );
  }
}
