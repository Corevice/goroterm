import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

// ignore: unused_import (ZLibDecoder is used in _isolateEntry)
import 'dart:convert' show utf8;
import '../utils/shell_utils.dart';

/// バックグラウンド Isolate でファイルダウンロードを完全に実行する。
/// SSH 接続の確立 → SFTP ダウンロード → ファイル書き込みを
/// すべて別 Isolate で行うため、メインアイソレートの UI を一切ブロックしない。
class DownloadIsolate {
  DownloadIsolate._(this._isolate, this._progressPort, this._resultPort);

  final Isolate? _isolate;
  final ReceivePort _progressPort;
  final ReceivePort _resultPort;

  /// ダウンロードの進捗を受け取るストリーム（0.0–1.0）。
  Stream<double> get progressStream =>
      _progressPort.where((msg) => msg is double).cast<double>();

  /// ダウンロードを開始し、完了時に結果を返す。
  /// 成功時は null、エラー時はエラーメッセージ。
  Future<String?> get result async {
    final res = await _resultPort.first;
    _progressPort.close();
    _resultPort.close();
    if (res is String) return res; // エラーメッセージ
    return null; // 成功
  }

  /// ダウンロードをキャンセルする。
  void cancel() {
    _isolate?.kill(priority: Isolate.immediate);
    _progressPort.close();
    _resultPort.close();
  }

  /// テスト用: 実 Isolate を生成せず、外部から制御できる [DownloadIsolate] を作成する。
  /// [progressPort] と [resultPort] にメッセージを送ることでダウンロード完了や
  /// エラーをシミュレートできる。
  @visibleForTesting
  static DownloadIsolate forTesting({
    required ReceivePort progressPort,
    required ReceivePort resultPort,
  }) =>
      DownloadIsolate._(null, progressPort, resultPort);

  /// バックグラウンド Isolate でダウンロードを開始する。
  static Future<DownloadIsolate> start({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKeyPem,
    String? passphrase,
    required String remotePath,
    required String localPath,
    required int totalBytes,
  }) async {
    final progressPort = ReceivePort();
    final resultPort = ReceivePort();

    final isolate = await Isolate.spawn(
      _isolateEntry,
      _DownloadRequest(
        host: host,
        port: port,
        username: username,
        password: password,
        privateKeyPem: privateKeyPem,
        passphrase: passphrase,
        remotePath: remotePath,
        localPath: localPath,
        totalBytes: totalBytes,
        progressSendPort: progressPort.sendPort,
        resultSendPort: resultPort.sendPort,
      ),
    );

    return DownloadIsolate._(isolate, progressPort, resultPort);
  }

