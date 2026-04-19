import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../preferences/power_settings.dart';

// SO_KEEPALIVE option number at SOL_SOCKET level (platform-specific)
const _soKeepaliveLinux = 9; // Linux/Android
const _soKeepaliveDarwin = 8; // macOS/iOS (0x0008)

// TCP keepalive tuning constants — Linux/Android (IPPROTO_TCP level)
const _tcpKeepidle = 4; // TCP_KEEPIDLE: idle seconds before first probe
const _tcpKeepintvl = 5; // TCP_KEEPINTVL: seconds between probes
const _tcpKeepcnt = 6; // TCP_KEEPCNT: max unanswered probes

// TCP keepalive tuning constants — macOS/iOS (IPPROTO_TCP level)
const _tcpKeepaliveDarwin = 0x10; // TCP_KEEPALIVE (equivalent to TCP_KEEPIDLE)
const _tcpKeepintvlDarwin = 0x101; // TCP_KEEPINTVL on macOS/iOS
const _tcpKeepcntDarwin = 0x102; // TCP_KEEPCNT on macOS/iOS

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

    applyKeepaliveOptions(socket);

    return KeepaliveSSHSocket._(socket);
  }

  /// TCP keepalive オプションをソケットに適用する。
  ///
  /// SO_KEEPALIVE のオプション番号はプラットフォームで異なるため、
  /// Linux/Android と macOS/iOS で別の定数を使用する。
  /// TCP 詳細パラメータも同様にプラットフォーム別の定数で設定する。
  @visibleForTesting
  static void applyKeepaliveOptions(Socket socket) {
    try {
      final isDarwin = Platform.isMacOS || Platform.isIOS;

      // SO_KEEPALIVE を有効化
      socket.setRawOption(
        RawSocketOption.fromBool(
          RawSocketOption.levelSocket,
          isDarwin ? _soKeepaliveDarwin : _soKeepaliveLinux,
          true,
        ),
      );

      // ユーザー設定の idle 値を使用。短いほど切断検知が早いがバッテリー消費大。
      final idleSeconds = PowerSettings.tcpKeepaliveIdleSeconds;

      if (isDarwin) {
        // macOS/iOS: TCP_KEEPALIVE (idle), TCP_KEEPINTVL, TCP_KEEPCNT
        socket.setRawOption(
          RawSocketOption.fromInt(
              RawSocketOption.levelTcp, _tcpKeepaliveDarwin, idleSeconds),
        );
        socket.setRawOption(
          RawSocketOption.fromInt(RawSocketOption.levelTcp, _tcpKeepintvlDarwin, 10),
        );
        socket.setRawOption(
          RawSocketOption.fromInt(RawSocketOption.levelTcp, _tcpKeepcntDarwin, 5),
        );
      } else {
        // Linux/Android: TCP_KEEPIDLE, TCP_KEEPINTVL, TCP_KEEPCNT
        socket.setRawOption(
          RawSocketOption.fromInt(
              RawSocketOption.levelTcp, _tcpKeepidle, idleSeconds),
        );
        socket.setRawOption(
          RawSocketOption.fromInt(RawSocketOption.levelTcp, _tcpKeepintvl, 10),
        );
        socket.setRawOption(
          RawSocketOption.fromInt(RawSocketOption.levelTcp, _tcpKeepcnt, 5),
        );
      }

      debugPrint('[SSH] TCP keepalive configured OK');
    } catch (e) {
      debugPrint('[SSH] TCP keepalive setup FAILED: $e');
    }
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
