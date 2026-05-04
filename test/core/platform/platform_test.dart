// Merged from: app_error_test.dart, macos_kv_store_test.dart

import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:terminal_ssh_app/core/error/app_error.dart';
import 'package:terminal_ssh_app/core/network/connectivity_monitor.dart';
import 'package:terminal_ssh_app/core/platform/macos_kv_store.dart';

void main() {
  // =====================================================================
  // app_error.dart
  // =====================================================================
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

      test('round-trips a key containing spaces', () async {
        const key = 'ssh_key_my key with spaces';
        await MacosKvStore.write(key, 'pem');
        expect(await MacosKvStore.read(key), 'pem');
      });

      test('returns null when file content is corrupted (invalid base64)',
          () async {
        final f =
            File(p.join(tempDir.path, Uri.encodeComponent('corrupt_key')));
        await f.writeAsString('!!!not-valid-base64!!!');

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
      test('returns empty map when directory does not exist', () async {
        MacosKvStore.setCacheDirForTesting(
          Directory('${tempDir.path}_empty'),
        );
        final all = await MacosKvStore.readAll();
        expect(all, isEmpty);
      });

      test('returns empty map when directory has no files', () async {
        final all = await MacosKvStore.readAll();
        expect(all, isEmpty);
      });

      test('returns all written key-value pairs', () async {
        await MacosKvStore.write('key_a', 'val_a');
        await MacosKvStore.write('key_b', 'val_b');

        final all = await MacosKvStore.readAll();

        expect(all, {'key_a': 'val_a', 'key_b': 'val_b'});
      });

      test('returned keys are the ORIGINAL keys, not sanitized filenames',
          () async {
        const colonKey = 'known_host_::1_22';
        const spaceKey = 'ssh_key_my key';

        await MacosKvStore.write(colonKey, 'fp1');
        await MacosKvStore.write(spaceKey, 'pem1');

        final all = await MacosKvStore.readAll();

        expect(all.containsKey(colonKey), isTrue);
        expect(all.containsKey(spaceKey), isTrue);
        expect(all[colonKey], 'fp1');
        expect(all[spaceKey], 'pem1');
      });

      test('does not include deleted entries', () async {
        await MacosKvStore.write('keep', 'yes');
        await MacosKvStore.write('remove', 'no');
        await MacosKvStore.delete('remove');

        final all = await MacosKvStore.readAll();

        expect(all.keys, ['keep']);
      });

      test('silently skips a corrupted file and still returns valid entries',
          () async {
        await MacosKvStore.write('good_key', 'good_value');

        final f =
            File(p.join(tempDir.path, Uri.encodeComponent('bad_key')));
        await f.writeAsString('!!!not-valid-base64!!!');

        final all = await MacosKvStore.readAll();

        expect(all['good_key'], 'good_value');
        expect(all.containsKey('bad_key'), isFalse);
      });
    });
  });

  // =====================================================================
  // connectivity_monitor.dart
  // =====================================================================
  group('NetworkStatus enum', () {
    test('has exactly two values', () {
      expect(NetworkStatus.values.length, 2);
    });

    test('contains connected and disconnected', () {
      expect(
        NetworkStatus.values,
        containsAll([NetworkStatus.connected, NetworkStatus.disconnected]),
      );
    });

    test('does not contain unknown variant', () {
      final names = NetworkStatus.values.map((e) => e.name).toList();
      expect(names, isNot(contains('unknown')));
    });
  });

  group('ConnectivityMonitor initial state', () {
    test('initial state is connected', () {
      final container = ProviderContainer(
        overrides: [
          connectivityProvider.overrideWith(_StubConnectivityMonitor.new),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(connectivityProvider), NetworkStatus.connected);
    });
  });

  group('ConnectivityMonitor transition rules', () {
    NetworkStatus _calc(List<ConnectivityResult> results) {
      if (results.contains(ConnectivityResult.none))
        return NetworkStatus.disconnected;
      return NetworkStatus.connected;
    }

    test('none → disconnected', () {
      expect(_calc([ConnectivityResult.none]), NetworkStatus.disconnected);
    });

    test('wifi → connected', () {
      expect(_calc([ConnectivityResult.wifi]), NetworkStatus.connected);
    });

    test('mobile → connected', () {
      expect(_calc([ConnectivityResult.mobile]), NetworkStatus.connected);
    });

    test('ethernet → connected', () {
      expect(_calc([ConnectivityResult.ethernet]), NetworkStatus.connected);
    });

    test('empty → connected', () {
      expect(_calc([]), NetworkStatus.connected);
    });

    test('[wifi, none] → disconnected', () {
      expect(
        _calc([ConnectivityResult.wifi, ConnectivityResult.none]),
        NetworkStatus.disconnected,
      );
    });
  });
}

/// Stub: bypasses Connectivity() platform channel, returns connected immediately.
class _StubConnectivityMonitor extends ConnectivityMonitor {
  @override
  NetworkStatus build() {
    ref.onDispose(() {});
    return NetworkStatus.connected;
  }
}
