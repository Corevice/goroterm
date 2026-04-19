import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

/// Wraps a widget in a MaterialApp configured with localization delegates.
/// Use this in widget tests instead of constructing MaterialApp manually so
/// any widget that calls `AppLocalizations.of(context)` works out of the box.
MaterialApp localizedTestApp({required Widget home}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    home: home,
  );
}
