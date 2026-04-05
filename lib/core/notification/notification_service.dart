import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _plugin.initialize(settings);
    _initialized = true;
  }

  /// セッションIDからAndroid通知IDを生成する（安定したハッシュ値）。
  int _notificationId(String sessionId) => sessionId.hashCode & 0x7FFFFFFF;

  Future<void> showCommandFinished({
    required String host,
    required String sessionId,
    String? tabLabel,
    String? body,
  }) async {
    if (!_initialized) return;

    const androidDetails = AndroidNotificationDetails(
      'command_finished',
      'Command Finished',
      channelDescription: 'Notifies when a long-running command completes',
      importance: Importance.high,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    final title = tabLabel != null
        ? 'Command finished on $host ($tabLabel)'
        : 'Command finished on $host';

    await _plugin.show(
      _notificationId(sessionId),
      title,
      body ?? 'Terminal output has stopped.',
      details,
    );
  }

  /// 指定セッションの通知をキャンセルする。
  Future<void> cancelForSession(String sessionId) async {
    if (!_initialized) return;
    await _plugin.cancel(_notificationId(sessionId));
  }
}
