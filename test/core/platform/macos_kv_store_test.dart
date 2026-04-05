import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:terminal_ssh_app/core/platform/macos_kv_store.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('macos_kv_store_test_');
    MacosKvStore.setCacheDirForTesting(tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
    // Reset so subsequent test groups re-create their own directory.
    MacosKvStore.setCacheDirForTesting(
      Directory('${tempDir.path}_cleared'),
    );
  });

  // ---------------------------------------------------------------------------
  // write / read round-trip
  // ---------------------------------------------------------------------------

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

    test('returns null when file content is corrupted (invalid base64)', () async {
      // Bypass write() to inject a file with invalid base64 content, simulating
      // on-disk corruption. The catch block in read() must return null instead
      // of propagating the FormatException thrown by base64Decode.
      final f = File(p.join(tempDir.path, Uri.encodeComponent('corrupt_key')));
      await f.writeAsString('!!!not-valid-base64!!!');

      expect(await MacosKvStore.read('corrupt_key'), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // delete
  // ---------------------------------------------------------------------------

  group('delete()', () {
    test('makes read() return null after deletion', () async {
      await MacosKvStore.write('to_delete', 'value');
      await MacosKvStore.delete('to_delete');
      expect(await MacosKvStore.read('to_delete'), isNull);
    });

    test('is a no-op when the key does not exist', () async {
      // Should not throw.
      await MacosKvStore.delete('nonexistent');
    });
  });

  // ---------------------------------------------------------------------------
  // readAll — the key invariant: returned keys must equal the original keys
  // ---------------------------------------------------------------------------

  group('readAll()', () {
    test('returns empty map when directory does not exist', () async {
      // Point at a directory that was never created.
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

      expect(all.containsKey(colonKey), isTrue,
          reason: 'Colon key must survive round-trip via readAll');
      expect(all.containsKey(spaceKey), isTrue,
          reason: 'Space key must survive round-trip via readAll');
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

    test('silently skips a corrupted file and still returns valid entries', () async {
      // Write one healthy entry via the normal API.
      await MacosKvStore.write('good_key', 'good_value');

      // Inject a corrupted file alongside it.  readAll() must catch the
      // FormatException from base64Decode and skip the bad entry rather than
      // throwing or omitting the healthy one.
      final f = File(p.join(tempDir.path, Uri.encodeComponent('bad_key')));
      await f.writeAsString('!!!not-valid-base64!!!');

      final all = await MacosKvStore.readAll();

      expect(all['good_key'], 'good_value',
          reason: 'valid entry must be present after corruption in another file');
      expect(all.containsKey('bad_key'), isFalse,
          reason: 'corrupted entry must be silently skipped');
    });
  });
}
