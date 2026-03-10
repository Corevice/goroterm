import 'package:flutter/material.dart';

/// パスワード入力ダイアログを表示し、入力値を返す。
/// キャンセル時は null を返す。
Future<String?> showPasswordDialog(
  BuildContext context, {
  required String host,
}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text('Password for $host'),
      content: TextField(
        controller: controller,
        obscureText: true,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Password',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (_) => Navigator.of(context).pop(controller.text),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('Connect'),
        ),
      ],
    ),
  );
}

/// パスフレーズ入力ダイアログを表示し、入力値を返す。
/// キャンセル時は null を返す。
Future<String?> showPassphraseDialog(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('Key Passphrase'),
      content: TextField(
        controller: controller,
        obscureText: true,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Passphrase',
          hintText: 'Enter passphrase for encrypted key',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (_) => Navigator.of(context).pop(controller.text),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('Connect'),
        ),
      ],
    ),
  );
}
