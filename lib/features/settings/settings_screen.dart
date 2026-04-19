import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/preferences/power_settings.dart';
import '../../core/utils/app_logger.dart';

import '../../core/theme/theme_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final fontSize = ref.watch(fontSizeProvider);
    final l = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Semantics(
          header: true,
          child: Text(l.settings),
        ),
      ),
      body: ListView(
        children: [
          // Theme section
          _SectionHeader(title: l.appearance),
          Semantics(
            label: l.themeSelection,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SegmentedButton<AppThemeMode>(
                segments: [
                  ButtonSegment(
                    value: AppThemeMode.dark,
                    label: Text(l.themeDark),
                    icon: const Icon(Icons.dark_mode),
                  ),
                  ButtonSegment(
                    value: AppThemeMode.light,
                    label: Text(l.themeLight),
                    icon: const Icon(Icons.light_mode),
                  ),
                  ButtonSegment(
                    value: AppThemeMode.highContrast,
                    label: Text(l.themeHighContrast),
                    icon: const Icon(Icons.contrast),
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
          _SectionHeader(title: l.terminalFontSize),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(l.size),
                    Semantics(
                      label: l.fontSizePt(fontSize.round()),
                      child: Text(
                        l.fontSizePt(fontSize.round()),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                Semantics(
                  label: l.terminalFontSizeSlider,
                  slider: true,
                  value: l.fontSizePt(fontSize.round()),
                  child: Slider(
                    value: fontSize,
                    min: 8.0,
                    max: 32.0,
                    divisions: 12,
                    label: l.fontSizePt(fontSize.round()),
                    onChanged: (value) {
                      ref.read(fontSizeProvider.notifier).setFontSize(value);
                    },
                  ),
                ),
              ],
            ),
          ),

          const Divider(),

          // Power section
          _SectionHeader(title: l.batterySaving),
          const _PowerSettingsTile(),

          const Divider(),

          // Diagnostics section
          _SectionHeader(title: l.diagnostics),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: Text(l.connectionLog),
            subtitle: Text(l.viewSshDiagnostics),
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
          _SectionHeader(title: l.about),
          Semantics(
            button: true,
            label: l.openSourceLicensesLabel,
            child: ListTile(
              leading: const Icon(Icons.article_outlined),
              title: Text(l.openSourceLicenses),
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
            label: l.privacyPolicyLabel,
            child: ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: Text(l.privacyPolicy),
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
            title: Text(l.version),
            trailing: const Text('1.0.0'),
          ),
        ],
      ),
    );
  }
}

class _PowerSettingsTile extends ConsumerWidget {
  const _PowerSettingsTile();

  String _formatSeconds(int s) =>
      s >= 60 ? '${s ~/ 60} min' : '$s sec';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tick = ref.watch(tickIntervalProvider);
    final tcp = ref.watch(tcpKeepaliveIdleProvider);
    final l = AppLocalizations.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  l.backgroundHealthCheck,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              DropdownButton<int>(
                value: tick,
                items: [
                  for (final v in tickPresetSeconds)
                    DropdownMenuItem(value: v, child: Text(_formatSeconds(v))),
                ],
                onChanged: (v) {
                  if (v != null) {
                    ref.read(tickIntervalProvider.notifier).setValue(v);
                  }
                },
              ),
            ],
          ),
          Text(
            l.backgroundHealthCheckHelp,
            style: Theme.of(context).textTheme.bodySmall,
          ),

          const SizedBox(height: 16),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  l.tcpKeepaliveInterval,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              DropdownButton<int>(
                value: tcp,
                items: [
                  for (final v in tcpKeepalivePresetSeconds)
                    DropdownMenuItem(value: v, child: Text(_formatSeconds(v))),
                ],
                onChanged: (v) {
                  if (v != null) {
                    ref.read(tcpKeepaliveIdleProvider.notifier).setValue(v);
                  }
                },
              ),
            ],
          ),
          Text(
            l.tcpKeepaliveHelp,
            style: Theme.of(context).textTheme.bodySmall,
          ),

          const SizedBox(height: 8),
          Text(
            l.settingsApplyOnRestart,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                ),
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
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Semantics(
          header: true,
          child: Text(l.privacyPolicy),
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
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.privacyPolicy, style: style.headlineSmall),
        const SizedBox(height: 8),
        Text(
          l.privacyLastUpdated,
          style: style.bodySmall,
        ),
        const SizedBox(height: 16),
        _Section(
          title: l.privacyDataWeHandle,
          body: l.privacyDataWeHandleBody,
        ),
        _Section(
          title: l.privacyDataStorage,
          body: l.privacyDataStorageBody,
        ),
        _Section(
          title: l.privacyDataNotCollect,
          body: l.privacyDataNotCollectBody,
        ),
        _Section(
          title: l.privacyPermissions,
          body: l.privacyPermissionsBody,
        ),
        _Section(
          title: l.privacySecurity,
          body: l.privacySecurityBody,
        ),
        _Section(
          title: l.privacyContact,
          body: l.privacyContactBody,
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
    final l = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l.connectionLog),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: l.copyAllLogs,
            onPressed: () {
              final text = logger.toText();
              if (text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l.noLogsToCopy)),
                );
                return;
              }
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(l.copiedLogEntries(entries.length)),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: l.clearLogs,
            onPressed: () {
              logger.clear();
              setState(() {});
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l.logsCleared)),
              );
            },
          ),
        ],
      ),
      body: entries.isEmpty
          ? Center(
              child: Text(
                l.noLogsYet,
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
