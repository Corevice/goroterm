import 'package:flutter/foundation.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  Future<void> showCommandFinished({required String host}) async {
    debugPrint('[Notification] Command finished on $host');
  }
}
