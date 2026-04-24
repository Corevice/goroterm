import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../utils/app_logger.dart';

/// PTY から流入する生バイトをファイルへ記録する診断用シングルトン。
///
/// Allow Edit プロンプト等、TUI アプリの描画崩れ再現時に有効化し、
/// 後でバイト列を解析することで根本原因を特定する。
///
/// 書式（行ごと）:
///   `+<elapsed_ms> <tag> <hex> | <ascii>`
/// - `elapsed_ms` は start() 後の相対ミリ秒。
/// - `hex` は半角スペース区切りの 16 進。
/// - `ascii` は印字可能 ASCII (0x20-0x7E)、それ以外は `.`。
///
/// ランアウェイ防止のため max 4 MB で自動停止する。
class PtyByteRecorder {
  PtyByteRecorder._();
  static final PtyByteRecorder instance = PtyByteRecorder._();

  static const int _maxBytes = 4 * 1024 * 1024;

  bool _enabled = false;
  IOSink? _sink;
  File? _file;
  Stopwatch? _stopwatch;
  int _writtenBytes = 0;

  bool get isEnabled => _enabled;
  File? get currentFile => _file;

  /// 記録開始。既に開いていれば一度閉じてから開き直す。
  Future<File> start() async {
    await stop();

    final dir = await getApplicationDocumentsDirectory();
    final debugDir = Directory('${dir.path}/debug');
    if (!debugDir.existsSync()) {
      debugDir.createSync(recursive: true);
    }

    final now = DateTime.now();
    final ts = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    final file = File('${debugDir.path}/pty-$ts.log');
    _file = file;
    _sink = file.openWrite();
    _stopwatch = Stopwatch()..start();
    _writtenBytes = 0;
    _enabled = true;

    _sink!.writeln('# PTY byte recorder — started ${now.toIso8601String()}');
    _sink!.writeln('# Format: +<ms> <tag> <hex> | <ascii>');
    AppLogger.instance.log('[pty-rec] started: ${file.path}');
    return file;
  }

  /// 記録停止。既に停止していれば no-op。
  Future<void> stop() async {
    if (!_enabled && _sink == null) return;
    _enabled = false;
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    _stopwatch?.stop();
    _stopwatch = null;
    AppLogger.instance.log('[pty-rec] stopped');
  }

  /// 1 チャンクを記録。enabled でない場合は no-op。
  void record(String tag, Uint8List data) {
    if (!_enabled) return;
    final sink = _sink;
    if (sink == null) return;
    if (_writtenBytes >= _maxBytes) {
      unawaited(_autoStop());
      return;
    }

    final elapsed = _stopwatch?.elapsedMilliseconds ?? 0;
    final hex = StringBuffer();
    final ascii = StringBuffer();
    for (var i = 0; i < data.length; i++) {
      final b = data[i];
      if (i > 0) hex.write(' ');
      hex.write(b.toRadixString(16).padLeft(2, '0'));
      ascii.writeCharCode((b >= 0x20 && b <= 0x7E) ? b : 0x2E);
    }
    final line = '+$elapsed $tag $hex | $ascii\n';
    sink.write(line);
    _writtenBytes += line.length;
  }

  Future<void> _autoStop() async {
    final sink = _sink;
    if (sink == null) return;
    _enabled = false;
    sink.writeln('# auto-stopped at $_writtenBytes bytes (limit reached)');
    try {
      await sink.flush();
      await sink.close();
    } catch (_) {}
    _sink = null;
    AppLogger.instance.log('[pty-rec] auto-stopped at size limit');
  }

  /// 記録ディレクトリ内のログファイルを新しい順に列挙。
  Future<List<File>> listLogs() async {
    final dir = await getApplicationDocumentsDirectory();
    final debugDir = Directory('${dir.path}/debug');
    if (!debugDir.existsSync()) return const [];
    final files = debugDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.log'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  Future<void> deleteAllLogs() async {
    await stop();
    final files = await listLogs();
    for (final f in files) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
    AppLogger.instance.log('[pty-rec] deleted ${files.length} log file(s)');
  }
}
