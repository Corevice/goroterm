import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

/// TCP keepalive を有効にした SSH ソケット。
/// OS カーネルレベルで keepalive パケットを送信するため、
/// Dart イベントループがスロットルされたバックグラウンドでも接続が維持される。
class KeepaliveSSHSocket implements SSHSocket {
  KeepaliveSSHSocket._(this._socket);

  final Socket _socket;

  /// TCP keepalive を有効にして接続する。
  static Future<KeepaliveSSHSocket> connect(
    String host,
    int port, {
    Duration? timeout,
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);

    // TCP_NODELAY（dartssh2 デフォルトと同じ）
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (e) {
      debugPrint('[SSH] TCP_NODELAY setup FAILED: $e');
    }

    // SO_KEEPALIVE を有効化（Linux: SOL_SOCKET=1, SO_KEEPALIVE=9）
    try {
      socket.setRawOption(
        RawSocketOption.fromBool(RawSocketOption.levelSocket, 9, true),
      );

      // TCP_KEEPIDLE: 最初の keepalive パケットまでのアイドル時間（秒）
      // 15 秒: モバイル NAT の最短タイムアウト (30秒) より十分短い値。
      // NAT エントリが消える前に keepalive パケットが送信される。
      // Linux/Android: IPPROTO_TCP=6, TCP_KEEPIDLE=4
      socket.setRawOption(
        RawSocketOption.fromInt(RawSocketOption.levelTcp, 4, 15),
      );

      // TCP_KEEPINTVL: keepalive パケットの再送間隔（秒）
      // Linux: IPPROTO_TCP=6, TCP_KEEPINTVL=5
      socket.setRawOption(
        RawSocketOption.fromInt(RawSocketOption.levelTcp, 5, 10),
      );

      // TCP_KEEPCNT: 応答がない場合の最大再送回数
      // Linux: IPPROTO_TCP=6, TCP_KEEPCNT=6
      socket.setRawOption(
        RawSocketOption.fromInt(RawSocketOption.levelTcp, 6, 5),
      );
      debugPrint('[SSH] TCP keepalive configured OK');
    } catch (e) {
      debugPrint('[SSH] TCP keepalive setup FAILED: $e');
    }

    return KeepaliveSSHSocket._(socket);
  }

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
