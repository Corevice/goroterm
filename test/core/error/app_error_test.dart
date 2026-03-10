import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_ssh_app/core/error/app_error.dart';

void main() {
  group('AppError', () {
    test('AuthenticationError has message and is AppError/Exception', () {
      const e = AuthenticationError('bad password');
      expect(e.message, 'bad password');
      expect(e, isA<AppError>());
      expect(e, isA<Exception>());
      expect(e.toString(), contains('AuthenticationError'));
      expect(e.toString(), contains('bad password'));
    });

    test('HostKeyError has message and fingerprint', () {
      const e = HostKeyError('key mismatch', fingerprint: 'abc123==');
      expect(e.message, 'key mismatch');
      expect(e.fingerprint, 'abc123==');
      expect(e, isA<AppError>());
      expect(e.toString(), contains('HostKeyError'));
    });

    test('NetworkError has message', () {
      const e = NetworkError('connection timed out');
      expect(e.message, 'connection timed out');
      expect(e, isA<AppError>());
      expect(e.toString(), contains('NetworkError'));
    });

    test('PermissionError has message', () {
      const e = PermissionError('permission denied: /etc/shadow');
      expect(e.message, 'permission denied: /etc/shadow');
      expect(e, isA<AppError>());
      expect(e.toString(), contains('PermissionError'));
    });

    group('TmuxError', () {
      test('defaults to unknown reason', () {
        const e = TmuxError('tmux error');
        expect(e.message, 'tmux error');
        expect(e.reason, TmuxErrorReason.unknown);
        expect(e, isA<AppError>());
      });

      test('notInstalled reason', () {
        const e = TmuxError('not found', reason: TmuxErrorReason.notInstalled);
        expect(e.reason, TmuxErrorReason.notInstalled);
      });

      test('sessionNotFound reason', () {
        const e = TmuxError(
          'session gone',
          reason: TmuxErrorReason.sessionNotFound,
        );
        expect(e.reason, TmuxErrorReason.sessionNotFound);
        expect(e.toString(), contains('TmuxError'));
      });

      test('TmuxErrorReason covers all enum values', () {
        expect(TmuxErrorReason.values.length, 3);
        expect(
          TmuxErrorReason.values,
          containsAll([
            TmuxErrorReason.notInstalled,
            TmuxErrorReason.sessionNotFound,
            TmuxErrorReason.unknown,
          ]),
        );
      });
    });

    test('all subtypes are AppError', () {
      final errors = <AppError>[
        const AuthenticationError('x'),
        const HostKeyError('x', fingerprint: 'y'),
        const NetworkError('x'),
        const PermissionError('x'),
        const TmuxError('x'),
      ];
      for (final e in errors) {
        expect(e, isA<AppError>());
        expect(e, isA<Exception>());
        expect(e.toString(), isNotEmpty);
      }
    });
  });
}
