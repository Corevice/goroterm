import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

/// Dialog shown on first SSH connection to verify the host key fingerprint.
class UnknownHostKeyDialog extends StatelessWidget {
  const UnknownHostKeyDialog({
    super.key,
    required this.host,
    required this.fingerprint,
  });

  final String host;
  final String fingerprint;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Semantics(
        label: l.unknownHostKeyFor(host),
        child: Text(l.verifyHostKey),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.firstTimeConnecting(host),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Text(
            l.hostKeyFingerprint,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: fingerprint));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l.fingerprintCopied)),
              );
            },
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey[850],
                borderRadius: BorderRadius.circular(4),
              ),
              child: SelectableText(
                fingerprint,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            l.verifyFingerprintWarning,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l.reject),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l.trustAndConnect),
        ),
      ],
    );
  }
}

/// Dialog shown when the SSH host key has changed (possible MITM attack).
/// Uses high-visibility red design to convey danger.
class HostKeyMismatchDialog extends StatelessWidget {
  const HostKeyMismatchDialog({
    super.key,
    required this.host,
    required this.storedFingerprint,
    required this.actualFingerprint,
  });

  final String host;
  final String storedFingerprint;
  final String actualFingerprint;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      backgroundColor: Colors.red[900],
      title: Semantics(
        label: l.hostKeyMismatchWarning(host),
        child: Row(
          children: [
            const Icon(Icons.warning_amber, color: Colors.yellow, size: 28),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l.hostKeyChangedTitle,
                style: TextStyle(
                  color: Colors.yellow[200],
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.hostKeyChangedFor(host),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l.mitmAttackWarning,
            style: TextStyle(color: Colors.red[200], fontSize: 12),
          ),
          const SizedBox(height: 12),
          _FingerprintRow(
            label: l.expectedStored,
            fingerprint: storedFingerprint,
          ),
          const SizedBox(height: 4),
          _FingerprintRow(
            label: l.actualServer,
            fingerprint: actualFingerprint,
            highlight: true,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          style: TextButton.styleFrom(foregroundColor: Colors.white),
          child: Text(l.abortConnection),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: Colors.yellow),
          child: Text(l.trustNewKeyDangerous),
        ),
      ],
    );
  }
}

class _FingerprintRow extends StatelessWidget {
  const _FingerprintRow({
    required this.label,
    required this.fingerprint,
    this.highlight = false,
  });

  final String label;
  final String fingerprint;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.grey[300],
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: highlight ? Colors.red[800] : Colors.black26,
            borderRadius: BorderRadius.circular(4),
          ),
          child: SelectableText(
            fingerprint,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: highlight ? Colors.yellow[200] : Colors.white70,
            ),
          ),
        ),
      ],
    );
  }
}
