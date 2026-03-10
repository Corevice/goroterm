import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// バックグラウンド Isolate でファイル書き込みを行うユーティリティ。
/// メインアイソレートから SendPort 経由で chunk を送信し、
/// バックグラウンド側で IOSink.add() + flush + close を行う。
class FileWriterIsolate {
  FileWriterIsolate._(this._sendPort, this._isolate, this._exitPort);

  final SendPort _sendPort;
  final Isolate _isolate;
  final ReceivePort _exitPort;
  bool _closed = false;

  /// バックグラウンド Isolate を起動し、書き込み先ファイルを開く。
  static Future<FileWriterIsolate> open(String filePath) async {
    final receivePort = ReceivePort();
    final exitPort = ReceivePort();
    final errorPort = ReceivePort();

    final isolate = await Isolate.spawn(
      _isolateEntry,
      _InitMessage(filePath, receivePort.sendPort),
      onExit: exitPort.sendPort,
      onError: errorPort.sendPort,
    );

    // エラーポートのリスナー（デバッグ用、致命的エラーのログ出力）
    errorPort.listen((_) {});

    // Isolate 側から SendPort を受け取る
    final sendPort = await receivePort.first as SendPort;
    receivePort.close();
    errorPort.close();

    return FileWriterIsolate._(sendPort, isolate, exitPort);
  }

  /// chunk をバックグラウンド Isolate に送信して書き込む。
  /// メインアイソレートでは chunk のコピーオーバーヘッドのみ。
  void addChunk(Uint8List chunk) {
    if (_closed) return;
    _sendPort.send(chunk);
  }

  /// 書き込みを完了し、flush → close → Isolate 終了を待つ。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _sendPort.send(null); // null = 終了シグナル
    await _exitPort.first; // Isolate 終了を待つ
    _exitPort.close();
  }

  /// エラー時に Isolate を強制終了する。
  void kill() {
    if (_closed) return;
    _closed = true;
    _isolate.kill(priority: Isolate.immediate);
    _exitPort.close();
  }

  /// Isolate エントリポイント。
  static Future<void> _isolateEntry(_InitMessage msg) async {
    final port = ReceivePort();
    msg.sendPort.send(port.sendPort);

    final sink = File(msg.filePath).openWrite();

    await for (final data in port) {
      if (data == null) break; // 終了シグナル
      sink.add(data as Uint8List);
    }

    await sink.flush();
    await sink.close();
    port.close();
  }
}

class _InitMessage {
  const _InitMessage(this.filePath, this.sendPort);
  final String filePath;
  final SendPort sendPort;
}
