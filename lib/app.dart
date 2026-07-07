import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/navigation/navigator_key.dart';
import 'core/notification/notification_service.dart';
import 'core/platform/detached_session_args.dart';
import 'core/theme/terminal_theme.dart';
import 'core/theme/theme_provider.dart';
import 'features/connections/connection_list_screen.dart';
import 'features/connections/connection_edit_screen.dart';
import 'features/terminal/session_manager.dart';
import 'features/terminal/terminal_connection_provider.dart';
import 'features/terminal/terminal_screen.dart';
import 'features/settings/settings_screen.dart';

class TerminalSshApp extends ConsumerStatefulWidget {
  const TerminalSshApp({super.key, this.detachedSession});

  /// macOS のタブ分離ウィンドウとして起動された場合の対象セッション。
  /// 通常起動では null。
  final DetachedSessionArgs? detachedSession;

  @override
  ConsumerState<TerminalSshApp> createState() => _TerminalSshAppState();
}

class _TerminalSshAppState extends ConsumerState<TerminalSshApp> {
  @override
  void initState() {
    super.initState();
    // 通知タップ → 該当セッションをアクティブにして /terminal までナビゲート。
    NotificationService.instance.onSelectSession = (sessionId) {
      if (!mounted) return;
      // 開いたセッションの通知だけを消す（他セッションの通知は残す）。
      NotificationService.instance.cancelForSession(sessionId);
      ref
          .read(terminalConnectionProvider(sessionId).notifier)
          .clearNotificationFlag();
      ref.read(sessionManagerProvider.notifier).setActiveSession(sessionId);
      final navigator = globalNavigatorKey.currentState;
      if (navigator == null) return;
      // ConnectionList ('/') は残し、それ以外を剥がして /terminal を載せる。
      // 既に /terminal にいる場合でも一度差し替えてアクティブタブを反映させる。
      navigator.pushNamedAndRemoveUntil(
        '/terminal',
        (route) => route.isFirst,
      );
    };

    // 通知のインライン返信 → 対象セッションの tmux に次の指示を send-keys で送る。
    // アプリ/接続が生きている間に有効（Android は foreground service で維持）。
    NotificationService.instance.onReplySession = (sessionId, text) {
      if (!mounted) return;
      ref
          .read(terminalConnectionProvider(sessionId).notifier)
          .sendTmuxInstruction(text);
      // RemoteInput のスピナーを片付けるため通知を消す。
      NotificationService.instance.cancelForSession(sessionId);
    };

    // タブ分離ウィンドウ: 起動引数のセッションをタブとして開き、
    // 接続一覧を経由せず直接ターミナル画面へ遷移する。
    final detached = widget.detachedSession;
    if (detached != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(sessionManagerProvider.notifier).addTmuxSession(
              connectionId: detached.connectionId,
              tmuxSessionName: detached.tmuxSessionName,
            );
        globalNavigatorKey.currentState?.pushNamedAndRemoveUntil(
          '/terminal',
          (route) => route.isFirst,
        );
      });
    }
  }

  @override
  void dispose() {
    NotificationService.instance.onSelectSession = null;
    NotificationService.instance.onReplySession = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);

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
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
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
