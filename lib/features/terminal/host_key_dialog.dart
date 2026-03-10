import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    return AlertDialog(
      title: Semantics(
        label: 'Unknown host key for $host',
        child: const Text('Verify Host Key'),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'You are connecting to "$host" for the first time.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          const Text(
            'Host key fingerprint (SHA-256):',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: fingerprint));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Fingerprint copied')),
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
          const Text(
            'Verify this fingerprint with the server administrator before '
            'connecting. Accepting an incorrect fingerprint could expose '
            'you to a man-in-the-middle attack.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Reject'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Trust & Connect'),
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
    return AlertDialog(
      backgroundColor: Colors.red[900],
      title: Semantics(
        label: 'Security warning: host key mismatch for $host',
        child: Row(
          children: [
            const Icon(Icons.warning_amber, color: Colors.yellow, size: 28),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'WARNING: Host Key Changed!',
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
            'The host key for "$host" has changed!',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'THIS MAY INDICATE A MAN-IN-THE-MIDDLE ATTACK. '
            'Do NOT connect unless you know the host key has legitimately '
            'changed (e.g., server was reinstalled).',
            style: TextStyle(color: Colors.red[200], fontSize: 12),
          ),
          const SizedBox(height: 12),
          _FingerprintRow(
            label: 'Expected (stored):',
            fingerprint: storedFingerprint,
          ),
          const SizedBox(height: 4),
          _FingerprintRow(
            label: 'Actual (server):',
            fingerprint: actualFingerprint,
            highlight: true,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          style: TextButton.styleFrom(foregroundColor: Colors.white),
          child: const Text('Abort Connection'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: Colors.yellow),
          child: const Text('Trust New Key (DANGEROUS)'),
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
