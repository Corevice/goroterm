import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import 'connection_config.dart';
import 'keepalive_ssh_socket.dart';
import 'known_hosts_store.dart';
import '../error/app_error.dart';

class SshClientService {
  SshClientService({
    required this.knownHostsStore,
    Future<SSHSocket> Function(String, int, {Duration? timeout})? socketFactory,
    @visibleForTesting
    Future<SSHSession> Function(String command)? executeFactory,
  })  : _socketFactory = socketFactory ?? _defaultSocketFactory,
        _executeFactory = executeFactory;

  static Future<SSHSocket> _defaultSocketFactory(
    String host,
    int port, {
    Duration? timeout,
  }) =>
      KeepaliveSSHSocket.connect(host, port, timeout: timeout);

  final KnownHostsStore knownHostsStore;
  final Future<SSHSocket> Function(String, int, {Duration? timeout})
  _socketFactory;
  final Future<SSHSession> Function(String command)? _executeFactory;
  SSHClient? _client;

  // ---------------------------------------------------------------------
  // 秘密鍵パース結果のキャッシュ。
  //
  // ネイティブタブを多数開いていると、各タブ (= 各エンジン) が独自の
  // SshClientService を持つ。スリープ復帰後の同時再接続で、同じ
  // privateKeyPem/passphrase の組を毎回 SSHKeyPair.fromPem() で再パース
  // すると、パスフレーズ付き鍵の bcrypt-pbkdf (純 Dart) がメインスレッド上
  // で何十回も同時に走り、UI が固まる。パース結果は決定的なので、
  // pem+passphrase の組をキーにメモリ内キャッシュして再パースを避ける。
  // 永続化はしない（プロセス内メモリのみ）。上限を超えたら最古のエントリ
  // (最も長く未使用) を破棄する単純な LRU。
  static const int _maxKeyPairCacheEntries = 32;
  static final LinkedHashMap<String, List<SSHKeyPair>> _keyPairCache =
      LinkedHashMap<String, List<SSHKeyPair>>();

  /// テストからパース回数を数えられるよう差し替え可能にしたパーサ。
  /// 既定は [SSHKeyPair.fromPem]。
  @visibleForTesting
  static List<SSHKeyPair> Function(String pem, String? passphrase)
      keyPairParser = SSHKeyPair.fromPem;

  /// テスト専用: キャッシュを空にする。
  @visibleForTesting
  static void clearKeyPairCache() => _keyPairCache.clear();

  static String _keyPairCacheKey(String pem, String? passphrase) =>
      '$pem\u0000${passphrase ?? ''}';

  /// [pem]/[passphrase] の組でキャッシュを引き、無ければ [keyPairParser] で
  /// パースしてキャッシュする。パース結果に含まれる秘密鍵そのものやキーに
  /// 使う文字列はログに出さない。
  static List<SSHKeyPair> _parseKeyPairCached(String pem, String? passphrase) {
    final cacheKey = _keyPairCacheKey(pem, passphrase);
    final cached = _keyPairCache.remove(cacheKey);
    if (cached != null) {
      // LinkedHashMap: 削除して入れ直すことで最近使った扱いにする (LRU)。
      _keyPairCache[cacheKey] = cached;
      return cached;
    }
    final parsed = keyPairParser(pem, passphrase);
    _keyPairCache[cacheKey] = parsed;
    if (_keyPairCache.length > _maxKeyPairCacheEntries) {
      _keyPairCache.remove(_keyPairCache.keys.first);
    }
    return parsed;
  }

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
      // 秘密鍵のパース (bcrypt-pbkdf 等で数百ms〜数秒かかることがある) は
      // ソケット接続より先に行う。キャッシュヒットすればほぼ 0 コストになり、
      // 多数のタブが同時に再接続してもメインスレッドの同時多発パースを
      // 避けられる。ソケット接続の成否に関わらずパースだけは完了させたい
      // ので、この順序は意図的。
      final identities =
          config.authMethod == AuthMethod.key && privateKeyPem != null
              ? _parseKeyPairCached(privateKeyPem, passphrase)
              : null;

      // TCP keepalive 付きカスタムソケットを使用。
      // OS カーネルがバックグラウンドでも keepalive パケットを送信し、
      // NAT テーブルの有効期限切れを防ぐ。
      final socket = await _socketFactory(
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
        identities: identities,
        onVerifyHostKey: (type, fingerprint) async {
          return verifyHostKey(
            config.host,
            config.port,
            fingerprint,
            onUnknownHostKey: onUnknownHostKey,
            onHostKeyMismatch: onHostKeyMismatch,
          );
        },
        keepAliveInterval: const Duration(seconds: 30),
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

  @visibleForTesting
  Future<bool> verifyHostKey(
    String host,
    int port,
    Uint8List hostKey, {
    Future<bool> Function(String fingerprint)? onUnknownHostKey,
    Future<bool> Function(String storedFingerprint, String actualFingerprint)?
        onHostKeyMismatch,
  }) async {
    final fingerprint = knownHostsStore.computeFingerprint(hostKey);
    final (matched, storedFingerprint) =
        await knownHostsStore.verify(host, port, hostKey);

    if (matched == null) {
      // First connection - ask user
      final accepted = await onUnknownHostKey?.call(fingerprint) ?? false;
      if (accepted) {
        await knownHostsStore.saveFingerprint(host, port, fingerprint);
      }
      return accepted;
    }

    if (matched == false) {
      // Mismatch - potential MITM; storedFingerprint is already available
      final accepted = await onHostKeyMismatch?.call(
            storedFingerprint ?? '',
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
    final execute = _executeFactory;
    // _executeFactory は @visibleForTesting 用。通常実行時は _client チェックを行う。
    if (execute == null && (_client == null || _client!.isClosed)) return false;
    SSHSession? session;
    try {
      final executeCmd = execute ?? (String cmd) => _client!.execute(cmd);
      session = await executeCmd('true').timeout(executeTimeout);
      await session.done.timeout(doneTimeout);
      return true;
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    } finally {
      try { session?.close(); } catch (_) {}
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

  /// テスト専用: _client を直接注入する。
  /// isConnected の `_client != null && _client!.isClosed` パスや
  /// keepAlive の isClosed ガードを実際の SSH 接続なしにテストするために使用する。
  @visibleForTesting
  void setClientForTesting(SSHClient? client) => _client = client;
}
