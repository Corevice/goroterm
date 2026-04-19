import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

/// パスワード入力ダイアログを表示し、入力値を返す。
/// キャンセル時は null を返す。
Future<String?> showPasswordDialog(
  BuildContext context, {
  required String host,
}) {
  final controller = TextEditingController();
  final l = AppLocalizations.of(context);
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(l.passwordForHost(host)),
      content: TextField(
        controller: controller,
        obscureText: true,
        autofocus: true,
        decoration: InputDecoration(
          labelText: l.passwordLabel,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => Navigator.of(context).pop(controller.text),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: Text(l.connect),
        ),
      ],
    ),
  );
}

/// パスフレーズ入力ダイアログを表示し、入力値を返す。
/// キャンセル時は null を返す。
Future<String?> showPassphraseDialog(BuildContext context) {
  final controller = TextEditingController();
  final l = AppLocalizations.of(context);
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(l.keyPassphrase),
      content: TextField(
        controller: controller,
        obscureText: true,
        autofocus: true,
        decoration: InputDecoration(
          labelText: l.passphraseLabel,
          hintText: l.enterPassphraseHint,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => Navigator.of(context).pop(controller.text),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: Text(l.connect),
        ),
      ],
    ),
  );
}