  /// Isolate エントリポイント。
  static Future<void> _isolateEntry(_DownloadRequest req) async {
    SSHClient? client;
    try {
      // 1. SSH 接続を確立
      final socket = await Socket.connect(req.host, req.port,
          timeout: const Duration(seconds: 10));
      socket.setOption(SocketOption.tcpNoDelay, true);

      final sshSocket = _SimpleSSHSocket(socket);

      client = SSHClient(
        sshSocket,
        username: req.username,
        onPasswordRequest:
            req.password != null ? () => req.password : null,
        identities:
            req.privateKeyPem != null
                ? SSHKeyPair.fromPem(req.privateKeyPem!, req.passphrase)
                : null,
        onVerifyHostKey: (_, __) async => true, // ホスト検証はメイン接続で済み
      );

      await client.authenticated;

      // 2. gzip 圧縮ダウンロード。
      // SSH 暗号化がボトルネックのため、転送データ量を減らすのが最も効果的。
      // gzip -1（最速圧縮）→ SSH 転送 → ローカルで zlib 展開。
      // テキスト系ファイルで 5-10x、バイナリでもオーバーヘッドは最小。
      // gzip が使えない環境では cat にフォールバック。
      final session = await client.execute(
        'if command -v gzip >/dev/null 2>&1; then '
        'echo GZIP; gzip -1 -c ${shellQuote(req.remotePath)}; '
        'else '
        'echo RAW; cat ${shellQuote(req.remotePath)}; '
        'fi',
      );

      // 最初の行で圧縮モードを判定
      final stdoutStream = session.stdout;
      final iterator = StreamIterator(stdoutStream);

      bool useGzip = false;
      final headerBuf = BytesBuilder();

      // ヘッダー行（GZIP\n or RAW\n）を読み取る
      Uint8List? leftover;
      while (await iterator.moveNext()) {
        final chunk = iterator.current;
        final nlIndex = chunk.indexOf(10); // \n
        if (nlIndex >= 0) {
          headerBuf.add(chunk.sublist(0, nlIndex));
          final header = utf8.decode(headerBuf.toBytes()).trim();
          useGzip = header == 'GZIP';
          // ヘッダー行の後に残りデータがあれば保持
          if (nlIndex + 1 < chunk.length) {
            leftover = chunk.sublist(nlIndex + 1);
          }
          break;
        } else {
          headerBuf.add(chunk);
        }
      }

      final sink = File(req.localPath).openWrite();
      int written = 0; // 展開後のバイト数（実際のファイルサイズ）
      int lastReportedPercent = -1;

      try {
        if (useGzip) {
          // gzip ストリームを zlib で展開しながら書き込み
          final gzipDecoder = ZLibDecoder(raw: false);

          // 残りの SSH stdout を連結するストリーム
          Stream<Uint8List> dataStream() async* {
            if (leftover != null) yield leftover;
            while (await iterator.moveNext()) {
              yield iterator.current;
            }
          }

          // gzip データを蓄積して一括展開
          final compressedBuf = BytesBuilder(copy: false);
          await for (final chunk in dataStream()) {
            compressedBuf.add(chunk);
          }

          final decompressed = gzipDecoder.convert(compressedBuf.toBytes());
          sink.add(decompressed);
          written = decompressed.length;
          req.progressSendPort.send(1.0);
        } else {
          // RAW モード（cat フォールバック）
          if (leftover != null) {
            sink.add(leftover);
            written += leftover.length;
          }

          while (await iterator.moveNext()) {
            final chunk = iterator.current;
            sink.add(chunk);
            written += chunk.length;

            if (req.totalBytes > 0) {
              final percent = (written * 100 ~/ req.totalBytes);
              if (percent != lastReportedPercent) {
                lastReportedPercent = percent;
                req.progressSendPort.send(written / req.totalBytes);
              }
            }

            if (req.totalBytes > 0 && written >= req.totalBytes) {
              break;
            }
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      // session.done を待って exitCode を取得
      try {
        await session.done.timeout(const Duration(seconds: 5));
      } catch (_) {}

      final exitCode = session.exitCode;
      if (exitCode != null && exitCode != 0) {
        req.resultSendPort.send('Download failed with exit code $exitCode');
        return;
      }

      // 3. 整合性チェック
      if (req.totalBytes > 0 && written != req.totalBytes) {
        req.resultSendPort
            .send('Download incomplete: $written / ${req.totalBytes} bytes');
        return;
      }

      // 成功
      req.progressSendPort.send(1.0);
      req.resultSendPort.send(true);
    } catch (e) {
      req.resultSendPort.send('Download error: $e');
    } finally {
      try { client?.close(); } catch (_) {}
    }
  }

}

/// dartssh2 の SSHSocket インターフェースの最小実装。
/// ダウンロード専用のため keepalive は不要。
class _SimpleSSHSocket implements SSHSocket {
  _SimpleSSHSocket(this._socket);

  final Socket _socket;

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() => _socket.close();

  @override
  void destroy() => _socket.destroy();
}

class _DownloadRequest {
  const _DownloadRequest({
    required this.host,
    required this.port,
    required this.username,
    this.password,
    this.privateKeyPem,
    this.passphrase,
    required this.remotePath,
    required this.localPath,
    required this.totalBytes,
    required this.progressSendPort,
    required this.resultSendPort,
  });

  final String host;
  final int port;
  final String username;
  final String? password;
  final String? privateKeyPem;
  final String? passphrase;
  final String remotePath;
  final String localPath;
  final int totalBytes;
  final SendPort progressSendPort;
  final SendPort resultSendPort;
}
