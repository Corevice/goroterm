import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/debug/pty_byte_recorder.dart';
import '../../core/preferences/power_settings.dart';
import '../../core/theme/theme_provider.dart';
import '../../core/utils/app_logger.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final fontSize = ref.watch(fontSizeProvider);
    final selectedLocale = ref.watch(localeProvider);
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
          // Language section
          _SectionHeader(title: l.language),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: DropdownButton<String>(
              isExpanded: true,
              value: selectedLocale?.languageCode ?? '',
              items: [
                DropdownMenuItem(value: '', child: Text(l.languageSystem)),
                DropdownMenuItem(value: 'en', child: Text(l.languageEnglish)),
                DropdownMenuItem(value: 'ja', child: Text(l.languageJapanese)),
                DropdownMenuItem(value: 'id', child: Text(l.languageIndonesian)),
              ],
              onChanged: (code) {
                ref.read(localeProvider.notifier).setLocale(
                      code == null || code.isEmpty ? null : Locale(code),
                    );
              },
            ),
          ),

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

          // Voice input language section
          _SectionHeader(title: l.voiceInput),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: DropdownButton<VoiceInputLanguage>(
              isExpanded: true,
              value: ref.watch(voiceInputLanguageProvider),
              items: [
                DropdownMenuItem(
                    value: VoiceInputLanguage.autoDetect,
                    child: Text(l.voiceInputAutoDetect)),
                DropdownMenuItem(
                    value: VoiceInputLanguage.japanese,
                    child: Text(l.voiceInputJapanese)),
                DropdownMenuItem(
                    value: VoiceInputLanguage.english,
                    child: Text(l.voiceInputEnglish)),
                DropdownMenuItem(
                    value: VoiceInputLanguage.indonesian,
                    child: Text(l.voiceInputIndonesian)),
              ],
              onChanged: (lang) {
                if (lang != null) {
                  ref.read(voiceInputLanguageProvider.notifier)
                      .setLanguage(lang);
                }
              },
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
          ListTile(
            leading: const Icon(Icons.fiber_manual_record_outlined),
            title: const Text('PTY バイト記録'),
            subtitle: const Text('描画崩れ再現時に raw bytes をファイルへ保存'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const PtyRecorderScreen(),
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

class PtyRecorderScreen extends StatefulWidget {
  const PtyRecorderScreen({super.key});

  @override
  State<PtyRecorderScreen> createState() => _PtyRecorderScreenState();
}

class _PtyRecorderScreenState extends State<PtyRecorderScreen> {
  List<File> _files = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final files = await PtyByteRecorder.instance.listLogs();
    if (!mounted) return;
    setState(() {
      _files = files;
      _loading = false;
    });
  }

  Future<void> _toggle(bool on) async {
    if (on) {
      await PtyByteRecorder.instance.start();
    } else {
      await PtyByteRecorder.instance.stop();
    }
    await _refresh();
  }

  Future<void> _share(File file) async {
    await Share.shareXFiles([XFile(file.path)], text: 'PTY bytes log');
  }

  Future<void> _deleteAll() async {
    await PtyByteRecorder.instance.deleteAllLogs();
    await _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('ログファイルを全削除しました')),
    );
  }

  String _prettySize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final enabled = PtyByteRecorder.instance.isEnabled;

    return Scaffold(
      appBar: AppBar(
        title: const Text('PTY バイト記録'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '更新',
            onPressed: _refresh,
          ),
          if (_files.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'ログ全削除',
              onPressed: _deleteAll,
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('記録を開始'),
                  subtitle: Text(
                    enabled
                        ? '記録中。描画崩れを再現したら OFF にして下のログを共有'
                        : 'ON にすると新規ファイルが作成され PTY 受信バイトが書き込まれます',
                  ),
                  value: enabled,
                  onChanged: (v) async {
                    await _toggle(v);
                    setState(() {});
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  '※ 最大 4 MB に達すると自動停止します。問題再現後は早めに OFF にしてください。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const Divider(height: 0),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '保存済みログ',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _files.isEmpty
                    ? const Center(child: Text('ログファイルはまだありません'))
                    : ListView.separated(
                        itemCount: _files.length,
                        separatorBuilder: (_, __) => const Divider(height: 0),
                        itemBuilder: (context, index) {
                          final f = _files[index];
                          final size = f.existsSync() ? f.lengthSync() : 0;
                          final name = f.path.split('/').last;
                          return ListTile(
                            leading: const Icon(Icons.description_outlined),
                            title: Text(
                              name,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 13,
                              ),
                            ),
                            subtitle: Text(_prettySize(size)),
                            trailing: IconButton(
                              icon: const Icon(Icons.share_outlined),
                              tooltip: '共有',
                              onPressed: () => _share(f),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
