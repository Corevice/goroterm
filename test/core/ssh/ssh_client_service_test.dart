import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:terminal_ssh_app/core/ssh/connection_config.dart';
import 'package:terminal_ssh_app/core/error/app_error.dart';
import 'package:terminal_ssh_app/core/platform/macos_kv_store.dart';
import 'package:terminal_ssh_app/core/ssh/keepalive_ssh_socket.dart';
import 'package:terminal_ssh_app/core/ssh/known_hosts_store.dart';
import 'package:terminal_ssh_app/core/ssh/ssh_channel_manager.dart';
import 'package:terminal_ssh_app/core/ssh/ssh_client_service.dart';
import 'package:terminal_ssh_app/core/ssh/ssh_key_manager.dart';
import 'package:terminal_ssh_app/core/utils/shell_utils.dart';

class MockKnownHostsStore extends Mock implements KnownHostsStore {}

class MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

/// Records all [setRawOption] calls without touching the OS.
class _FakeSocket extends Fake implements Socket {
  final List<RawSocketOption> rawOptions = [];

  @override
  bool setRawOption(RawSocketOption option) {
    rawOptions.add(option);
    return true;
  }

  @override
  bool setOption(SocketOption option, bool enabled) => true;
}

class _ThrowingSocket extends Fake implements Socket {
  @override
  bool setRawOption(RawSocketOption option) =>
      throw const SocketException('simulated failure');
}

// ---------------------------------------------------------------------------
// Fakes for _readAbsolutePath tests (ssh_channel_manager)
// ---------------------------------------------------------------------------

class _StubSession extends Fake implements SSHSession {
  _StubSession(String output)
      : _stdout =
            Stream.value(Uint8List.fromList(utf8.encode(output)));

  final Stream<Uint8List> _stdout;
  bool closeCalled = false;

  @override
  Stream<Uint8List> get stdout => _stdout;

  @override
  void close() => closeCalled = true;
}

class _StubClient extends Fake implements SSHClient {
  _StubClient(this._factory);
  final SSHSession Function(String command) _factory;

  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    Map<String, String>? environment,
  }) async =>
      _factory(command);
}

class _ThrowingClient extends Fake implements SSHClient {
  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    Map<String, String>? environment,
  }) =>
      Future.error(Exception('execute failed'));
}

class _ShellThrowingClient extends Fake implements SSHClient {
  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty,
    Map<String, String>? environment,
  }) =>
      Future.error(Exception('shell failed'));
}

class _FakePtySession extends Fake implements SSHSession {
  bool closeCalled = false;
  final List<(int, int)> resizeCalls = [];

  @override
  Stream<Uint8List> get stdout => const Stream.empty();

  @override
  void close() => closeCalled = true;

  @override
  void resizeTerminal(int width, int height, [int pixelWidth = 0, int pixelHeight = 0]) =>
      resizeCalls.add((width, height));
}

class _FakeShellClient extends Fake implements SSHClient {
  _FakeShellClient(this.session);
  final _FakePtySession session;

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty,
    Map<String, String>? environment,
  }) async =>
      session;
}

class _RunThrowingClient extends Fake implements SSHClient {
  @override
  Future<Uint8List> run(
    String command, {
    bool runInPty = false,
    bool stdout = true,
    bool stderr = true,
    Map<String, String>? environment,
  }) =>
      Future.error(Exception('run failed'));
}

class _CapturingShellClient extends Fake implements SSHClient {
  _CapturingShellClient(this._session);
  final _FakePtySession _session;
  SSHPtyConfig? capturedPty;

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty,
    Map<String, String>? environment,
  }) async {
    capturedPty = pty;
    return _session;
  }
}

class _FakeRunClient extends Fake implements SSHClient {
  _FakeRunClient(this._result);
  final Uint8List _result;

  @override
  Future<Uint8List> run(
    String command, {
    bool runInPty = false,
    bool stdout = true,
    bool stderr = true,
    Map<String, String>? environment,
  }) async =>
      _result;
}

class _CombinedFakeClient extends Fake implements SSHClient {
  _CombinedFakeClient({required this.ptySession, required this.sftpCounter});
  final _FakePtySession ptySession;
  final _SftpCountingClient sftpCounter;

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty,
    Map<String, String>? environment,
  }) async =>
      ptySession;

  @override
  Future<SftpClient> sftp() => sftpCounter.sftp();
}

class _SftpThrowingClient extends Fake implements SSHClient {
  @override
  Future<SftpClient> sftp() => Future.error(Exception('sftp failed'));
}

class _SftpSucceedOnceThenThrowClient extends Fake implements SSHClient {
  final _FakeSftpClient firstClient = _FakeSftpClient();
  int _calls = 0;

  @override
  Future<SftpClient> sftp() async {
    _calls++;
    if (_calls == 1) return firstClient;
    throw Exception('sftp failed on second call');
  }
}

class _FakeSftpClient extends Fake implements SftpClient {
  bool closeCalled = false;

  @override
  void close() => closeCalled = true;
}

class _SftpCountingClient extends Fake implements SSHClient {
  final List<_FakeSftpClient> created = [];

  @override
  Future<SftpClient> sftp() async {
    final fake = _FakeSftpClient();
    created.add(fake);
    return fake;
  }
}

class _HangingSession extends Fake implements SSHSession {
  _HangingSession() : _controller = StreamController<Uint8List>();

  final StreamController<Uint8List> _controller;
  bool closeCalled = false;

  @override
  Stream<Uint8List> get stdout => _controller.stream;

  @override
  void close() => closeCalled = true;

  void dispose() {
    if (!_controller.isClosed) _controller.close();
  }
}

