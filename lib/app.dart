import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/navigation/navigator_key.dart';
import 'core/theme/terminal_theme.dart';
import 'core/theme/theme_provider.dart';
import 'features/connections/connection_list_screen.dart';
import 'features/connections/connection_edit_screen.dart';
import 'features/terminal/terminal_screen.dart';
import 'features/settings/settings_screen.dart';

class TerminalSshApp extends ConsumerWidget {
  const TerminalSshApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);

    ThemeData? theme;
    ThemeData? darkTheme;
    ThemeMode materialThemeMode;

    switch (themeMode) {
      case AppThemeMode.dark:
        theme = AppTheme.light;
        darkTheme = AppTheme.dark;
        materialThemeMode = ThemeMode.dark;
      case AppThemeMode.light:
        theme = AppTheme.light;
        darkTheme = AppTheme.dark;
        materialThemeMode = ThemeMode.light;
      case AppThemeMode.highContrast:
        theme = AppTheme.highContrast;
        darkTheme = AppTheme.highContrast;
        materialThemeMode = ThemeMode.dark;
    }

    return MaterialApp(
      navigatorKey: globalNavigatorKey,
      title: 'SSH Terminal',
      theme: theme,
      darkTheme: darkTheme,
      themeMode: materialThemeMode,
      initialRoute: '/',
      onGenerateRoute: _onGenerateRoute,
    );
  }

  Route<dynamic>? _onGenerateRoute(RouteSettings settings) {
    final uri = Uri.parse(settings.name ?? '/');
    final pathSegments = uri.pathSegments;

    if (settings.name == '/') {
      return MaterialPageRoute(
        builder: (_) => const ConnectionListScreen(),
      );
    }

    if (pathSegments.isNotEmpty && pathSegments[0] == 'terminal') {
      return MaterialPageRoute(
        builder: (_) => const TerminalScreen(),
      );
    }

    if (pathSegments.isNotEmpty && pathSegments[0] == 'connection') {
      if (pathSegments.length >= 2 && pathSegments[1] == 'edit') {
        final id = pathSegments.length > 2
            ? int.tryParse(pathSegments[2])
            : null;
        return MaterialPageRoute(
          builder: (_) => ConnectionEditScreen(connectionId: id),
        );
      }
    }

    if (settings.name == '/settings') {
      return MaterialPageRoute(
        builder: (_) => const SettingsScreen(),
      );
    }

    return MaterialPageRoute(
      builder: (_) => const ConnectionListScreen(),
    );
  }
}
