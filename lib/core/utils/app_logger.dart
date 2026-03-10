import 'dart:collection';

import 'package:flutter/foundation.dart';

/// アプリ内診断ログ。リングバッファに最新のログを保持する。
/// 設定画面から閲覧・コピー可能。
class AppLogger {
  AppLogger._();
  static final AppLogger instance = AppLogger._();

  static const int maxEntries = 500;
  final _entries = Queue<LogEntry>();

  List<LogEntry> get entries => List.unmodifiable(_entries);

  /// ログを追加する。[debugPrint] にも出力する。
  void log(String message) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      message: message,
    );
    _entries.addLast(entry);
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
    debugPrint(message);
  }

  /// 全ログをテキストとして取得する。
  String toText() {
    final buffer = StringBuffer();
    for (final entry in _entries) {
      buffer.writeln(
        '${entry.timestamp.toIso8601String()} ${entry.message}',
      );
    }
    return buffer.toString();
  }

  void clear() => _entries.clear();
}

class LogEntry {
  const LogEntry({required this.timestamp, required this.message});
  final DateTime timestamp;
  final String message;
}
