import 'dart:io';

import 'package:flutter/material.dart';
import 'package:in_app_update/in_app_update.dart';

import '../navigation/navigator_key.dart';
import '../utils/app_logger.dart';

/// Wraps Google Play In-App Updates (Android only).
///
/// Strategy: check on app start / resume → if a flexible update is available
/// download it in the background, then prompt the user to restart via a
/// SnackBar.  Failures are logged and swallowed (updates are best-effort).
class InAppUpdateService {
  InAppUpdateService._();

  /// Guards against re-entrant checks (e.g. resume firing while download is
  /// still in progress).
  static bool _checkInFlight = false;

  /// True once a flexible download has completed and we're waiting for the
  /// user to tap "Restart" — prevents prompting twice.
  static bool _restartPending = false;

  static Future<void> checkAndPromptUpdate() async {
    if (!Platform.isAndroid) return;
    if (_checkInFlight || _restartPending) return;
    _checkInFlight = true;
    try {
      final info = await InAppUpdate.checkForUpdate();
      if (info.updateAvailability != UpdateAvailability.updateAvailable) {
        return;
      }
      if (info.flexibleUpdateAllowed) {
        final result = await InAppUpdate.startFlexibleUpdate();
        if (result == AppUpdateResult.success) {
          _restartPending = true;
          _showRestartSnackBar();
        }
      }
    } catch (e, st) {
      AppLogger.instance.log('[update] check failed: $e\n$st');
    } finally {
      _checkInFlight = false;
    }
  }

  static void _showRestartSnackBar() {
    final ctx = globalNavigatorKey.currentContext;
    if (ctx == null) return;
    final messenger = ScaffoldMessenger.maybeOf(ctx);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('アップデートの準備ができました'),
          duration: const Duration(days: 1), // 永続表示（ユーザー操作で消す）
          action: SnackBarAction(
            label: '再起動して適用',
            onPressed: () async {
              try {
                await InAppUpdate.completeFlexibleUpdate();
              } catch (e) {
                AppLogger.instance.log('[update] complete failed: $e');
                _restartPending = false;
              }
            },
          ),
        ),
      );
  }
}
