import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_ssh_app/core/ssh/connection_config.dart';
import 'package:terminal_ssh_app/core/error/app_error.dart';

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
}
