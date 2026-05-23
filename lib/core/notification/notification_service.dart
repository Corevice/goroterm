import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Called when the user taps a notification while the app is running. The
  /// payload is the [sessionId] passed to [showCommandFinished]. Set this
  /// from the widget layer so we can route through Riverpod / Navigator.
  void Function(String sessionId)? onSelectSession;

  Future<void> init() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    // 起動時に通知許可ダイアログを出す (iOS / macOS)。
    // Android 13+ の POST_NOTIFICATIONS は flutter_foreground_task 側で
    // 接続時に要求しているため、ここでは未要求のままで OK。
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: false,
      requestSoundPermission: true,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _handleResponse,
    );
    _initialized = true;
  }

  void _handleResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    onSelectSession?.call(payload);
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
    // threadIdentifier に sessionId を入れて iOS 通知センターでセッション単位に
    // 折り畳ませる。前面時もバナー表示するために present* を明示。
    final iosDetails = DarwinNotificationDetails(
      presentBanner: true,
      presentList: true,
      presentSound: true,
      interruptionLevel: InterruptionLevel.active,
      threadIdentifier: sessionId,
    );
    final details = NotificationDetails(
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
      payload: sessionId,
    );
  }

  /// 指定セッションの通知をキャンセルする。
  Future<void> cancelForSession(String sessionId) async {
    if (!_initialized) return;
    await _plugin.cancel(_notificationId(sessionId));
  }
}
