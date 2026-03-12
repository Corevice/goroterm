import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ssh/ssh_channel_manager.dart';
import '../terminal/terminal_connection_provider.dart';

/// Claude Code の利用状況を表示するダイアログ。
/// リモートサーバーの ~/.claude/.credentials.json から OAuth トークンを読み取り、
/// Anthropic の内部 API で利用状況を取得する。
class ClaudeUsageDialog extends ConsumerStatefulWidget {
  const ClaudeUsageDialog({
    super.key,
    required this.sessionId,
  });

  final String sessionId;

  static Future<void> show(BuildContext context, String sessionId) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => ClaudeUsageDialog(sessionId: sessionId),
    );
  }

  @override
  ConsumerState<ClaudeUsageDialog> createState() => _ClaudeUsageDialogState();
}

class _ClaudeUsageDialogState extends ConsumerState<ClaudeUsageDialog> {
  bool _loading = true;
  String? _error;
  _UsageData? _usage;

  @override
  void initState() {
    super.initState();
    _fetchUsage();
  }

  Future<void> _fetchUsage() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final channelManager = ref
          .read(terminalConnectionProvider(widget.sessionId))
          .channelManager;
      if (channelManager == null) {
        setState(() {
          _loading = false;
          _error = 'SSH not connected';
        });
        return;
      }

      final usage = await _queryUsageApi(channelManager);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _usage = usage;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<_UsageData> _queryUsageApi(SshChannelManager channelManager) async {
    // リモートサーバーでシェルコマンドを実行して利用状況を取得
    // 1. OAuth トークンを読み取り
    // 2. Anthropic API にリクエスト
    // 3. JSON で結果を返す
    const command = r'''
python3 -c "
import json, urllib.request, os, sys

cred_path = os.path.expanduser('~/.claude/.credentials.json')
if not os.path.exists(cred_path):
    print(json.dumps({'error': 'Claude Code not found (~/.claude/.credentials.json missing)'}))
    sys.exit(0)

with open(cred_path) as f:
    cred = json.load(f)

oauth = cred.get('claudeAiOauth', cred)
token = oauth.get('accessToken')
if not token:
    print(json.dumps({'error': 'No access token found'}))
    sys.exit(0)

sub_type = oauth.get('subscriptionType', 'unknown')
rate_tier = oauth.get('rateLimitTier', 'unknown')

req = urllib.request.Request(
    'https://api.anthropic.com/api/oauth/usage',
    headers={
        'Authorization': f'Bearer {token}',
        'anthropic-beta': 'oauth-2025-04-20',
        'Content-Type': 'application/json',
    },
)
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        usage = json.loads(resp.read())
except urllib.error.HTTPError as e:
    body = e.read().decode('utf-8', errors='replace')
    print(json.dumps({'error': f'API error {e.code}: {body[:200]}'}))
    sys.exit(0)
except Exception as e:
    print(json.dumps({'error': str(e)}))
    sys.exit(0)

result = {
    'subscription': sub_type,
    'rateLimitTier': rate_tier,
    'usage': usage,
}
print(json.dumps(result))
" 2>&1
''';

    final output = await channelManager.runCommand(command);
    final jsonStr = utf8.decode(output).trim();

    if (jsonStr.isEmpty) {
      throw Exception('No output from remote server');
    }

    // 複数行の場合、最後の行が JSON
    final lines = jsonStr.split('\n');
    final lastLine = lines.last.trim();

    final Map<String, dynamic> result;
    try {
      result = json.decode(lastLine) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('Invalid response: $lastLine');
    }

    if (result.containsKey('error')) {
      throw Exception(result['error'] as String);
    }

    return _UsageData.fromJson(result);
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.85;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.analytics_outlined,
                    color: Colors.white70, size: 24),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Claude Code Usage',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (!_loading)
                  IconButton(
                    icon: const Icon(Icons.refresh, color: Colors.white70),
                    onPressed: _fetchUsage,
                    tooltip: 'Refresh',
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_error != null)
              _buildError()
            else if (_usage != null)
              _buildUsageContent(),
          ],
          ),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red[900]?.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUsageContent() {
    final usage = _usage!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // サブスクリプション情報
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.blue[900]?.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            'Plan: ${_formatSubscription(usage.subscription)}',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
        const SizedBox(height: 16),

        // 5時間リミット
        if (usage.fiveHour != null)
          _buildUsageBar(
            label: '5-Hour Limit',
            utilization: usage.fiveHour!.utilization,
            resetsAt: usage.fiveHour!.resetsAt,
            color: _getBarColor(usage.fiveHour!.utilization),
          ),
        const SizedBox(height: 12),

        // 7日間リミット（総合）
        if (usage.sevenDay != null)
          _buildUsageBar(
            label: '7-Day Limit',
            utilization: usage.sevenDay!.utilization,
            resetsAt: usage.sevenDay!.resetsAt,
            color: _getBarColor(usage.sevenDay!.utilization),
          ),
        const SizedBox(height: 12),

        // 7日間 Opus
        if (usage.sevenDayOpus != null &&
            usage.sevenDayOpus!.utilization > 0) ...[
          _buildUsageBar(
            label: '7-Day Opus',
            utilization: usage.sevenDayOpus!.utilization,
            resetsAt: usage.sevenDayOpus!.resetsAt,
            color: _getBarColor(usage.sevenDayOpus!.utilization),
          ),
          const SizedBox(height: 12),
        ],

        // 7日間 Sonnet
        if (usage.sevenDaySonnet != null &&
            usage.sevenDaySonnet!.utilization > 0)
          _buildUsageBar(
            label: '7-Day Sonnet',
            utilization: usage.sevenDaySonnet!.utilization,
            resetsAt: usage.sevenDaySonnet!.resetsAt,
            color: _getBarColor(usage.sevenDaySonnet!.utilization),
          ),

        // Extra usage
        if (usage.extraUsageEnabled == true) ...[
          const SizedBox(height: 12),
          _buildUsageBar(
            label: 'Extra Usage',
            utilization: usage.extraUsageUtilization ?? 0,
            resetsAt: null,
            color: Colors.purple,
            subtitle: usage.extraUsageCredits != null
                ? '\$${(usage.extraUsageCredits! / 100).toStringAsFixed(2)} used'
                : null,
          ),
        ],
      ],
    );
  }

  Widget _buildUsageBar({
    required String label,
    required double utilization,
    required DateTime? resetsAt,
    required Color color,
    String? subtitle,
  }) {
    final remaining = (100 - utilization).clamp(0, 100);
    final resetText = resetsAt != null ? _formatResetTime(resetsAt) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style:
                    const TextStyle(color: Colors.white, fontSize: 14)),
            Text(
              '${remaining.toStringAsFixed(1)}% remaining',
              style: TextStyle(
                color: remaining < 20 ? Colors.redAccent : Colors.white70,
                fontSize: 13,
                fontWeight:
                    remaining < 20 ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: utilization / 100,
            backgroundColor: Colors.white12,
            color: color,
            minHeight: 8,
          ),
        ),
        if (resetText != null || subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              subtitle ?? 'Resets $resetText',
              style:
                  const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
      ],
    );
  }

  Color _getBarColor(double utilization) {
    if (utilization >= 90) return Colors.red;
    if (utilization >= 70) return Colors.orange;
    if (utilization >= 50) return Colors.yellow[700]!;
    return Colors.green;
  }

  String _formatSubscription(String sub) {
    switch (sub) {
      case 'max':
        return 'Claude Max';
      case 'max_5x':
        return 'Claude Max 5x';
      case 'max_20x':
        return 'Claude Max 20x';
      case 'pro':
        return 'Claude Pro';
      default:
        return sub;
    }
  }

  String _formatResetTime(DateTime resetTime) {
    final now = DateTime.now().toUtc();
    final diff = resetTime.difference(now);

    if (diff.isNegative) return 'soon';
    if (diff.inMinutes < 60) return 'in ${diff.inMinutes}m';
    if (diff.inHours < 24) {
      final h = diff.inHours;
      final m = diff.inMinutes % 60;
      return 'in ${h}h${m > 0 ? ' ${m}m' : ''}';
    }
    final d = diff.inDays;
    final h = diff.inHours % 24;
    return 'in ${d}d ${h}h';
  }
}