/// SSHClient の isClosed が true を返す最小限のフェイク。
/// SshClientService.isConnected / keepAlive の isClosed ガードをテストするために使用する。
class _FakeClosedSSHClient extends Fake implements SSHClient {
  @override
  bool get isClosed => true;
}

/// close() 呼び出しを追跡するフェイク SSHClient。
/// disconnect() が実際に SSHClient.close() を呼び出すかを検証するために使用する。
class _FakeTrackingSSHClient extends Fake implements SSHClient {
  bool closeCalled = false;

  @override
  bool get isClosed => false; // 接続中（非 closed）として振る舞う

  @override
  void close() => closeCalled = true;
}

/// テスト用のフェイク SSHSession。
/// [done] を制御できる Completer を受け取り、close() の呼び出しを追跡する。
class _FakeSession extends Fake implements SSHSession {
  _FakeSession(this._doneCompleter);
  final Completer<void> _doneCompleter;
  bool closeCalled = false;

  @override
  Future<void> get done => _doneCompleter.future;

  @override
  void close() => closeCalled = true;
}

void main() {
  group('ConnectionConfig', () {
    test('should create with required fields', () {
      final config = ConnectionConfig(
        label: 'Test Server',
        host: 'example.com',
        username: 'user',
      );

      expect(config.label, 'Test Server');
      expect(config.host, 'example.com');
      expect(config.port, 22);
      expect(config.username, 'user');
      expect(config.authMethod, AuthMethod.password);
      expect(config.id, isNull);
      expect(config.createdAt, isNull);
    });

    test('should create with all fields', () {
      final now = DateTime.now();
      final config = ConnectionConfig(
        id: 'test-id',
        label: 'Test',
        host: '192.168.1.1',
        port: 2222,
        username: 'admin',
        authMethod: AuthMethod.key,
        createdAt: now,
      );

      expect(config.port, 2222);
      expect(config.authMethod, AuthMethod.key);
      expect(config.createdAt, now);
    });

    test('copyWith should create modified copy', () {
      final config = ConnectionConfig(
        label: 'Test',
        host: 'example.com',
        username: 'user',
      );
      final modified = config.copyWith(port: 2222);
      expect(modified.port, 2222);
      expect(modified.host, 'example.com');
    });

    test('should serialize to/from JSON', () {
      final config = ConnectionConfig(
        id: 'test-id',
        label: 'Test',
        host: 'example.com',
        port: 22,
        username: 'user',
        authMethod: AuthMethod.password,
      );

      final json = config.toJson();
      final restored = ConnectionConfig.fromJson(json);
      expect(restored, equals(config));
    });
  });

  group('AppError', () {
    test('AuthenticationError should contain message', () {
      const error = AuthenticationError('Invalid password');
      expect(error.message, 'Invalid password');
      expect(error, isA<AppError>());
    });

    test('HostKeyError should contain fingerprint', () {
      const error = HostKeyError(
        'Host key mismatch',
        fingerprint: 'abc123',
      );
      expect(error.fingerprint, 'abc123');
      expect(error, isA<AppError>());
    });

    test('NetworkError should contain message', () {
      const error = NetworkError('Connection timed out');
      expect(error.message, 'Connection timed out');
      expect(error, isA<AppError>());
    });

    test('PermissionError should contain message', () {
      const error = PermissionError('Access denied');
      expect(error.message, 'Access denied');
      expect(error, isA<AppError>());
    });
  });

  group('SshClientService.connect() catch-all', () {
    late MockKnownHostsStore mockStore;

    setUp(() {
      mockStore = MockKnownHostsStore();
    });

    test('wraps SocketException in NetworkError', () async {
      final service = SshClientService(
        knownHostsStore: mockStore,
        socketFactory: (host, port, {timeout}) =>
            Future.error(const SocketException('Connection refused')),
      );
      final config = ConnectionConfig(
        label: 'Test',
        host: '127.0.0.1',
        username: 'user',
      );
      expect(
        () => service.connect(config: config, password: null),
        throwsA(isA<NetworkError>()),
      );
    });

    test('wraps TimeoutException in NetworkError', () async {
      final service = SshClientService(
        knownHostsStore: mockStore,
        socketFactory: (host, port, {timeout}) =>
            Future.error(TimeoutException('timed out')),
      );
      final config = ConnectionConfig(
        label: 'Test',
        host: '127.0.0.1',
        username: 'user',
      );
      expect(
        () => service.connect(config: config, password: null),
        throwsA(isA<NetworkError>()),
      );
    });

    test('wraps unknown exception in NetworkError', () async {
      final service = SshClientService(
        knownHostsStore: mockStore,
        socketFactory: (host, port, {timeout}) =>
            Future.error(Exception('unexpected SSH handshake error')),
      );
      final config = ConnectionConfig(
        label: 'Test',
        host: '127.0.0.1',
        username: 'user',
      );
      await expectLater(
        service.connect(config: config, password: null),
        throwsA(
          isA<NetworkError>().having(
            (e) => e.message,
            'message',
            contains('Connection failed'),
          ),
        ),
      );
    });

    test('wraps SSHAuthFailError in AuthenticationError', () async {
      final service = SshClientService(
        knownHostsStore: mockStore,
        socketFactory: (host, port, {timeout}) =>
            Future.error(SSHAuthFailError('bad credentials')),
      );
      final config = ConnectionConfig(
        label: 'Test',
        host: '127.0.0.1',
        username: 'user',
      );
      await expectLater(
        service.connect(config: config, password: null),
        throwsA(
          isA<AuthenticationError>().having(
            (e) => e.message,
            'message',
            'Authentication failed',
          ),
        ),
      );
    });

    test('wraps SSHAuthAbortError in AuthenticationError', () async {
      final service = SshClientService(
        knownHostsStore: mockStore,
        socketFactory: (host, port, {timeout}) =>
            Future.error(SSHAuthAbortError('aborted by server')),
      );
      final config = ConnectionConfig(
        label: 'Test',
        host: '127.0.0.1',
        username: 'user',
      );
      await expectLater(
        service.connect(config: config, password: null),
        throwsA(
          isA<AuthenticationError>().having(
            (e) => e.message,
            'message',
            'Authentication aborted',
          ),
        ),
      );
    });
  });

  group('SshClientService.verifyHostKey', () {
    late MockKnownHostsStore mockStore;
    late SshClientService service;

    final hostKey = Uint8List.fromList([1, 2, 3, 4, 5]);
    const host = 'example.com';
    const port = 22;

    setUp(() {
      mockStore = MockKnownHostsStore();
      service = SshClientService(knownHostsStore: mockStore);
    });

    test('unknown host: calls onUnknownHostKey and saves fingerprint on accept',
        () async {
      const fingerprint = 'fp_new';
      when(() => mockStore.computeFingerprint(hostKey)).thenReturn(fingerprint);
      when(() => mockStore.verify(host, port, hostKey))
          .thenAnswer((_) async => (null, null));
      when(() => mockStore.saveFingerprint(host, port, fingerprint))
          .thenAnswer((_) async {});

      String? receivedFp;
      final result = await service.verifyHostKey(
        host,
        port,
        hostKey,
        onUnknownHostKey: (fp) async {
          receivedFp = fp;
          return true;
        },
      );

      expect(result, isTrue);
      expect(receivedFp, equals(fingerprint));
      verify(() => mockStore.saveFingerprint(host, port, fingerprint))
          .called(1);
    });

    test('unknown host: returns false and skips save when user rejects',
        () async {
      const fingerprint = 'fp_new';
      when(() => mockStore.computeFingerprint(hostKey)).thenReturn(fingerprint);
      when(() => mockStore.verify(host, port, hostKey))
          .thenAnswer((_) async => (null, null));

      final result = await service.verifyHostKey(
        host,
        port,
        hostKey,
        onUnknownHostKey: (_) async => false,
      );

      expect(result, isFalse);
      verifyNever(() => mockStore.saveFingerprint(any(), any(), any()));
    });

    test('mismatch: passes both fingerprints to onHostKeyMismatch and saves on accept',
        () async {
      const fingerprint = 'fp_actual';
      const storedFp = 'fp_stored';
      when(() => mockStore.computeFingerprint(hostKey)).thenReturn(fingerprint);
      when(() => mockStore.verify(host, port, hostKey))
          .thenAnswer((_) async => (false, storedFp));
      when(() => mockStore.saveFingerprint(host, port, fingerprint))
          .thenAnswer((_) async {});

      String? gotStored;
      String? gotActual;
      final result = await service.verifyHostKey(
        host,
        port,
        hostKey,
        onHostKeyMismatch: (stored, actual) async {
          gotStored = stored;
          gotActual = actual;
          return true;
        },
      );

      expect(result, isTrue);
      expect(gotStored, equals(storedFp));
      expect(gotActual, equals(fingerprint));
      verify(() => mockStore.saveFingerprint(host, port, fingerprint))
          .called(1);
    });

    test('mismatch: returns false and skips save when user rejects', () async {
      const fingerprint = 'fp_actual';
      const storedFp = 'fp_stored';
      when(() => mockStore.computeFingerprint(hostKey)).thenReturn(fingerprint);
      when(() => mockStore.verify(host, port, hostKey))
          .thenAnswer((_) async => (false, storedFp));

      final result = await service.verifyHostKey(
        host,
        port,
        hostKey,
        onHostKeyMismatch: (_, __) async => false,
      );

      expect(result, isFalse);
      verifyNever(() => mockStore.saveFingerprint(any(), any(), any()));
    });

    test('unknown host: returns false (fail-closed) when onUnknownHostKey is null',
        () async {
      // Security: if no dialog is wired up, the connection must be rejected.
      // Tests the `onUnknownHostKey?.call(fp) ?? false` pattern.
      when(() => mockStore.computeFingerprint(hostKey)).thenReturn('fp_new');
      when(() => mockStore.verify(host, port, hostKey))
          .thenAnswer((_) async => (null, null));

      final result = await service.verifyHostKey(host, port, hostKey);

      expect(result, isFalse);
      verifyNever(() => mockStore.saveFingerprint(any(), any(), any()));
    });

    test('mismatch: returns false (fail-closed) when onHostKeyMismatch is null',
        () async {
      // Security: if no dialog is wired up, the connection must be rejected.
      // Tests the `onHostKeyMismatch?.call(...) ?? false` pattern.
      when(() => mockStore.computeFingerprint(hostKey)).thenReturn('fp_actual');
      when(() => mockStore.verify(host, port, hostKey))
          .thenAnswer((_) async => (false, 'fp_stored'));

      final result = await service.verifyHostKey(host, port, hostKey);

      expect(result, isFalse);
      verifyNever(() => mockStore.saveFingerprint(any(), any(), any()));
    });

    test('match: returns true without invoking any callbacks', () async {
      const fingerprint = 'fp_match';
      when(() => mockStore.computeFingerprint(hostKey)).thenReturn(fingerprint);
      when(() => mockStore.verify(host, port, hostKey))
          .thenAnswer((_) async => (true, fingerprint));

      bool unknownCalled = false;
      bool mismatchCalled = false;
      final result = await service.verifyHostKey(
        host,
        port,
        hostKey,
        onUnknownHostKey: (_) async {
          unknownCalled = true;
          return true;
        },
        onHostKeyMismatch: (_, __) async {
          mismatchCalled = true;
          return true;
        },
      );

      expect(result, isTrue);
      expect(unknownCalled, isFalse);
      expect(mismatchCalled, isFalse);
      verifyNever(() => mockStore.saveFingerprint(any(), any(), any()));
    });
  });

  group('SshClientService.keepAlive', () {
    late MockKnownHostsStore mockStore;

    setUp(() {
      mockStore = MockKnownHostsStore();
    });

    SshClientService makeService(Future<SSHSession> Function(String) factory) {
      return SshClientService(
        knownHostsStore: mockStore,
        executeFactory: factory,
      );
    }

    test('returns true when session completes normally', () async {
      final doneCompleter = Completer<void>()..complete();
      final fakeSession = _FakeSession(doneCompleter);
      final service = makeService((_) async => fakeSession);

      final result = await service.keepAlive();

      expect(result, isTrue);
      expect(fakeSession.closeCalled, isTrue,
          reason: 'session must be closed in finally even on success');
    });

    test('done timeout: returns false and closes session', () async {
      final fakeSession = _FakeSession(Completer<void>()); // never completes
      final service = makeService((_) async => fakeSession);

      final result = await service.keepAlive(
        doneTimeout: const Duration(milliseconds: 10),
      );

      expect(result, isFalse);
      expect(fakeSession.closeCalled, isTrue,
          reason: 'session must be closed even on done timeout (resource leak fix)');
    });

    test('execute timeout: returns false without crash', () async {
      final service = makeService(
        (_) => Future.delayed(
          const Duration(seconds: 10),
          () => _FakeSession(Completer<void>()),
        ),
      );

      final result = await service.keepAlive(
        executeTimeout: const Duration(milliseconds: 10),
      );

      expect(result, isFalse);
      // session was never assigned — no close() call needed, just no crash
    });

    test('execute throws: returns false without crash', () async {
      final service = makeService(
        (_) => Future.error(Exception('channel open failed')),
      );

      final result = await service.keepAlive();

      expect(result, isFalse);
    });
  });

  group('SshClientService.keepAlive without executeFactory', () {
    late MockKnownHostsStore mockStore;

    setUp(() {
      mockStore = MockKnownHostsStore();
    });

    test('returns false when client is null (production guard path)', () async {
      // No executeFactory → production path: guard checks _client == null.
      // execute == null && _client == null → returns false immediately.
      final service = SshClientService(knownHostsStore: mockStore);
      final result = await service.keepAlive();
      expect(result, isFalse);
    });
  });

  group('SshClientService.disconnect and isConnected', () {
    late MockKnownHostsStore mockStore;

    setUp(() {
      mockStore = MockKnownHostsStore();
    });

    test('isConnected returns false when client is null', () {
      final service = SshClientService(knownHostsStore: mockStore);
      expect(service.isConnected, isFalse);
    });

    test('client getter returns null when not connected', () {
      final service = SshClientService(knownHostsStore: mockStore);
      expect(service.client, isNull);
    });

    test('disconnect() does not throw when client is null', () {
      final service = SshClientService(knownHostsStore: mockStore);
      expect(() => service.disconnect(), returnsNormally);
    });

    test('isConnected returns false after disconnect() on null client', () {
      final service = SshClientService(knownHostsStore: mockStore);
      service.disconnect();
      expect(service.isConnected, isFalse);
    });

    test('disconnect() calls close() on a non-null open client', () {
      // Verifies that disconnect() actually invokes SSHClient.close().
      // The implementation: try { _client?.close(); } catch(_) {} finally { _client = null; }
      final service = SshClientService(knownHostsStore: mockStore);
      final fake = _FakeTrackingSSHClient();
      service.setClientForTesting(fake);

      service.disconnect();

      expect(fake.closeCalled, isTrue,
          reason: 'disconnect() must call close() on the SSH client');
      expect(service.client, isNull,
          reason: 'disconnect() must clear _client after close()');
    });
  });

  group('SshClientService isClosed client path', () {
    late MockKnownHostsStore mockStore;

    setUp(() {
      mockStore = MockKnownHostsStore();
    });

    test('isConnected returns false when client is not null but isClosed', () {
      // _client != null && _client!.isClosed == true → isConnected must be false.
      // This tests the second branch of:
      //   bool get isConnected => _client != null && !_client!.isClosed;
      final service = SshClientService(knownHostsStore: mockStore);
      service.setClientForTesting(_FakeClosedSSHClient());
      expect(service.isConnected, isFalse);
    });

    test('client getter returns the injected closed client', () {
      final service = SshClientService(knownHostsStore: mockStore);
      final fake = _FakeClosedSSHClient();
      service.setClientForTesting(fake);
      expect(service.client, same(fake));
    });

    test('keepAlive returns false when client is not null but isClosed (production guard)', () async {
      // No executeFactory → production guard path:
      //   execute == null && (_client == null || _client!.isClosed) → return false.
      // This tests the _client!.isClosed branch of the guard condition.
      final service = SshClientService(knownHostsStore: mockStore);
      service.setClientForTesting(_FakeClosedSSHClient());
      final result = await service.keepAlive();
      expect(result, isFalse);
    });

    test('disconnect() after injecting closed client resets isConnected to false', () {
      final service = SshClientService(knownHostsStore: mockStore);
      service.setClientForTesting(_FakeClosedSSHClient());
      // Already false because isClosed=true, but disconnect() must also clear _client.
      service.disconnect();
      expect(service.isConnected, isFalse);
      expect(service.client, isNull);
    });
  });

  // =====================================================================
  // keepalive_ssh_socket.dart
  // =====================================================================
  group('KeepaliveSSHSocket.applyKeepaliveOptions', () {
    late _FakeSocket fakeSocket;

    setUp(() {
      fakeSocket = _FakeSocket();
    });

    test('sets exactly 4 options: 1 SO_KEEPALIVE + 3 TCP tuning', () {
      KeepaliveSSHSocket.applyKeepaliveOptions(fakeSocket);
      expect(fakeSocket.rawOptions.length, 4);
    });

    test('first option is at SOL_SOCKET level', () {
      KeepaliveSSHSocket.applyKeepaliveOptions(fakeSocket);
      expect(fakeSocket.rawOptions.first.level, RawSocketOption.levelSocket);
    });

    test('remaining 3 options are at IPPROTO_TCP level', () {
      KeepaliveSSHSocket.applyKeepaliveOptions(fakeSocket);
      final tcpOptions = fakeSocket.rawOptions.skip(1).toList();
      for (final opt in tcpOptions) {
        expect(opt.level, RawSocketOption.levelTcp);
      }
    });

    test('SO_KEEPALIVE value is 1 (enabled)', () {
      KeepaliveSSHSocket.applyKeepaliveOptions(fakeSocket);
      final soOpt = fakeSocket.rawOptions.first;
      expect(soOpt.value.length, 4);
      final view = ByteData.sublistView(soOpt.value);
      expect(view.getInt32(0, Endian.host), 1);
    });

    test('TCP idle option value matches PowerSettings default (45 seconds)', () {
      KeepaliveSSHSocket.applyKeepaliveOptions(fakeSocket);
      final idleOpt = fakeSocket.rawOptions[1];
      final view = ByteData.sublistView(idleOpt.value);
      expect(view.getInt32(0, Endian.host), 45);
    });

    test('does not throw even when socket setRawOption throws', () {
      expect(
        () => KeepaliveSSHSocket.applyKeepaliveOptions(_ThrowingSocket()),
        returnsNormally,
      );
    });

    test('applies options idempotently on repeated calls', () {
      KeepaliveSSHSocket.applyKeepaliveOptions(fakeSocket);
      KeepaliveSSHSocket.applyKeepaliveOptions(fakeSocket);
      expect(fakeSocket.rawOptions.length, 8);
    });
  });

  // =====================================================================
  // ssh_key_manager.dart
  // =====================================================================
  // Test fixtures sourced from dartssh2's own test suite.
  const _ed25519Unencrypted = '''
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACBZnnnYZjFQ7Zt0gMyJ2YYmDINTucLFWY81/Wuv2aOIpAAAAKBQ6gOSUOoD
kgAAAAtzc2gtZWQyNTUxOQAAACBZnnnYZjFQ7Zt0gMyJ2YYmDINTucLFWY81/Wuv2aOIpA
AAAEAP8fq0hjlR3jhL7pg+26PSaMiC1V/RrinVbo/4eBMRNFmeedhmMVDtm3SAzInZhiYM
g1O5wsVZjzX9a6/Zo4ikAAAAGWpmb3V0dHNAVVNBSkZPVVRUU00ubG9jYWwBAgME
-----END OPENSSH PRIVATE KEY-----
''';

  const _ed25519Encrypted = '''
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABC0l9Iobg
dIkpFRXIVcSMo9AAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIDl6gJA/mTwGajQU
GysVNxbg5DLxNkxNMr1N6nMqmILLAAAAoAheLDCmikMrd30h6Z3ug4h7WsK8TjBYToUkhO
1fu5qRd6pgCCeQt0C5eeJMkCSNTP+HZyWT9Vc67VCvzaECjFfXYJUsRYdknAXEO4oFc9fg
v8qGMQTFoIajXQk8Gk9QLqGQ0nupn4fZ3BhHhMoDIx7DWLhlvHddSJzgkORIt4bV8ntzh8
AK9jJFzpo0q4FnYkalW4fo/nosGUM/bq5LR2M=
-----END OPENSSH PRIVATE KEY-----
''';

  const _ed25519Passphrase = '123456';

  group('SshKeyManager', () {
    late MockFlutterSecureStorage mockKeyStorage;
    late SshKeyManager keyManager;

    setUp(() {
      mockKeyStorage = MockFlutterSecureStorage();
      keyManager = SshKeyManager(storage: mockKeyStorage);
    });

    group('savePrivateKey()', () {
      test('writes PEM content under ssh_key_-prefixed key', () async {
        when(() => mockKeyStorage.write(
              key: 'ssh_key_my-key',
              value: '-----BEGIN RSA PRIVATE KEY-----',
            )).thenAnswer((_) async {});

        await keyManager.savePrivateKey('my-key', '-----BEGIN RSA PRIVATE KEY-----');

        verify(() => mockKeyStorage.write(
              key: 'ssh_key_my-key',
              value: '-----BEGIN RSA PRIVATE KEY-----',
            )).called(1);
      });

      test('uses keyId verbatim as the suffix after ssh_key_', () async {
        when(() => mockKeyStorage.write(
              key: 'ssh_key_prod-server-2024',
              value: 'pem',
            )).thenAnswer((_) async {});

        await keyManager.savePrivateKey('prod-server-2024', 'pem');

        verify(() => mockKeyStorage.write(
              key: 'ssh_key_prod-server-2024',
              value: 'pem',
            )).called(1);
      });
    });

    group('loadPrivateKey()', () {
      test('returns PEM content for an existing key', () async {
        when(() => mockKeyStorage.read(key: 'ssh_key_my-key'))
            .thenAnswer((_) async => '-----BEGIN RSA PRIVATE KEY-----');

        final result = await keyManager.loadPrivateKey('my-key');
        expect(result, '-----BEGIN RSA PRIVATE KEY-----');
      });

      test('returns null for a non-existent key', () async {
        when(() => mockKeyStorage.read(key: 'ssh_key_unknown'))
            .thenAnswer((_) async => null);

        expect(await keyManager.loadPrivateKey('unknown'), isNull);
      });
    });

    group('deletePrivateKey()', () {
      test('deletes the ssh_key_-prefixed storage entry', () async {
        when(() => mockKeyStorage.delete(key: 'ssh_key_my-key'))
            .thenAnswer((_) async {});

        await keyManager.deletePrivateKey('my-key');
        verify(() => mockKeyStorage.delete(key: 'ssh_key_my-key')).called(1);
      });
    });

    group('listKeyIds()', () {
      test('returns empty list when storage is empty', () async {
        when(() => mockKeyStorage.readAll()).thenAnswer((_) async => {});
        expect(await keyManager.listKeyIds(), isEmpty);
      });

      test('returns stripped key IDs for ssh_key_-prefixed entries', () async {
        when(() => mockKeyStorage.readAll()).thenAnswer((_) async => {
              'ssh_key_key1': 'pem1',
              'ssh_key_key2': 'pem2',
            });
        expect(await keyManager.listKeyIds(), unorderedEquals(['key1', 'key2']));
      });

      test('filters out non-ssh_key_ entries', () async {
        when(() => mockKeyStorage.readAll()).thenAnswer((_) async => {
              'ssh_key_my-key': 'pem',
              'known_host_example.com_22': 'fingerprint',
              'some_other_entry': 'value',
            });
        expect(await keyManager.listKeyIds(), ['my-key']);
      });
    });

    group('isEncrypted()', () {
      test('returns false for an unencrypted ed25519 key', () {
        expect(keyManager.isEncrypted(_ed25519Unencrypted), isFalse);
      });

      test('returns true for a passphrase-protected ed25519 key', () {
        expect(keyManager.isEncrypted(_ed25519Encrypted), isTrue);
      });
    });

    group('parseKeyPair()', () {
      test('returns one OpenSSHEd25519KeyPair for an unencrypted ed25519 key',
          () {
        final pairs = keyManager.parseKeyPair(_ed25519Unencrypted);
        expect(pairs.length, 1);
        expect(pairs.single, isA<OpenSSHEd25519KeyPair>());
      });

      test('decrypts and returns key pair with correct passphrase', () {
        final pairs = keyManager.parseKeyPair(_ed25519Encrypted, _ed25519Passphrase);
        expect(pairs.length, 1);
        expect(pairs.single, isA<OpenSSHEd25519KeyPair>());
      });

      test('throws when passphrase is wrong for an encrypted key', () {
        expect(
          () => keyManager.parseKeyPair(_ed25519Encrypted, 'wrong-passphrase'),
          throwsA(anything),
        );
      });

      test('throws for completely invalid PEM content', () {
        expect(
          () => keyManager.parseKeyPair('not-a-pem-at-all'),
          throwsA(anything),
        );
      });
    });
  });

  // =====================================================================
  // known_hosts_store.dart
  // =====================================================================
  group('KnownHostsStore', () {
    late MockFlutterSecureStorage mockHostStorage;
    late KnownHostsStore hostStore;

    setUp(() {
      mockHostStorage = MockFlutterSecureStorage();
      hostStore = KnownHostsStore(storage: mockHostStorage);
    });

    group('computeFingerprint', () {
      test('should return consistent SHA-256 fingerprint for same input', () {
        final hostKey = Uint8List.fromList([1, 2, 3, 4, 5]);
        final fp1 = hostStore.computeFingerprint(hostKey);
        final fp2 = hostStore.computeFingerprint(hostKey);
        expect(fp1, equals(fp2));
        expect(fp1.isNotEmpty, isTrue);
      });

      test('should return different fingerprints for different keys', () {
        final key1 = Uint8List.fromList([1, 2, 3]);
        final key2 = Uint8List.fromList([4, 5, 6]);
        expect(
          hostStore.computeFingerprint(key1),
          isNot(equals(hostStore.computeFingerprint(key2))),
        );
      });
    });

    group('verify', () {
      test('returns (null, null) for unknown host', () async {
        when(() => mockHostStorage.read(key: 'known_host_example.com:22'))
            .thenAnswer((_) async => null);

        final (matched, stored) = await hostStore.verify(
          'example.com',
          22,
          Uint8List.fromList([1, 2, 3]),
        );
        expect(matched, isNull);
        expect(stored, isNull);
      });

      test('returns (true, storedFingerprint) for matching fingerprint', () async {
        final hostKey = Uint8List.fromList([1, 2, 3]);
        final fingerprint = hostStore.computeFingerprint(hostKey);

        when(() => mockHostStorage.read(key: 'known_host_example.com:22'))
            .thenAnswer((_) async => fingerprint);

        final (matched, stored) =
            await hostStore.verify('example.com', 22, hostKey);
        expect(matched, isTrue);
        expect(stored, equals(fingerprint));
      });

      test('returns (false, storedFingerprint) for mismatched fingerprint',
          () async {
        final hostKey = Uint8List.fromList([1, 2, 3]);
        const differentFp = 'different_fingerprint';

        when(() => mockHostStorage.read(key: 'known_host_example.com:22'))
            .thenAnswer((_) async => differentFp);

        final (matched, stored) =
            await hostStore.verify('example.com', 22, hostKey);
        expect(matched, isFalse);
        expect(stored, equals(differentFp));
      });
    });

    group('saveFingerprint', () {
      test('should save fingerprint to secure storage', () async {
        when(() => mockHostStorage.write(
              key: 'known_host_example.com:22',
              value: 'test_fingerprint',
            )).thenAnswer((_) async {});

        await hostStore.saveFingerprint('example.com', 22, 'test_fingerprint');

        verify(() => mockHostStorage.write(
              key: 'known_host_example.com:22',
              value: 'test_fingerprint',
            )).called(1);
      });
    });

    group('removeFingerprint', () {
      test('should delete fingerprint from secure storage', () async {
        when(() => mockHostStorage.delete(key: 'known_host_example.com:22'))
            .thenAnswer((_) async {});

        await hostStore.removeFingerprint('example.com', 22);

        verify(() => mockHostStorage.delete(key: 'known_host_example.com:22'))
            .called(1);
      });
    });

    group('non-standard port numbers', () {
      test('saveFingerprint uses correct storage key for port 2222', () async {
        when(() => mockHostStorage.write(
              key: 'known_host_myserver.internal:2222',
              value: 'fp_2222',
            )).thenAnswer((_) async {});

        await hostStore.saveFingerprint('myserver.internal', 2222, 'fp_2222');

        verify(() => mockHostStorage.write(
              key: 'known_host_myserver.internal:2222',
              value: 'fp_2222',
            )).called(1);
      });
    });
  });

  // =====================================================================
  // macos_kv_store.dart
  // =====================================================================
  group('MacosKvStore', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('macos_kv_store_test_');
      MacosKvStore.setCacheDirForTesting(tempDir);
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
      MacosKvStore.setCacheDirForTesting(
        Directory('${tempDir.path}_cleared'),
      );
    });

    group('write() / read()', () {
      test('round-trips a simple ASCII key', () async {
        await MacosKvStore.write('ssh_key_my-key', 'pem-content');
        expect(await MacosKvStore.read('ssh_key_my-key'), 'pem-content');
      });

      test('returns null for a key that was never written', () async {
        expect(await MacosKvStore.read('unknown_key'), isNull);
      });

      test('overwrites a previously written value', () async {
        await MacosKvStore.write('my_key', 'value1');
        await MacosKvStore.write('my_key', 'value2');
        expect(await MacosKvStore.read('my_key'), 'value2');
      });

      test('round-trips a key containing a colon (IPv6 host)', () async {
        const key = 'known_host_::1_22';
        await MacosKvStore.write(key, 'fingerprint');
        expect(await MacosKvStore.read(key), 'fingerprint');
      });

      test('returns null when file content is corrupted (invalid base64)',
          () async {
        final f = File(
            '/tmp/${Uri.encodeComponent('macos_kv_corrupt_key')}' +
            '_${DateTime.now().microsecondsSinceEpoch}');
        await f.writeAsString('!!!not-valid-base64!!!');
        // Use the temp dir path directly
        final fileInTemp =
            File('${tempDir.path}/${Uri.encodeComponent('corrupt_key')}');
        await fileInTemp.writeAsString('!!!not-valid-base64!!!');
        expect(await MacosKvStore.read('corrupt_key'), isNull);
      });
    });

    group('delete()', () {
      test('makes read() return null after deletion', () async {
        await MacosKvStore.write('to_delete', 'value');
        await MacosKvStore.delete('to_delete');
        expect(await MacosKvStore.read('to_delete'), isNull);
      });

      test('is a no-op when the key does not exist', () async {
        await MacosKvStore.delete('nonexistent');
      });
    });

    group('readAll()', () {
      test('returns empty map when directory has no files', () async {
        final all = await MacosKvStore.readAll();
        expect(all, isEmpty);
      });

      test('returns all written key-value pairs', () async {
        await MacosKvStore.write('key_a', 'val_a');
        await MacosKvStore.write('key_b', 'val_b');
        expect(await MacosKvStore.readAll(), {'key_a': 'val_a', 'key_b': 'val_b'});
      });
    });
  });

  // =====================================================================
  // ssh_channel_manager.dart
  // =====================================================================
  group('openExecStream command format', () {
    test('simple path produces cat with single-quoted argument', () {
      final cmd = 'cat ${shellQuote('/home/user/file.txt')}';
      expect(cmd, "cat '/home/user/file.txt'");
    });

    test('path with spaces is correctly quoted', () {
      final cmd = 'cat ${shellQuote('/home/user/my docs/file.txt')}';
      expect(cmd, "cat '/home/user/my docs/file.txt'");
    });

    test('path with single quote is escaped', () {
      final cmd = "cat ${shellQuote("/home/user/o'clock/log.txt")}";
      expect(cmd, r"cat '/home/user/o'\''clock/log.txt'");
    });

    test('path with shell metacharacters is safely quoted', () {
      final cmd = 'cat ${shellQuote('/tmp/\$(rm -rf /)/')}';
      expect(cmd, "cat '/tmp/\$(rm -rf /)/'");
    });

    test('empty path produces empty single-quoted argument', () {
      final cmd = 'cat ${shellQuote('')}';
      expect(cmd, "cat ''");
    });
  });

  group('getTmuxPaneCwd command format', () {
    String buildTmuxCmd(String sessionName) =>
        "tmux display-message -p -t ${shellQuote(sessionName)} "
        "'#{pane_current_path}' 2>/dev/null";

    test('simple session name is single-quoted', () {
      expect(
        buildTmuxCmd('main'),
        "tmux display-message -p -t 'main' '#{pane_current_path}' 2>/dev/null",
      );
    });

    test('session name with spaces is safely quoted', () {
      expect(
        buildTmuxCmd('my session'),
        "tmux display-message -p -t 'my session' '#{pane_current_path}' 2>/dev/null",
      );
    });
  });

  group('getShellCwd output validation', () {
    test('returns absolute path when output starts with /', () async {
      final stub = _StubSession('/home/user/projects');
      final manager = SshChannelManager(client: _StubClient((_) => stub));
      expect(await manager.getShellCwd(), '/home/user/projects');
    });

    test('strips trailing whitespace/newline from the path', () async {
      final stub = _StubSession('/var/log\n');
      final manager = SshChannelManager(client: _StubClient((_) => stub));
      expect(await manager.getShellCwd(), '/var/log');
    });

    test('returns null for empty output', () async {
      final stub = _StubSession('');
      final manager = SshChannelManager(client: _StubClient((_) => stub));
      expect(await manager.getShellCwd(), isNull);
    });

    test('returns null when output does not start with /', () async {
      final stub = _StubSession('relative/path');
      final manager = SshChannelManager(client: _StubClient((_) => stub));
      expect(await manager.getShellCwd(), isNull);
    });

    test('returns null when execute() throws', () async {
      final manager = SshChannelManager(client: _ThrowingClient());
      expect(await manager.getShellCwd(), isNull);
    });

    test('session.close() is called after successful read', () async {
      final stub = _StubSession('/home/user');
      final manager = SshChannelManager(client: _StubClient((_) => stub));
      await manager.getShellCwd();
      expect(stub.closeCalled, isTrue);
    });

    test('returns null when stdout stream hangs past 5-second timeout', () {
      final session = _HangingSession();
      fakeAsync((async) {
        final manager = SshChannelManager(client: _StubClient((_) => session));
        String? result;
        var done = false;
        manager.getShellCwd().then((v) {
          result = v;
          done = true;
        });
        async.elapse(const Duration(seconds: 4, milliseconds: 999));
        expect(done, isFalse);
        async.elapse(const Duration(seconds: 1));
        expect(done, isTrue);
        expect(result, isNull);
        expect(session.closeCalled, isTrue);
      });
      session.dispose();
    });
  });

  group('getTmuxPaneCwd output validation', () {
    test('returns pane path when output starts with /', () async {
      final stub = _StubSession('/home/user/work');
      final manager = SshChannelManager(client: _StubClient((_) => stub));
      expect(await manager.getTmuxPaneCwd('main'), '/home/user/work');
    });

    test('returns null for empty output', () async {
      final stub = _StubSession('');
      final manager = SshChannelManager(client: _StubClient((_) => stub));
      expect(await manager.getTmuxPaneCwd('main'), isNull);
    });
  });

  group('SshChannelManager NetworkError wrapping', () {
    test('openPtyChannel() wraps shell() exception as NetworkError', () {
      final manager = SshChannelManager(client: _ShellThrowingClient());
      expect(() => manager.openPtyChannel(), throwsA(isA<NetworkError>()));
    });

    test('executeCommand() wraps execute() exception as NetworkError', () {
      final manager = SshChannelManager(client: _ThrowingClient());
      expect(() => manager.executeCommand('echo hi'), throwsA(isA<NetworkError>()));
    });

    test('openSftpChannel() wraps sftp() exception as NetworkError', () {
      final manager = SshChannelManager(client: _SftpThrowingClient());
      expect(() => manager.openSftpChannel(), throwsA(isA<NetworkError>()));
    });

    test('dispose() does not throw when no sessions are open', () {
      final manager = SshChannelManager(client: _ThrowingClient());
      expect(manager.dispose, returnsNormally);
    });
  });

  group('SshChannelManager openSftpChannel re-open', () {
    test('previous SftpClient is closed when openSftpChannel() is called again',
        () async {
      final countingClient = _SftpCountingClient();
      final manager = SshChannelManager(client: countingClient);
      await manager.openSftpChannel();
      await manager.openSftpChannel();
      expect(countingClient.created[0].closeCalled, isTrue);
      expect(countingClient.created[1].closeCalled, isFalse);
    });
  });

  group('SshChannelManager dispose closes _ptySession', () {
    test('dispose() calls close() on _ptySession after openPtyChannel()',
        () async {
      final pty = _FakePtySession();
      final manager = SshChannelManager(client: _FakeShellClient(pty));
      await manager.openPtyChannel();
      manager.dispose();
      expect(pty.closeCalled, isTrue);
    });
  });

  group('SshChannelManager resizePty()', () {
    test('delegates width and height to resizeTerminal()', () async {
      final pty = _FakePtySession();
      final manager = SshChannelManager(client: _FakeShellClient(pty));
      await manager.openPtyChannel();
      manager.resizePty(120, 40);
      expect(pty.resizeCalls, [(120, 40)]);
    });

    test('resizePty() is a no-op when no PTY session is open', () {
      final manager = SshChannelManager(client: _ShellThrowingClient());
      expect(() => manager.resizePty(80, 24), returnsNormally);
    });

    test('resizePty() ignores zero or negative dimensions', () async {
      final pty = _FakePtySession();
      final manager = SshChannelManager(client: _FakeShellClient(pty));
      await manager.openPtyChannel();
      manager.resizePty(0, 24);
      manager.resizePty(80, 0);
      expect(pty.resizeCalls, isEmpty);
    });
  });

  group('SshChannelManager openPtyChannel dimension forwarding', () {
    test('uses default 80x24 when no dimensions specified', () async {
      final pty = _FakePtySession();
      final capturing = _CapturingShellClient(pty);
      final manager = SshChannelManager(client: capturing);
      await manager.openPtyChannel();
      expect(capturing.capturedPty?.width, 80);
      expect(capturing.capturedPty?.height, 24);
    });

    test('forwards custom dimensions to SSHPtyConfig', () async {
      final pty = _FakePtySession();
      final capturing = _CapturingShellClient(pty);
      final manager = SshChannelManager(client: capturing);
      await manager.openPtyChannel(width: 132, height: 50);
      expect(capturing.capturedPty?.width, 132);
      expect(capturing.capturedPty?.height, 50);
    });
  });
}
