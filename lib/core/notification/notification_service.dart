import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Android 通知チャンネル ID。一度作ったあとは設定変更不可なので固定値を保持する。
const _kCommandFinishedChannelId = 'command_finished';
const _kCommandFinishedChannelName = 'Command Finished';
const _kCommandFinishedChannelDescription =
    'Notifies when a long-running command completes';

/// 通知内インライン返信アクション/カテゴリの ID（両プラットフォーム共通）。
const _kReplyActionId = 'reply';
const _kReplyCategoryId = 'claude_reply';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Called when the user taps a notification while the app is running. The
  /// payload is the [sessionId] passed to [showCommandFinished]. Set this
  /// from the widget layer so we can route through Riverpod / Navigator.
  void Function(String sessionId)? onSelectSession;

  /// 通知のインライン返信で送信されたときに呼ばれる。[text] はユーザーが
  /// 入力した次の指示。ウィジェット層から設定し、対象セッションの tmux へ
  /// 送信する。
  void Function(String sessionId, String text)? onReplySession;

  Future<void> init() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    // 起動時に通知許可ダイアログを出す (iOS / macOS)。
    // Android 13+ の POST_NOTIFICATIONS は init 後に Android 専用 API で要求する。
    final darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: false,
      requestSoundPermission: true,
      // 通知からのインライン返信（Claude への次の指示）用カテゴリ。
      notificationCategories: [
        DarwinNotificationCategory(
          _kReplyCategoryId,
          actions: [
            DarwinNotificationAction.text(
              _kReplyActionId,
              'Reply',
              buttonTitle: 'Send',
              placeholder: 'Message to Claude…',
            ),
          ],
          options: {DarwinNotificationCategoryOption.allowInCarPlay},
        ),
      ],
    );
    const linuxSettings =
        LinuxInitializationSettings(defaultActionName: 'Open');
    const windowsSettings = WindowsInitializationSettings(
      appName: 'goroterm',
      appUserModelId: 'Corevice.goroterm',
      // GUID は通知 activation コールバックの登録に使われる。生成後は変えない。
      guid: '2c2cca97-fc04-4cf9-9c39-5fd99c10d4a8',
    );
    final settings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
      linux: linuxSettings,
      windows: windowsSettings,
    );

    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _handleResponse,
    );

    // Android はチャンネル設定が一度作成すると変更不可。暗黙作成に頼らず、
    // 起動時に明示作成して importance / sound / vibration をピン留めする。
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
      _kCommandFinishedChannelId,
      _kCommandFinishedChannelName,
      description: _kCommandFinishedChannelDescription,
      importance: Importance.high,
      enableVibration: true,
      playSound: true,
    ));

    // Android 13+ では通常通知も POST_NOTIFICATIONS が必要。
    // 拒否時は false が返るが UI 誘導は今回スコープ外。
    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }

    _initialized = true;
  }

  void _handleResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    // インライン返信: 入力テキストを対象セッションへ送信する。
    if (response.actionId == _kReplyActionId) {
      final text = response.input?.trim() ?? '';
      if (text.isNotEmpty) onReplySession?.call(payload, text);
      return;
    }
    onSelectSession?.call(payload);
  }

  /// セッションIDからAndroid通知IDを生成する（安定したハッシュ値）。
  int _notificationId(String sessionId) => sessionId.hashCode & 0x7FFFFFFF;

  /// 完了通知を表示する。表示テキストは呼び出し側でロケールに合わせて
  /// 組み立て、[title]（セッション名を先頭に）と [body]（何が完了したか）を渡す。
  /// 完了通知を表示する。
  /// [title] はセッション名（一覧で識別）、[summary] は「Claude Code finished ·
  /// host」等の一行要約、[preview] は Claude の最後の出力プレビュー（展開表示）。
  Future<void> showCommandFinished({
    required String sessionId,
    required String title,
    required String summary,
    String? preview,
    String? replyLabel,
    String? replyHint,
  }) async {
    if (!_initialized) return;

    final hasPreview = preview != null && preview.trim().isNotEmpty;
    // 折りたたみ時に見える本文。プレビューがあればそれ、無ければ要約。
    final body = hasPreview ? preview.trim() : summary;

    // インライン返信アクション（次の指示を Claude に送る）。
    // replyLabel が指定されたときだけ付与する。
    final androidActions = replyLabel == null
        ? null
        : <AndroidNotificationAction>[
            AndroidNotificationAction(
              _kReplyActionId,
              replyLabel,
              inputs: <AndroidNotificationActionInput>[
                AndroidNotificationActionInput(label: replyHint ?? replyLabel),
              ],
              allowGeneratedReplies: false,
              // 返信後は通知を消す（送信済みとして片付ける）。
              cancelNotification: true,
            ),
          ];

    // groupKey に sessionId を入れて iOS の threadIdentifier と同様に
    // セッション単位で通知センターでまとめる。
    final androidDetails = AndroidNotificationDetails(
      _kCommandFinishedChannelId,
      _kCommandFinishedChannelName,
      channelDescription: _kCommandFinishedChannelDescription,
      importance: Importance.high,
      priority: Priority.high,
      groupKey: sessionId,
      actions: androidActions,
      // 展開すると Claude の最後の出力プレビューを複数行で表示する。
      styleInformation: BigTextStyleInformation(
        body,
        contentTitle: title,
        summaryText: summary,
      ),
    );
    final iosDetails = DarwinNotificationDetails(
      presentBanner: true,
      presentList: true,
      presentSound: true,
      interruptionLevel: InterruptionLevel.active,
      threadIdentifier: sessionId,
      categoryIdentifier: replyLabel == null ? null : _kReplyCategoryId,
      // iOS は subtitle に要約、本文にプレビューを出す。
      subtitle: hasPreview ? summary : null,
    );
    // Linux はプレビュー本文をそのまま出す。Windows も既定表示で本文を出す。
    final linuxDetails = LinuxNotificationDetails(
      defaultActionName: 'Open',
    );
    const windowsDetails = WindowsNotificationDetails();
    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      macOS: iosDetails,
      linux: linuxDetails,
      windows: windowsDetails,
    );

    await _plugin.show(
      _notificationId(sessionId),
      title,
      body,
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
