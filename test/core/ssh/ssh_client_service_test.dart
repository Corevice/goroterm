import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:terminal_ssh_app/core/ssh/connection_config.dart';
import 'package:terminal_ssh_app/core/error/app_error.dart';
import 'package:terminal_ssh_app/core/ssh/known_hosts_store.dart';
import 'package:terminal_ssh_app/core/ssh/ssh_client_service.dart';

class MockKnownHostsStore extends Mock implements KnownHostsStore {}

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
}
