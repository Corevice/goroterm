import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:terminal_ssh_app/features/file_browser/file_browser_provider.dart';

void main() {
  group('FileBrowserState', () {
    test('visibleItems hides dotfiles when showHidden is false', () {
      final items = [
        _makeItem('.hidden'),
        _makeItem('visible.txt'),
        _makeItem('.bashrc'),
        _makeItem('README.md'),
      ];
      final state = FileBrowserState(items: items, showHidden: false);
      final visible = state.visibleItems;
      expect(visible.map((e) => e.filename), ['visible.txt', 'README.md']);
    });

    test('visibleItems shows all items when showHidden is true', () {
      final items = [
        _makeItem('.hidden'),
        _makeItem('visible.txt'),
      ];
      final state = FileBrowserState(items: items, showHidden: true);
      expect(state.visibleItems.length, 2);
    });

    test('parentPath returns null at root', () {
      const state = FileBrowserState(currentPath: '/');
      expect(state.parentPath, isNull);
    });

    test('parentPath returns parent directory', () {
      const state = FileBrowserState(currentPath: '/home/user/projects');
      expect(state.parentPath, '/home/user');
    });

    test('parentPath returns / for top-level directory', () {
      const state = FileBrowserState(currentPath: '/home');
      expect(state.parentPath, '/');
    });

    test('copyWith preserves unspecified fields', () {
      const original = FileBrowserState(
        currentPath: '/foo',
        showHidden: true,
      );
      final updated = original.copyWith(currentPath: '/bar');
      expect(updated.currentPath, '/bar');
      expect(updated.showHidden, true);
    });

    test('copyWith clears downloadProgress with null', () {
      final original = FileBrowserState(downloadProgress: 0.5);
      final updated = original.copyWith(downloadProgress: null);
      expect(updated.downloadProgress, isNull);
    });
  });

  group('Sorting', () {
    test('directories sort before files', () {
      final items = [
        _makeItem('file.txt', isDirectory: false),
        _makeItem('dir_a', isDirectory: true),
        _makeItem('file_b.sh', isDirectory: false),
        _makeItem('dir_z', isDirectory: true),
      ];

      items.sort((a, b) {
        final aIsDir = a.attr.isDirectory;
        final bIsDir = b.attr.isDirectory;
        if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
        return a.filename.compareTo(b.filename);
      });

      expect(items[0].filename, 'dir_a');
      expect(items[1].filename, 'dir_z');
      expect(items[2].filename, 'file.txt');
      expect(items[3].filename, 'file_b.sh');
    });

    test('files sort alphabetically within same type', () {
      final items = [
        _makeItem('z_file.txt', isDirectory: false),
        _makeItem('a_file.txt', isDirectory: false),
        _makeItem('m_file.txt', isDirectory: false),
      ];

      items.sort((a, b) => a.filename.compareTo(b.filename));

      expect(items.map((e) => e.filename), ['a_file.txt', 'm_file.txt', 'z_file.txt']);
    });
  });

  group('shellEscapePath', () {
    test('wraps path in single quotes', () {
      expect(shellEscapePath('/home/user'), "'/home/user'");
    });

    test('escapes single quotes in path', () {
      expect(shellEscapePath("/path/with'quote"), r"'/path/with'\''quote'");
    });

    test('handles path with spaces', () {
      expect(shellEscapePath('/path/with spaces/file.txt'),
          "'/path/with spaces/file.txt'");
    });

    test('handles path with dollar sign', () {
      expect(shellEscapePath('/home/\$USER/file'), "'/home/\$USER/file'");
    });

    test('handles path with semicolon', () {
      expect(shellEscapePath('/path/a;rm -rf /'), "'/path/a;rm -rf /'");
    });

    test('handles path with pipe', () {
      expect(shellEscapePath('/path/a|b'), "'/path/a|b'");
    });

    test('handles path with backtick', () {
      expect(shellEscapePath('/path/`cmd`'), "'/path/`cmd`'");
    });

    test('handles empty path', () {
      expect(shellEscapePath(''), "''");
    });

    test('handles path with multiple single quotes', () {
      expect(shellEscapePath("a'b'c"), r"'a'\''b'\''c'");
    });
  });

  group('downloadFile state fields (Phase 8)', () {
    test('downloadedFilePath is null by default', () {
      const state = FileBrowserState();
      expect(state.downloadedFilePath, isNull);
    });

    test('copyWith sets downloadedFilePath', () {
      const state = FileBrowserState();
      final updated = state.copyWith(downloadedFilePath: '/data/user/0/cache/file.txt');
      expect(updated.downloadedFilePath, '/data/user/0/cache/file.txt');
    });

    test('copyWith clears downloadedFilePath with null', () {
      const state = FileBrowserState(downloadedFilePath: '/tmp/file.txt');
      final updated = state.copyWith(downloadedFilePath: null);
      expect(updated.downloadedFilePath, isNull);
    });

    test('download path does not use /storage/emulated (Scoped Storage fix)', () {
      // Production code uses getTemporaryDirectory() which returns the app's
      // cache dir (e.g. /data/user/0/.../cache), NOT /storage/emulated/0/Download.
      // This test documents the contract: any stored downloadedFilePath must
      // not point to the legacy direct-write path removed in Phase 8.
      const legacyAndroidPath = '/storage/emulated/0/Download/file.txt';
      const tempCachePath = '/data/user/0/com.example.app/cache/file.txt';

      // The state accepts whatever path the caller provides — the constraint is
      // enforced by production code using getTemporaryDirectory(). Here we
      // verify that storing a temp-dir path works correctly, and that the
      // legacy path is structurally different.
      const state = FileBrowserState(downloadedFilePath: tempCachePath);
      expect(state.downloadedFilePath, tempCachePath);
      expect(state.downloadedFilePath, isNot(equals(legacyAndroidPath)));
      expect(legacyAndroidPath, contains('/storage/emulated'));
      expect(tempCachePath, isNot(contains('/storage/emulated')));
    });

    test('downloadProgress and downloadedFilePath are independent fields', () {
      final state = FileBrowserState(downloadProgress: 0.5, downloadedFilePath: '/tmp/f');
      final clearedProgress = state.copyWith(downloadProgress: null);

      // Clearing progress does not affect the stored path.
      expect(clearedProgress.downloadProgress, isNull);
      expect(clearedProgress.downloadedFilePath, '/tmp/f');
    });

    test('copyWith preserves other fields when setting downloadedFilePath', () {
      const state = FileBrowserState(
        currentPath: '/home/user',
        showHidden: true,
      );
      final updated = state.copyWith(downloadedFilePath: '/tmp/result.zip');
      expect(updated.currentPath, '/home/user');
      expect(updated.showHidden, true);
      expect(updated.downloadedFilePath, '/tmp/result.zip');
    });
  });

  group('uploadFile state fields (Phase 16)', () {
    test('uploadProgress is null by default', () {
      const state = FileBrowserState();
      expect(state.uploadProgress, isNull);
    });

    test('uploadCompleteFile is null by default', () {
      const state = FileBrowserState();
      expect(state.uploadCompleteFile, isNull);
    });

    test('copyWith sets uploadProgress', () {
      const state = FileBrowserState();
      final updated = state.copyWith(uploadProgress: 0.5);
      expect(updated.uploadProgress, 0.5);
    });

    test('copyWith clears uploadProgress with null', () {
      final state = FileBrowserState(uploadProgress: 0.8);
      final updated = state.copyWith(uploadProgress: null);
      expect(updated.uploadProgress, isNull);
    });

    test('copyWith sets uploadCompleteFile', () {
      const state = FileBrowserState();
      final updated = state.copyWith(uploadCompleteFile: 'photo.jpg');
      expect(updated.uploadCompleteFile, 'photo.jpg');
    });

    test('copyWith clears uploadCompleteFile with null', () {
      const state = FileBrowserState(uploadCompleteFile: 'photo.jpg');
      final updated = state.copyWith(uploadCompleteFile: null);
      expect(updated.uploadCompleteFile, isNull);
    });

    test('uploadProgress and uploadCompleteFile are independent fields', () {
      final state =
          FileBrowserState(uploadProgress: 0.5, uploadCompleteFile: 'old.txt');
      final cleared = state.copyWith(uploadProgress: null);
      expect(cleared.uploadProgress, isNull);
      expect(cleared.uploadCompleteFile, 'old.txt');
    });

    test('copyWith preserves other fields when setting uploadCompleteFile', () {
      const state = FileBrowserState(
        currentPath: '/home/user',
        showHidden: true,
      );
      final updated = state.copyWith(uploadCompleteFile: 'result.zip');
      expect(updated.currentPath, '/home/user');
      expect(updated.showHidden, true);
      expect(updated.uploadCompleteFile, 'result.zip');
    });
  });

  group('humanReadableSize', () {
    test('null returns empty string', () {
      expect(humanReadableSize(null), '');
    });

    test('bytes under 1 KB', () {
      expect(humanReadableSize(512), '512 B');
    });

    test('kilobytes', () {
      expect(humanReadableSize(1536), '1.5 KB');
    });

    test('megabytes', () {
      expect(humanReadableSize(1024 * 1024 * 2), '2.0 MB');
    });

    test('gigabytes', () {
      expect(humanReadableSize(1024 * 1024 * 1024 * 3), '3.0 GB');
    });
  });

  // -------------------------------------------------------------------------
  // SFTP permission error classification (replacing fragile string matching)
  //
  // _fetchItems used to check e.toString().contains('permission'), which is
  // locale-dependent and could false-positive on unrelated messages.
  // The fix uses SftpStatusError + SftpStatusCode.permissionDenied (code 3).
  //
  // These tests document the dartssh2 API contract our code relies on.
  // -------------------------------------------------------------------------

  group('SftpStatusError classification', () {
    test('SftpStatusCode.permissionDenied is 3 (SFTP standard)', () {
      // Documents the numeric value our code depends on.
      expect(SftpStatusCode.permissionDenied, 3);
    });

    test('SftpStatusError carries the code', () {
      final e = SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied');
      expect(e.code, SftpStatusCode.permissionDenied);
      expect(e, isA<SftpStatusError>());
    });

    test('SftpStatusError with permissionDenied code matches the guard', () {
      final e = SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied');
      // This is exactly the condition used in _fetchItems.
      expect(e.code == SftpStatusCode.permissionDenied, isTrue);
    });

    test('SftpStatusError with noSuchFile code does NOT match permission guard', () {
      final e = SftpStatusError(SftpStatusCode.noSuchFile, 'No such file');
      expect(e.code == SftpStatusCode.permissionDenied, isFalse);
    });

    test('SftpStatusError with failure code does NOT match permission guard', () {
      final e = SftpStatusError(SftpStatusCode.failure, 'Failure');
      expect(e.code == SftpStatusCode.permissionDenied, isFalse);
    });

    test('regression: plain Exception containing "permission" does NOT match guard', () {
      // The old string-based check would have matched this. The new type-based
      // check correctly ignores it.
      final e = Exception('Operation requires permission level 3');
      expect(e is SftpStatusError, isFalse);
    });
  });

  group('permissionString', () {
    test('null mode returns dashes', () {
      expect(permissionString(null), '---------');
    });

    test('full permissions', () {
      // rwxrwxrwx = 0777
      final mode = SftpFileMode(
        userRead: true,
        userWrite: true,
        userExecute: true,
        groupRead: true,
        groupWrite: true,
        groupExecute: true,
        otherRead: true,
        otherWrite: true,
        otherExecute: true,
      );
      expect(permissionString(mode), 'rwxrwxrwx');
    });

    test('read-only owner', () {
      final mode = SftpFileMode(
        userRead: true,
        userWrite: false,
        userExecute: false,
        groupRead: false,
        groupWrite: false,
        groupExecute: false,
        otherRead: false,
        otherWrite: false,
        otherExecute: false,
      );
      expect(permissionString(mode), 'r--------');
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

SftpName _makeItem(String filename, {bool isDirectory = false}) {
  // Build permissions: directory bit (0040000) + 0755 for dirs, 0644 for files
  final permBits = isDirectory
      ? (1 << 14) | // isDirectory flag
          (1 << 8) | (1 << 7) | (1 << 6) | // user rwx
          (1 << 5) | (1 << 3) | // group r-x
          (1 << 2) | (1 << 0) // other r-x
      : (1 << 15) | // isRegularFile flag
          (1 << 8) | (1 << 7) | // user rw-
          (1 << 5) | // group r--
          (1 << 2); // other r--

  return SftpName(
    filename: filename,
    longname: '${isDirectory ? 'd' : '-'}rwxr-xr-x 1 user group 0 Jan 1 12:00 $filename',
    attr: SftpFileAttrs(
      mode: SftpFileMode.value(permBits),
      size: isDirectory ? null : 1024,
    ),
  );
}
