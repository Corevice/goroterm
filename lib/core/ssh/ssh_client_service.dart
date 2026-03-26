import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'connection_config.dart';
import 'keepalive_ssh_socket.dart';
import 'known_hosts_store.dart';
import '../error/app_error.dart';

class SshClientService {
  SshClientService({required this.knownHostsStore});

  final KnownHostsStore knownHostsStore;
  SSHClient? _client;

  SSHClient? get client => _client;
  bool get isConnected => _client != null && !_client!.isClosed;

  Future<SSHClient> connect({
    required ConnectionConfig config,
    required String? password,
    String? privateKeyPem,
    String? passphrase,
    Future<bool> Function(String fingerprint)? onUnknownHostKey,
    Future<bool> Function(String storedFingerprint, String actualFingerprint)?
        onHostKeyMismatch,
  }) async {
    try {
      // TCP keepalive 付きカスタムソケットを使用。
      // OS カーネルがバックグラウンドでも keepalive パケットを送信し、
      // NAT テーブルの有効期限切れを防ぐ。
      final socket = await KeepaliveSSHSocket.connect(
        config.host,
        config.port,
        timeout: const Duration(seconds: 10),
      );

      _client = SSHClient(
        socket,
        username: config.username,
        onPasswordRequest: config.authMethod == AuthMethod.password
            ? () => password
            : null,
        identities: config.authMethod == AuthMethod.key && privateKeyPem != null
            ? SSHKeyPair.fromPem(privateKeyPem, passphrase)
            : null,
        onVerifyHostKey: (type, fingerprint) async {
          return _verifyHostKey(
            config.host,
            config.port,
            fingerprint,
            onUnknownHostKey: onUnknownHostKey,
            onHostKeyMismatch: onHostKeyMismatch,
          );
        },
        keepAliveInterval: const Duration(seconds: 10),
      );

      await _client!.authenticated;
      return _client!;
    } on SocketException catch (e) {
      throw NetworkError(e.message);
    } on SSHAuthFailError {
      throw const AuthenticationError('Authentication failed');
    } on SSHAuthAbortError {
      throw const AuthenticationError('Authentication aborted');
    } on TimeoutException {
      throw const NetworkError('Connection timed out');
    } catch (e) {
      throw NetworkError('Connection failed: $e');
    }
  }

  Future<bool> _verifyHostKey(
    String host,
    int port,
    Uint8List hostKey, {
    Future<bool> Function(String fingerprint)? onUnknownHostKey,
    Future<bool> Function(String storedFingerprint, String actualFingerprint)?
        onHostKeyMismatch,
  }) async {
    final fingerprint = knownHostsStore.computeFingerprint(hostKey);
    final result = await knownHostsStore.verify(host, port, hostKey);

    if (result == null) {
      // First connection - ask user
      final accepted = await onUnknownHostKey?.call(fingerprint) ?? false;
      if (accepted) {
        await knownHostsStore.saveFingerprint(host, port, fingerprint);
      }
      return accepted;
    }

    if (result == false) {
      // Mismatch - potential MITM
      final storedFingerprint =
          await knownHostsStore.getStoredFingerprint(host, port);
      final accepted = await onHostKeyMismatch?.call(
            storedFingerprint!,
            fingerprint,
          ) ??
          false;
      if (accepted) {
        await knownHostsStore.saveFingerprint(host, port, fingerprint);
      }
      return accepted;
    }

    return true; // Match
  }

  /// 軽量な keepalive: `true` コマンドを実行して接続を維持する。
  /// SSH_MSG_CHANNEL_OPEN → SSH_MSG_CHANNEL_CLOSE のやり取りで
  /// サーバーに接続が生きていることを通知する。
  /// 成功なら true、失敗（接続切れ）なら false。
  Future<bool> keepAlive({
    Duration executeTimeout = const Duration(seconds: 5),
    Duration doneTimeout = const Duration(seconds: 5),
  }) async {
    if (_client == null || _client!.isClosed) return false;
    try {
      final session = await _client!
          .execute('true')
          .timeout(executeTimeout);
      await session.done.timeout(doneTimeout);
      return true;
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }

  void disconnect() {
    try {
      _client?.close();
    } catch (_) {
      // close 中のエラーは無視
    } finally {
      _client = null;
    }
  }
}