class _UsageData {
  _UsageData({
    required this.subscription,
    this.fiveHour,
    this.sevenDay,
    this.sevenDayOpus,
    this.sevenDaySonnet,
    this.extraUsageEnabled,
    this.extraUsageUtilization,
    this.extraUsageCredits,
  });

  final String subscription;
  final _LimitInfo? fiveHour;
  final _LimitInfo? sevenDay;
  final _LimitInfo? sevenDayOpus;
  final _LimitInfo? sevenDaySonnet;
  final bool? extraUsageEnabled;
  final double? extraUsageUtilization;
  final double? extraUsageCredits;

  factory _UsageData.fromJson(Map<String, dynamic> json) {
    final usage = json['usage'] as Map<String, dynamic>? ?? {};
    return _UsageData(
      subscription: json['subscription'] as String? ?? 'unknown',
      fiveHour: _LimitInfo.fromJson(usage['five_hour']),
      sevenDay: _LimitInfo.fromJson(usage['seven_day']),
      sevenDayOpus: _LimitInfo.fromJson(usage['seven_day_opus']),
      sevenDaySonnet: _LimitInfo.fromJson(usage['seven_day_sonnet']),
      extraUsageEnabled:
          (usage['extra_usage'] as Map<String, dynamic>?)?['is_enabled']
              as bool?,
      extraUsageUtilization:
          ((usage['extra_usage'] as Map<String, dynamic>?)?['utilization']
              as num?)
              ?.toDouble(),
      extraUsageCredits:
          ((usage['extra_usage'] as Map<String, dynamic>?)?['used_credits']
              as num?)
              ?.toDouble(),
    );
  }
}

class _LimitInfo {
  _LimitInfo({required this.utilization, this.resetsAt});

  final double utilization;
  final DateTime? resetsAt;

  static _LimitInfo? fromJson(dynamic json) {
    if (json == null || json is! Map<String, dynamic>) return null;
    final util = (json['utilization'] as num?)?.toDouble() ?? 0;
    DateTime? resets;
    final resetsStr = json['resets_at'] as String?;
    if (resetsStr != null) {
      resets = DateTime.tryParse(resetsStr);
    }
    return _LimitInfo(utilization: util, resetsAt: resets);
  }
}
