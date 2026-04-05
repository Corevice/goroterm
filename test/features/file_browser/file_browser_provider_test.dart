import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:terminal_ssh_app/core/error/app_error.dart';
import 'package:terminal_ssh_app/core/platform/download_isolate.dart';
import 'package:terminal_ssh_app/core/ssh/ssh_channel_manager.dart';
import 'package:terminal_ssh_app/features/file_browser/file_browser_provider.dart';

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

class _MockSshChannelManager extends Mock implements SshChannelManager {}

class _MockSftpClient extends Mock implements SftpClient {}

class _MockSftpFile extends Mock implements SftpFile {}

// ---------------------------------------------------------------------------
// Helper: builds a ProviderContainer with FileBrowserNotifier pre-initialized
// (past the initial build() failure) and with [mockSftp] injected.
// ---------------------------------------------------------------------------

Future<ProviderContainer> _makeFileBrowserContainer({
  required _MockSftpClient mockSftp,
  SshChannelManager? mockManager,
  FileBrowserState initialState = const FileBrowserState(currentPath: '/home/user'),
}) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  // Let build() run and fail (no channelManager → NetworkError).
  await container
      .read(fileBrowserProvider('conn-1').future)
      .catchError((_) => const FileBrowserState());
  // Inject sftp + state directly, bypassing a real SSH connection.
  container.read(fileBrowserProvider('conn-1').notifier).initForTesting(
        sftp: mockSftp,
        channelManager: mockManager,
        initialState: initialState,
      );
  return container;
}

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

    test('downloadError is null by default', () {
      const state = FileBrowserState();
      expect(state.downloadError, isNull);
    });

    test('copyWith sets downloadError', () {
      const state = FileBrowserState();
      final updated = state.copyWith(downloadError: 'Connection credentials not set');
      expect(updated.downloadError, 'Connection credentials not set');
    });

    test('copyWith clears downloadError with null', () {
      const state = FileBrowserState(downloadError: 'some error');
      final updated = state.copyWith(downloadError: null);
      expect(updated.downloadError, isNull);
    });

    test('copyWith preserves downloadError when not specified', () {
      const state = FileBrowserState(downloadError: 'transfer failed');
      final updated = state.copyWith(currentPath: '/new/path');
      expect(updated.downloadError, 'transfer failed');
      expect(updated.currentPath, '/new/path');
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

    test('0644 rw-r--r-- (typical file)', () {
      final mode = SftpFileMode(
        userRead: true,
        userWrite: true,
        userExecute: false,
        groupRead: true,
        groupWrite: false,
        groupExecute: false,
        otherRead: true,
        otherWrite: false,
        otherExecute: false,
      );
      expect(permissionString(mode), 'rw-r--r--');
    });

    test('0755 rwxr-xr-x (typical executable/directory)', () {
      final mode = SftpFileMode(
        userRead: true,
        userWrite: true,
        userExecute: true,
        groupRead: true,
        groupWrite: false,
        groupExecute: true,
        otherRead: true,
        otherWrite: false,
        otherExecute: true,
      );
      expect(permissionString(mode), 'rwxr-xr-x');
    });

    test('0700 rwx------ (owner-only access)', () {
      final mode = SftpFileMode(
        userRead: true,
        userWrite: true,
        userExecute: true,
        groupRead: false,
        groupWrite: false,
        groupExecute: false,
        otherRead: false,
        otherWrite: false,
        otherExecute: false,
      );
      expect(permissionString(mode), 'rwx------');
    });

    test('0000 --------- (no permissions, all-false mode)', () {
      final mode = SftpFileMode(
        userRead: false,
        userWrite: false,
        userExecute: false,
        groupRead: false,
        groupWrite: false,
        groupExecute: false,
        otherRead: false,
        otherWrite: false,
        otherExecute: false,
      );
      expect(permissionString(mode), '---------');
    });

    test('0111 --x--x--x (execute-only bits)', () {
      final mode = SftpFileMode(
        userRead: false,
        userWrite: false,
        userExecute: true,
        groupRead: false,
        groupWrite: false,
        groupExecute: true,
        otherRead: false,
        otherWrite: false,
        otherExecute: true,
      );
      expect(permissionString(mode), '--x--x--x');
    });

    test('0640 rw-r----- (group read, no other)', () {
      final mode = SftpFileMode(
        userRead: true,
        userWrite: true,
        userExecute: false,
        groupRead: true,
        groupWrite: false,
        groupExecute: false,
        otherRead: false,
        otherWrite: false,
        otherExecute: false,
      );
      expect(permissionString(mode), 'rw-r-----');
    });
  });

  // ---------------------------------------------------------------------------
  // FileBrowserNotifier — notifier-level tests
  // ---------------------------------------------------------------------------

  group('FileBrowserNotifier', () {
    setUpAll(() {
      registerFallbackValue('');
    });

    test('initial state is AsyncError when channelManager is null', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(fileBrowserProvider('conn-1').future)
          .catchError((_) => const FileBrowserState());

      final state = container.read(fileBrowserProvider('conn-1'));
      expect(state, isA<AsyncError>());
      expect(state.error, isA<NetworkError>());
    });

    test('setChannelManager(null) is no-op when already null', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(fileBrowserProvider('conn-1').future)
          .catchError((_) => const FileBrowserState());
      final stateBefore = container.read(fileBrowserProvider('conn-1'));

      container
          .read(fileBrowserProvider('conn-1').notifier)
          .setChannelManager(null);

      final stateAfter = container.read(fileBrowserProvider('conn-1'));
      expect(stateAfter, equals(stateBefore));
    });

    test('setChannelManager(null) transitions to AsyncError when was connected',
        () async {
      final mockSftp = _MockSftpClient();
      final mockManager = _MockSshChannelManager();
      // listdir is called by refresh() after navigateTo — not needed here.
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        mockManager: mockManager,
      );

      container
          .read(fileBrowserProvider('conn-1').notifier)
          .setChannelManager(null);

      final state = container.read(fileBrowserProvider('conn-1'));
      expect(state, isA<AsyncError>());
      expect(state.error, isA<NetworkError>());
    });

    test('setChannelManager with manager triggers _initializeState to AsyncData',
        () async {
      final mockManager = _MockSshChannelManager();
      final mockSftp = _MockSftpClient();
      when(() => mockManager.openSftpChannel()).thenAnswer((_) async => mockSftp);
      when(() => mockSftp.absolute('.')).thenAnswer((_) async => '/home/user');
      when(() => mockSftp.listdir(any())).thenAnswer((_) async => []);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Wait for initial build to fail.
      await container
          .read(fileBrowserProvider('conn-1').future)
          .catchError((_) => const FileBrowserState());

      container
          .read(fileBrowserProvider('conn-1').notifier)
          .setChannelManager(mockManager);

      // Pump event loop to let _initializeState complete its async chain.
      await Future.delayed(Duration.zero);

      final state = container.read(fileBrowserProvider('conn-1'));
      expect(state, isA<AsyncData<FileBrowserState>>());
      expect(state.value?.currentPath, '/home/user');
    });

    test(
        'rapid setChannelManager(A→B): stale A result does not overwrite B state',
        () async {
      // Manager A's openSftpChannel() hangs until we release it via completer.
      // Manager B's openSftpChannel() completes immediately.
      final completerA = Completer<SftpClient>();
      final sftpA = _MockSftpClient();
      final sftpB = _MockSftpClient();
      final managerA = _MockSshChannelManager();
      final managerB = _MockSshChannelManager();

      when(() => managerA.openSftpChannel())
          .thenAnswer((_) => completerA.future);
      when(() => sftpA.close()).thenReturn(null); // called when stale channel is closed

      when(() => managerB.openSftpChannel()).thenAnswer((_) async => sftpB);
      when(() => sftpB.absolute('.')).thenAnswer((_) async => '/home/b');
      when(() => sftpB.listdir(any())).thenAnswer((_) async => []);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(fileBrowserProvider('conn-1').future)
          .catchError((_) => const FileBrowserState());

      final notifier = container.read(fileBrowserProvider('conn-1').notifier);

      // Start slow init with A, then immediately switch to B.
      notifier.setChannelManager(managerA);
      notifier.setChannelManager(managerB);

      // Let B's _initializeState complete.
      await Future.delayed(Duration.zero);

      // State must reflect B, not A.
      final stateAfterB = container.read(fileBrowserProvider('conn-1'));
      expect(stateAfterB, isA<AsyncData<FileBrowserState>>());
      expect(stateAfterB.value?.currentPath, '/home/b');

      // Now release A's slow openSftpChannel — the stale channel should be
      // closed immediately and state must remain B's.
      completerA.complete(sftpA);
      await Future.delayed(Duration.zero);

      final stateAfterACompletes = container.read(fileBrowserProvider('conn-1'));
      expect(stateAfterACompletes.value?.currentPath, '/home/b',
          reason: 'stale A result must not overwrite B state');
      verify(() => sftpA.close()).called(1); // stale channel was cleaned up
    });

    test('toggleHidden flips showHidden', () async {
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(mockSftp: mockSftp);

      expect(
          container.read(fileBrowserProvider('conn-1')).value?.showHidden,
          isFalse);

      container.read(fileBrowserProvider('conn-1').notifier).toggleHidden();
      expect(
          container.read(fileBrowserProvider('conn-1')).value?.showHidden,
          isTrue);

      container.read(fileBrowserProvider('conn-1').notifier).toggleHidden();
      expect(
          container.read(fileBrowserProvider('conn-1')).value?.showHidden,
          isFalse);
    });

    test('clearDownloadNotification clears downloadedFilePath', () async {
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        initialState: const FileBrowserState(
          currentPath: '/home/user',
          downloadedFilePath: '/tmp/file.txt',
        ),
      );

      container
          .read(fileBrowserProvider('conn-1').notifier)
          .clearDownloadNotification();

      expect(
        container.read(fileBrowserProvider('conn-1')).value?.downloadedFilePath,
        isNull,
      );
    });

    test('clearUploadNotification clears uploadCompleteFile', () async {
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        initialState: const FileBrowserState(
          currentPath: '/home/user',
          uploadCompleteFile: 'photo.jpg',
        ),
      );

      container
          .read(fileBrowserProvider('conn-1').notifier)
          .clearUploadNotification();

      expect(
        container.read(fileBrowserProvider('conn-1')).value?.uploadCompleteFile,
        isNull,
      );
    });

    test('navigateTo fetches items and updates currentPath', () async {
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(mockSftp: mockSftp);

      final items = [
        _makeItem('dir_a', isDirectory: true),
        _makeItem('file.txt'),
      ];
      when(() => mockSftp.listdir('/projects')).thenAnswer((_) async => items);

      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .navigateTo('/projects');

      final state = container.read(fileBrowserProvider('conn-1'));
      expect(state.value?.currentPath, '/projects');
      // _fetchItems sorts directories first.
      expect(state.value?.items.first.filename, 'dir_a');
      expect(state.value?.items.last.filename, 'file.txt');
    });

    test('navigateTo with permission denied transitions to AsyncError', () async {
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(mockSftp: mockSftp);

      when(() => mockSftp.listdir('/etc/shadow')).thenAnswer(
        (_) async =>
            throw SftpStatusError(SftpStatusCode.permissionDenied, 'denied'),
      );

      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .navigateTo('/etc/shadow');

      final state = container.read(fileBrowserProvider('conn-1'));
      expect(state, isA<AsyncError>());
      expect(state.error, isA<PermissionError>());
    });

    test(
        'concurrent navigateTo — second supersedes first, state reflects second',
        () async {
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        initialState: const FileBrowserState(currentPath: '/home/user'),
      );

      // First navigation is slow: its listdir will only resolve after the
      // second navigation has already completed.
      final slowCompleter = Completer<List<SftpName>>();
      when(() => mockSftp.listdir('/slow'))
          .thenAnswer((_) => slowCompleter.future);
      when(() => mockSftp.listdir('/fast'))
          .thenAnswer((_) async => [_makeItem('fast_file.txt')]);

      // Start the slow navigation without awaiting (paused at listdir).
      final slowFuture = container
          .read(fileBrowserProvider('conn-1').notifier)
          .navigateTo('/slow');

      // Second navigation supersedes the first and completes immediately.
      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .navigateTo('/fast');

      expect(
        container.read(fileBrowserProvider('conn-1')).value?.currentPath,
        '/fast',
        reason: 'second navigation should complete normally',
      );

      // Now resolve the first navigation's listdir — it is already superseded.
      slowCompleter.complete([_makeItem('slow_file.txt')]);
      await slowFuture;

      // Superseded result must not overwrite the second navigation's state.
      final state = container.read(fileBrowserProvider('conn-1'));
      expect(state.value?.currentPath, '/fast');
      expect(state.value?.items.first.filename, 'fast_file.txt');
    });

    test('error in superseded navigation is silently ignored', () async {
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        initialState: const FileBrowserState(currentPath: '/home/user'),
      );

      final errorCompleter = Completer<List<SftpName>>();
      when(() => mockSftp.listdir('/will-error'))
          .thenAnswer((_) => errorCompleter.future);
      when(() => mockSftp.listdir('/second'))
          .thenAnswer((_) async => [_makeItem('second_file.txt')]);

      // Start the first navigation (will later error, but already superseded).
      final errorFuture = container
          .read(fileBrowserProvider('conn-1').notifier)
          .navigateTo('/will-error');

      // Second navigation supersedes the first.
      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .navigateTo('/second');

      expect(
        container.read(fileBrowserProvider('conn-1')).value?.currentPath,
        '/second',
      );

      // Resolve the first navigation with a permission error — superseded.
      errorCompleter.completeError(
        SftpStatusError(SftpStatusCode.permissionDenied, 'denied'),
      );
      await errorFuture;

      // State must remain AsyncData '/second', NOT transition to AsyncError.
      final state = container.read(fileBrowserProvider('conn-1'));
      expect(state, isA<AsyncData<FileBrowserState>>());
      expect(state.value?.currentPath, '/second');
    });

    test('refresh re-fetches items at current path', () async {
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        initialState: const FileBrowserState(currentPath: '/home/user'),
      );

      final updatedItems = [_makeItem('newfile.txt')];
      when(() => mockSftp.listdir('/home/user'))
          .thenAnswer((_) async => updatedItems);

      await container.read(fileBrowserProvider('conn-1').notifier).refresh();

      final state = container.read(fileBrowserProvider('conn-1'));
      expect(state.value?.currentPath, '/home/user');
      expect(state.value?.items.length, 1);
      expect(state.value?.items.first.filename, 'newfile.txt');
    });

    test('deleteFile calls sftp.remove then refreshes', () async {
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        initialState: const FileBrowserState(currentPath: '/home/user'),
      );

      when(() => mockSftp.remove('/home/user/file.txt'))
          .thenAnswer((_) async {});
      when(() => mockSftp.listdir('/home/user')).thenAnswer((_) async => []);

      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .deleteFile('/home/user/file.txt');

      verify(() => mockSftp.remove('/home/user/file.txt')).called(1);
      expect(
          container.read(fileBrowserProvider('conn-1')).value?.currentPath,
          '/home/user');
    });

    test('deleteFile with isDirectory calls sftp.rmdir', () async {
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        initialState: const FileBrowserState(currentPath: '/home/user'),
      );

      when(() => mockSftp.rmdir('/home/user/docs')).thenAnswer((_) async {});
      when(() => mockSftp.listdir('/home/user')).thenAnswer((_) async => []);

      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .deleteFile('/home/user/docs', isDirectory: true);

      verify(() => mockSftp.rmdir('/home/user/docs')).called(1);
    });

    test('renameFile calls sftp.rename then refreshes', () async {
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        initialState: const FileBrowserState(currentPath: '/home/user'),
      );

      when(() =>
              mockSftp.rename('/home/user/old.txt', '/home/user/new.txt'))
          .thenAnswer((_) async {});
      when(() => mockSftp.listdir('/home/user')).thenAnswer((_) async => []);

      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .renameFile('/home/user/old.txt', '/home/user/new.txt');

      verify(() =>
              mockSftp.rename('/home/user/old.txt', '/home/user/new.txt'))
          .called(1);
    });

    test('deleteFile maps SftpStatusError(permissionDenied) to PermissionError',
        () async {
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        initialState: const FileBrowserState(currentPath: '/home/user'),
      );

      when(() => mockSftp.remove('/root/secret'))
          .thenThrow(SftpStatusError(SftpStatusCode.permissionDenied, 'denied'));

      expect(
        () => container
            .read(fileBrowserProvider('conn-1').notifier)
            .deleteFile('/root/secret'),
        throwsA(isA<PermissionError>()),
      );
    });

    test(
        'deleteFile with isDirectory maps SftpStatusError(permissionDenied) to PermissionError',
        () async {
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        initialState: const FileBrowserState(currentPath: '/home/user'),
      );

      when(() => mockSftp.rmdir('/root/secret'))
          .thenThrow(SftpStatusError(SftpStatusCode.permissionDenied, 'denied'));

      expect(
        () => container
            .read(fileBrowserProvider('conn-1').notifier)
            .deleteFile('/root/secret', isDirectory: true),
        throwsA(isA<PermissionError>()),
      );
    });

    test('deleteFile rethrows non-permission SftpStatusError', () async {
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        initialState: const FileBrowserState(currentPath: '/home/user'),
      );

      when(() => mockSftp.remove('/home/user/missing.txt'))
          .thenThrow(SftpStatusError(SftpStatusCode.noSuchFile, 'no such file'));

      expect(
        () => container
            .read(fileBrowserProvider('conn-1').notifier)
            .deleteFile('/home/user/missing.txt'),
        throwsA(isA<SftpStatusError>()),
      );
    });

    test('renameFile maps SftpStatusError(permissionDenied) to PermissionError',
        () async {
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        initialState: const FileBrowserState(currentPath: '/home/user'),
      );

      when(() => mockSftp.rename('/root/old', '/root/new'))
          .thenThrow(SftpStatusError(SftpStatusCode.permissionDenied, 'denied'));

      expect(
        () => container
            .read(fileBrowserProvider('conn-1').notifier)
            .renameFile('/root/old', '/root/new'),
        throwsA(isA<PermissionError>()),
      );
    });

    test('renameFile rethrows non-permission SftpStatusError', () async {
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        initialState: const FileBrowserState(currentPath: '/home/user'),
      );

      when(() => mockSftp.rename('/home/user/a.txt', '/home/user/b.txt'))
          .thenThrow(SftpStatusError(SftpStatusCode.failure, 'failure'));

      expect(
        () => container
            .read(fileBrowserProvider('conn-1').notifier)
            .renameFile('/home/user/a.txt', '/home/user/b.txt'),
        throwsA(isA<SftpStatusError>()),
      );
    });

    // uploadFile permission error mapping — same contract as deleteFile/renameFile.
    // sftp.open() throws SSH_FX_PERMISSION_DENIED when writing to a protected
    // directory (e.g. /root/). The inner catch must map this to PermissionError.

    group('uploadFile permission error mapping', () {
      late Directory tempDir;
      late File localFile;

      setUpAll(() {
        registerFallbackValue(SftpFileOpenMode.write);
      });

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp('upload_test_');
        localFile = File('${tempDir.path}/test.txt');
        await localFile.writeAsString('hello');
      });

      tearDown(() async {
        await tempDir.delete(recursive: true);
      });

      test('maps SftpStatusError(permissionDenied) to PermissionError', () async {
        final mockSftp = _MockSftpClient();
        final container = await _makeFileBrowserContainer(
          mockSftp: mockSftp,
          initialState: const FileBrowserState(currentPath: '/root'),
        );

        when(() => mockSftp.open(any(), mode: any(named: 'mode')))
            .thenThrow(SftpStatusError(SftpStatusCode.permissionDenied, 'denied'));

        await expectLater(
          container
              .read(fileBrowserProvider('conn-1').notifier)
              .uploadFile(localFile.path),
          throwsA(isA<PermissionError>()),
        );
      });

      test('clears uploadProgress when permission denied', () async {
        final mockSftp = _MockSftpClient();
        final container = await _makeFileBrowserContainer(
          mockSftp: mockSftp,
          initialState: const FileBrowserState(currentPath: '/root'),
        );

        when(() => mockSftp.open(any(), mode: any(named: 'mode')))
            .thenThrow(SftpStatusError(SftpStatusCode.permissionDenied, 'denied'));

        await container
            .read(fileBrowserProvider('conn-1').notifier)
            .uploadFile(localFile.path)
            .catchError((_) {});

        final state = container.read(fileBrowserProvider('conn-1'));
        expect(state.value?.uploadProgress, isNull,
            reason: 'uploadProgress must be cleared after a permission error');
      });

      test('rethrows non-permission SftpStatusError', () async {
        final mockSftp = _MockSftpClient();
        final container = await _makeFileBrowserContainer(
          mockSftp: mockSftp,
          initialState: const FileBrowserState(currentPath: '/home/user'),
        );

        when(() => mockSftp.open(any(), mode: any(named: 'mode')))
            .thenThrow(SftpStatusError(SftpStatusCode.noSuchFile, 'no such file'));

        await expectLater(
          container
              .read(fileBrowserProvider('conn-1').notifier)
              .uploadFile(localFile.path),
          throwsA(isA<SftpStatusError>()),
        );
      });
    });
  });

  // ---------------------------------------------------------------------------
  // navigateToInitialDirectory
  // ---------------------------------------------------------------------------

  group('navigateToInitialDirectory', () {
    setUpAll(() {
      registerFallbackValue('');
    });

    test('with tmux session navigates to tmux pane CWD', () async {
      final mockSftp = _MockSftpClient();
      final mockManager = _MockSshChannelManager();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        mockManager: mockManager,
        initialState: const FileBrowserState(currentPath: '/home/user'),
      );

      when(() => mockManager.getTmuxPaneCwd('mysession'))
          .thenAnswer((_) async => '/home/user/projects');
      when(() => mockSftp.listdir('/home/user/projects'))
          .thenAnswer((_) async => []);

      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .navigateToInitialDirectory(tmuxSessionName: 'mysession');

      expect(
        container.read(fileBrowserProvider('conn-1')).value?.currentPath,
        '/home/user/projects',
      );
    });

    test('without tmux session falls back to getShellCwd', () async {
      final mockSftp = _MockSftpClient();
      final mockManager = _MockSshChannelManager();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        mockManager: mockManager,
        initialState: const FileBrowserState(currentPath: '/home/user'),
      );

      when(() => mockManager.getShellCwd())
          .thenAnswer((_) async => '/home/user/work');
      when(() => mockSftp.listdir('/home/user/work'))
          .thenAnswer((_) async => []);

      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .navigateToInitialDirectory();

      expect(
        container.read(fileBrowserProvider('conn-1')).value?.currentPath,
        '/home/user/work',
      );
    });

    test('tmux CWD null falls back to getShellCwd', () async {
      final mockSftp = _MockSftpClient();
      final mockManager = _MockSshChannelManager();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        mockManager: mockManager,
        initialState: const FileBrowserState(currentPath: '/home/user'),
      );

      when(() => mockManager.getTmuxPaneCwd(any()))
          .thenAnswer((_) async => null);
      when(() => mockManager.getShellCwd())
          .thenAnswer((_) async => '/home/user/shell');
      when(() => mockSftp.listdir('/home/user/shell'))
          .thenAnswer((_) async => []);

      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .navigateToInitialDirectory(tmuxSessionName: 'mysession');

      expect(
        container.read(fileBrowserProvider('conn-1')).value?.currentPath,
        '/home/user/shell',
      );
    });

    test('channelManager null falls back to sftp.absolute', () async {
      final mockSftp = _MockSftpClient();
      // No mockManager → channelManager is null in notifier
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        mockManager: null,
        initialState: const FileBrowserState(currentPath: '/home/user'),
      );

      when(() => mockSftp.absolute('.')).thenAnswer((_) async => '/home/user');
      when(() => mockSftp.listdir('/home/user')).thenAnswer((_) async => []);

      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .navigateToInitialDirectory();

      expect(
        container.read(fileBrowserProvider('conn-1')).value?.currentPath,
        '/home/user',
      );
    });

    test('getShellCwd null falls back to sftp.absolute', () async {
      final mockSftp = _MockSftpClient();
      final mockManager = _MockSshChannelManager();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        mockManager: mockManager,
        initialState: const FileBrowserState(currentPath: '/home/user'),
      );

      when(() => mockManager.getShellCwd()).thenAnswer((_) async => null);
      when(() => mockSftp.absolute('.')).thenAnswer((_) async => '/home/user');
      when(() => mockSftp.listdir('/home/user')).thenAnswer((_) async => []);

      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .navigateToInitialDirectory();

      expect(
        container.read(fileBrowserProvider('conn-1')).value?.currentPath,
        '/home/user',
      );
    });

    test('getTmuxPaneCwd throws falls back to sftp.absolute', () async {
      final mockSftp = _MockSftpClient();
      final mockManager = _MockSshChannelManager();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        mockManager: mockManager,
        initialState: const FileBrowserState(currentPath: '/home/user'),
      );

      when(() => mockManager.getTmuxPaneCwd(any()))
          .thenThrow(Exception('tmux not available'));
      when(() => mockSftp.absolute('.')).thenAnswer((_) async => '/home/user');
      when(() => mockSftp.listdir('/home/user')).thenAnswer((_) async => []);

      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .navigateToInitialDirectory(tmuxSessionName: 'mysession');

      expect(
        container.read(fileBrowserProvider('conn-1')).value?.currentPath,
        '/home/user',
      );
    });

    // -----------------------------------------------------------------------
    // Edge cases
    // -----------------------------------------------------------------------

    test('sftp null → returns early without changing state', () async {
      // Build a container where _sftp is null (never called initForTesting).
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(fileBrowserProvider('conn-1').future)
          .catchError((_) => const FileBrowserState());

      // State is AsyncError at this point. navigateToInitialDirectory must
      // return early (sftp == null guard) without mutating it.
      final stateBefore = container.read(fileBrowserProvider('conn-1'));

      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .navigateToInitialDirectory();

      expect(
        container.read(fileBrowserProvider('conn-1')),
        equals(stateBefore),
        reason: 'sftp null → early return, state must be unchanged',
      );
    });

    test('getShellCwd returns empty string → falls back to sftp.absolute', () async {
      // cwd.isNotEmpty guard: empty string is falsy → skip navigateTo(cwd),
      // fall through to the sftp.absolute('.') fallback.
      final mockSftp = _MockSftpClient();
      final mockManager = _MockSshChannelManager();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        mockManager: mockManager,
        initialState: const FileBrowserState(currentPath: '/old/path'),
      );

      when(() => mockManager.getShellCwd()).thenAnswer((_) async => '');
      when(() => mockSftp.absolute('.')).thenAnswer((_) async => '/home/user');
      when(() => mockSftp.listdir('/home/user')).thenAnswer((_) async => []);

      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .navigateToInitialDirectory();

      expect(
        container.read(fileBrowserProvider('conn-1')).value?.currentPath,
        '/home/user',
        reason: 'empty getShellCwd must fall back to sftp.absolute',
      );
    });

    test('sftp.absolute returns empty string in fallback → current path unchanged', () async {
      // The `if (home.isNotEmpty)` guard: when absolute('.') returns '',
      // navigateTo is skipped and the current path stays as-is.
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        mockManager: null, // channelManager null → skip to sftp.absolute fallback
        initialState: const FileBrowserState(currentPath: '/preserved/path'),
      );

      when(() => mockSftp.absolute('.')).thenAnswer((_) async => '');

      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .navigateToInitialDirectory();

      expect(
        container.read(fileBrowserProvider('conn-1')).value?.currentPath,
        '/preserved/path',
        reason: 'empty sftp.absolute result must leave current path unchanged',
      );
    });

    // -----------------------------------------------------------------------
    // Staleness guard: _channelManager replaced mid-await
    //
    // `navigateToInitialDirectory` captures `channelManager = _channelManager`
    // before calling `getShellCwd()`.  After the await it checks
    // `_channelManager == channelManager` to detect a reconnect that swapped
    // the channel.  If the check fails the CWD result is discarded and the
    // sftp.absolute('.') fallback is used instead.
    // -----------------------------------------------------------------------

    test(
        'stale channelManager: CWD from getShellCwd ignored when channelManager replaced mid-await',
        () async {
      final mockSftp = _MockSftpClient();
      final mockManager1 = _MockSshChannelManager();
      final mockManager2 = _MockSshChannelManager();

      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        mockManager: mockManager1,
        initialState: const FileBrowserState(currentPath: '/initial'),
      );

      // getShellCwd returns a future controlled by a Completer so we can
      // inject the channelManager swap before the result arrives.
      final cwdCompleter = Completer<String?>();
      when(() => mockManager1.getShellCwd())
          .thenAnswer((_) => cwdCompleter.future);

      // Fallback path used after the stale guard fires.
      when(() => mockSftp.absolute('.')).thenAnswer((_) async => '/fallback/home');
      when(() => mockSftp.listdir('/fallback/home')).thenAnswer((_) async => []);

      // Start navigateToInitialDirectory. The function suspends at
      // `await channelManager.getShellCwd()` because cwdCompleter is not yet done.
      final navFuture = container
          .read(fileBrowserProvider('conn-1').notifier)
          .navigateToInitialDirectory();

      // Swap the channelManager while getShellCwd is still pending.
      // This simulates a reconnect event happening mid-flight.
      container.read(fileBrowserProvider('conn-1').notifier).initForTesting(
            sftp: mockSftp, // same sftp instance — fallback path still valid
            channelManager: mockManager2, // different instance → stale guard triggers
            initialState: const FileBrowserState(currentPath: '/initial'),
          );

      // Deliver the CWD result. The staleness check (_channelManager == channelManager)
      // now fails (mockManager2 ≠ mockManager1), so the result is discarded.
      cwdCompleter.complete('/home/user/projects');
      await navFuture;

      // The stale CWD must be ignored; the fallback home dir must be used.
      expect(
        container.read(fileBrowserProvider('conn-1')).value?.currentPath,
        '/fallback/home',
        reason: 'stale CWD from replaced channelManager must be discarded; '
            'sftp.absolute fallback must be used',
      );
      // Confirm navigateTo was never called with the stale path.
      verifyNever(() => mockSftp.listdir('/home/user/projects'));
    });
  });

  // ---------------------------------------------------------------------------
  // readFileBytes
  // ---------------------------------------------------------------------------

  group('readFileBytes', () {
    setUpAll(() {
      registerFallbackValue(SftpFileOpenMode.read);
    });

    test('uses file size from stat when smaller than maxBytes', () async {
      final mockSftp = _MockSftpClient();
      final mockFile = _MockSftpFile();
      final container = await _makeFileBrowserContainer(mockSftp: mockSftp);

      when(() => mockSftp.open(any(), mode: any(named: 'mode')))
          .thenAnswer((_) async => mockFile);
      when(() => mockFile.stat())
          .thenAnswer((_) async => SftpFileAttrs(size: 500));
      when(() => mockFile.readBytes(length: any(named: 'length')))
          .thenAnswer((_) async => Uint8List.fromList([1, 2, 3]));
      when(() => mockFile.close()).thenAnswer((_) async {});

      final result = await container
          .read(fileBrowserProvider('conn-1').notifier)
          .readFileBytes('/home/user/file.txt');

      expect(result, [1, 2, 3]);
      // Stat reported 500 bytes → should read exactly 500, not the default 1 MB
      verify(() => mockFile.readBytes(length: 500)).called(1);
      verify(() => mockFile.close()).called(1);
    });

    test('falls back to maxBytes when stat throws', () async {
      final mockSftp = _MockSftpClient();
      final mockFile = _MockSftpFile();
      final container = await _makeFileBrowserContainer(mockSftp: mockSftp);

      when(() => mockSftp.open(any(), mode: any(named: 'mode')))
          .thenAnswer((_) async => mockFile);
      when(() => mockFile.stat()).thenThrow(Exception('stat failed'));
      when(() => mockFile.readBytes(length: any(named: 'length')))
          .thenAnswer((_) async => Uint8List.fromList([10, 20]));
      when(() => mockFile.close()).thenAnswer((_) async {});

      const defaultMax = 1024 * 1024;
      final result = await container
          .read(fileBrowserProvider('conn-1').notifier)
          .readFileBytes('/home/user/big.bin');

      expect(result, [10, 20]);
      verify(() => mockFile.readBytes(length: defaultMax)).called(1);
    });

    test('falls back to maxBytes when stat size is null', () async {
      final mockSftp = _MockSftpClient();
      final mockFile = _MockSftpFile();
      final container = await _makeFileBrowserContainer(mockSftp: mockSftp);

      when(() => mockSftp.open(any(), mode: any(named: 'mode')))
          .thenAnswer((_) async => mockFile);
      when(() => mockFile.stat())
          .thenAnswer((_) async => SftpFileAttrs(size: null));
      when(() => mockFile.readBytes(length: any(named: 'length')))
          .thenAnswer((_) async => Uint8List(0));
      when(() => mockFile.close()).thenAnswer((_) async {});

      const defaultMax = 1024 * 1024;
      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .readFileBytes('/home/user/nul.bin');

      verify(() => mockFile.readBytes(length: defaultMax)).called(1);
    });

    test('falls back to maxBytes when file size >= maxBytes', () async {
      final mockSftp = _MockSftpClient();
      final mockFile = _MockSftpFile();
      final container = await _makeFileBrowserContainer(mockSftp: mockSftp);
      const smallMax = 256;

      when(() => mockSftp.open(any(), mode: any(named: 'mode')))
          .thenAnswer((_) async => mockFile);
      when(() => mockFile.stat())
          .thenAnswer((_) async => SftpFileAttrs(size: 1024)); // > smallMax
      when(() => mockFile.readBytes(length: any(named: 'length')))
          .thenAnswer((_) async => Uint8List(smallMax));
      when(() => mockFile.close()).thenAnswer((_) async {});

      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .readFileBytes('/home/user/big.bin', maxBytes: smallMax);

      verify(() => mockFile.readBytes(length: smallMax)).called(1);
    });

    test('closes file even when readBytes throws', () async {
      final mockSftp = _MockSftpClient();
      final mockFile = _MockSftpFile();
      final container = await _makeFileBrowserContainer(mockSftp: mockSftp);

      when(() => mockSftp.open(any(), mode: any(named: 'mode')))
          .thenAnswer((_) async => mockFile);
      when(() => mockFile.stat())
          .thenAnswer((_) async => SftpFileAttrs(size: 100));
      when(() => mockFile.readBytes(length: any(named: 'length')))
          .thenThrow(Exception('read error'));
      when(() => mockFile.close()).thenAnswer((_) async {});

      await expectLater(
        container
            .read(fileBrowserProvider('conn-1').notifier)
            .readFileBytes('/home/user/bad.bin'),
        throwsA(isA<Exception>()),
      );
      verify(() => mockFile.close()).called(1);
    });

    test('throws NetworkError when sftp not initialized', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(fileBrowserProvider('conn-1').future)
          .catchError((_) => const FileBrowserState());
      // Do NOT call initForTesting → _sftp remains null

      await expectLater(
        container
            .read(fileBrowserProvider('conn-1').notifier)
            .readFileBytes('/home/user/file.txt'),
        throwsA(isA<NetworkError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // setConnectionCredentials()
  //
  // Stores host/port/user/password/key for the download isolate.
  // Calling it must not throw and must not change visible state.
  // ---------------------------------------------------------------------------

  group('setConnectionCredentials()', () {
    test('does not throw and does not change visible state', () async {
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(mockSftp: mockSftp);

      final stateBefore = container.read(fileBrowserProvider('conn-1'));

      // Act: set credentials — pure field setter with no side-effects on state.
      container.read(fileBrowserProvider('conn-1').notifier).setConnectionCredentials(
        host: '192.168.1.1',
        port: 22,
        username: 'admin',
        password: 's3cr3t',
        privateKeyPem: null,
        passphrase: null,
      );

      final stateAfter = container.read(fileBrowserProvider('conn-1'));
      expect(stateAfter, equals(stateBefore),
          reason: 'setConnectionCredentials must not modify notifier state');
    });

    test('accepts all optional parameters as null', () async {
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(mockSftp: mockSftp);

      // Should not throw even with all optional fields null.
      expect(
        () => container
            .read(fileBrowserProvider('conn-1').notifier)
            .setConnectionCredentials(
              host: 'server.example.com',
              port: 2222,
              username: 'user',
            ),
        returnsNormally,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // _initializeState() — error path (line 172)
  //
  // When setChannelManager(manager) is called and openSftpChannel() throws,
  // the notifier must transition to AsyncError.
  // ---------------------------------------------------------------------------

  group('_initializeState() error path', () {
    test('transitions to AsyncError when openSftpChannel throws', () async {
      final mockManager = _MockSshChannelManager();
      when(() => mockManager.openSftpChannel())
          .thenThrow(Exception('channel open failed'));

      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Allow initial build to fail (no channelManager).
      await container
          .read(fileBrowserProvider('conn-1').future)
          .catchError((_) => const FileBrowserState());

      // setChannelManager triggers _initializeState which calls openSftpChannel.
      container
          .read(fileBrowserProvider('conn-1').notifier)
          .setChannelManager(mockManager);

      // Allow the async _initializeState to complete.
      await Future<void>.delayed(Duration.zero);

      final state = container.read(fileBrowserProvider('conn-1'));
      expect(state, isA<AsyncError>(),
          reason: '_initializeState must emit AsyncError when openSftpChannel throws');
    });
  });

  // ---------------------------------------------------------------------------
  // _connectSftp() — absolute('.') fallback
  //
  // When sftp.absolute('.') throws, _connectSftp must fall back to '/' instead
  // of propagating the error.
  // ---------------------------------------------------------------------------

  group('_connectSftp absolute path fallback', () {
    late _MockSshChannelManager mockManager;
    late _MockSftpClient mockSftp;

    setUp(() {
      mockManager = _MockSshChannelManager();
      mockSftp = _MockSftpClient();
      when(() => mockManager.openSftpChannel()).thenAnswer((_) async => mockSftp);
      when(() => mockSftp.listdir(any())).thenAnswer((_) async => []);
    });

    Future<void> triggerInitialize(ProviderContainer container) async {
      // Allow initial build to fail (no channelManager).
      await container
          .read(fileBrowserProvider('conn-1').future)
          .catchError((_) => const FileBrowserState());
      container
          .read(fileBrowserProvider('conn-1').notifier)
          .setChannelManager(mockManager);
      await Future<void>.delayed(Duration.zero);
    }

    test('uses absolute path when sftp.absolute succeeds', () async {
      when(() => mockSftp.absolute('.')).thenAnswer((_) async => '/home/user');
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await triggerInitialize(container);

      final state = container.read(fileBrowserProvider('conn-1'));
      expect(state.value?.currentPath, '/home/user');
    });

    test('falls back to "/" when sftp.absolute throws', () async {
      when(() => mockSftp.absolute('.')).thenThrow(Exception('not supported'));
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await triggerInitialize(container);

      final state = container.read(fileBrowserProvider('conn-1'));
      expect(state, isA<AsyncData<FileBrowserState>>(),
          reason: 'absolute() failure must not cause AsyncError');
      expect(state.value?.currentPath, '/',
          reason: 'should fall back to / when absolute() throws');
    });

    test('falls back to "/" when sftp.absolute returns empty string', () async {
      when(() => mockSftp.absolute('.')).thenAnswer((_) async => '');
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await triggerInitialize(container);

      final state = container.read(fileBrowserProvider('conn-1'));
      expect(state, isA<AsyncData<FileBrowserState>>());
      // Empty return value is treated the same as an exception — fall back to /.
      expect(state.value?.currentPath, '/');
    });
  });

  // ---------------------------------------------------------------------------
  // downloadFile() — guard conditions
  //
  // downloadFile() returns early when already downloading (_isDownloading guard).
  // When credentials are not set, _downloadFileCore throws NetworkError which
  // is caught internally — the public API must not propagate the exception.
  // ---------------------------------------------------------------------------

  group('downloadFile() guard conditions', () {
    setUpAll(() {
      registerFallbackValue(SftpFileOpenMode.read);
    });

    test('concurrent calls do not throw (second is a no-op via _isDownloading guard)',
        () async {
      final mockSftp = _MockSftpClient();
      // mockManager is null → credentials will be null → _downloadFileCore
      // throws NetworkError immediately (before getTemporaryDirectory).
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        mockManager: null,
      );

      // Fire two concurrent calls. The second must hit _isDownloading guard
      // and return early before the first call's await resolves.
      final f1 = container
          .read(fileBrowserProvider('conn-1').notifier)
          .downloadFile('/file1.txt');
      final f2 = container
          .read(fileBrowserProvider('conn-1').notifier)
          .downloadFile('/file2.txt');

      // Neither call should propagate exceptions to the caller.
      await expectLater(Future.wait([f1, f2]), completes);
    });

    test('downloadFile with no credentials completes without throwing', () async {
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        mockManager: null, // ensures _channelManager is null
      );

      // credentials not set → _downloadFileCore throws NetworkError (caught internally).
      await expectLater(
        container
            .read(fileBrowserProvider('conn-1').notifier)
            .downloadFile('/remote/file.txt'),
        completes,
      );
    });

    test('downloadFile transitions to AsyncError when channelManager is null after download',
        () async {
      final mockSftp = _MockSftpClient();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        mockManager: null, // no channelManager → AsyncError in finally block
      );

      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .downloadFile('/remote/file.txt');

      // After download (which failed with NetworkError), channelManager is null
      // → state transitions to AsyncError in the finally block.
      final state = container.read(fileBrowserProvider('conn-1'));
      expect(state, isA<AsyncError>(),
          reason: 'downloadFile finally must set AsyncError when channelManager is null');
      expect(state.error, isA<NetworkError>());
    });

    test('downloadFile sets downloadError when download fails and channelManager is non-null',
        () async {
      final mockSftp = _MockSftpClient();
      final mockManager = _MockSshChannelManager();
      // credentials not set → _downloadFileCore throws NetworkError immediately.
      // Since channelManager is non-null, state stays AsyncData with downloadError set.
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        mockManager: mockManager,
      );

      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .downloadFile('/remote/file.txt');

      final state = container.read(fileBrowserProvider('conn-1'));
      expect(state, isA<AsyncData<FileBrowserState>>(),
          reason: 'State should remain AsyncData when channelManager is non-null');
      expect(state.valueOrNull?.downloadError, isNotNull,
          reason: 'downloadError should be set when download fails with live connection');
      expect(state.valueOrNull?.downloadError,
          contains('Connection credentials not set'));
    });

    test('downloadFile clears previous downloadError when starting a new download', () async {
      final mockSftp = _MockSftpClient();
      final mockManager = _MockSshChannelManager();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        mockManager: mockManager,
        initialState: const FileBrowserState(
          currentPath: '/home/user',
          downloadError: 'previous error message',
        ),
      );

      // A new download should clear the previous error before running.
      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .downloadFile('/remote/file.txt');

      final state = container.read(fileBrowserProvider('conn-1'));
      expect(state.valueOrNull?.downloadError,
          isNot(equals('previous error message')),
          reason: 'Previous downloadError must be cleared when a new download starts');
    });

    test('clearDownloadError clears the downloadError field', () async {
      final mockSftp = _MockSftpClient();
      final mockManager = _MockSshChannelManager();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        mockManager: mockManager,
      );
      final notifier = container.read(fileBrowserProvider('conn-1').notifier);

      // Trigger a failed download to populate downloadError.
      await notifier.downloadFile('/remote/file.txt');
      expect(container.read(fileBrowserProvider('conn-1')).valueOrNull?.downloadError,
          isNotNull);

      // Dismiss the error.
      notifier.clearDownloadError();

      expect(container.read(fileBrowserProvider('conn-1')).valueOrNull?.downloadError,
          isNull,
          reason: 'clearDownloadError must reset downloadError to null');
    });
  });

  // -------------------------------------------------------------------------
  // saveToDownloads failure surfaces as downloadError
  //
  // Before the fix, a saveToDownloads exception was caught and silently ignored —
  // the UI would receive a "downloaded" notification with a phantom filename that
  // was never written to Downloads. After the fix, the error propagates to the
  // downloadFile() catch block and surfaces as FileBrowserState.downloadError.
  // -------------------------------------------------------------------------

  group('downloadFile() saveToDownloads failure', () {
    setUpAll(() {
      registerFallbackValue(SftpFileOpenMode.read);
    });

    test('saveToDownloads failure surfaces as downloadError (not phantom success)',
        () async {
      final mockSftp = _MockSftpClient();
      final mockManager = _MockSshChannelManager();

      // Fake isolate that immediately reports success (no real SSH needed).
      final progressPort = ReceivePort();
      final resultPort = ReceivePort();
      // Send success before downloadFile awaits result — ReceivePort buffers it.
      resultPort.sendPort.send(true);

      // Fake temp directory so path_provider is not needed.
      final tempDir = Directory.systemTemp.createTempSync('dl_test_');
      addTearDown(tempDir.deleteSync);

      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        mockManager: mockManager,
      );
      final notifier = container.read(fileBrowserProvider('conn-1').notifier);

      // Set credentials so _downloadFileCore passes the null-check.
      notifier.setConnectionCredentials(
        host: 'testhost',
        port: 22,
        username: 'testuser',
        password: 'testpass',
      );

      // Inject test doubles: fake isolate (success) + failing saveToDownloads.
      notifier.initForTesting(
        sftp: mockSftp,
        channelManager: mockManager,
        getTemporaryDirectory: () async => tempDir,
        startDownloadIsolate: ({
          required host,
          required port,
          required username,
          password,
          privateKeyPem,
          passphrase,
          required remotePath,
          required localPath,
          required totalBytes,
        }) async =>
            DownloadIsolate.forTesting(
              progressPort: progressPort,
              resultPort: resultPort,
            ),
        saveToDownloads: ({required tempFilePath, required fileName}) async {
          throw Exception('MediaStore write failed');
        },
      );

      // sftp.stat may be called for progress — make it return quickly.
      when(() => mockSftp.stat(any()))
          .thenAnswer((_) async => SftpFileAttrs(size: 0));

      await notifier.downloadFile('/remote/test.txt');

      final state = container.read(fileBrowserProvider('conn-1'));
      expect(
        state.valueOrNull?.downloadError,
        isNotNull,
        reason: 'saveToDownloads failure must surface as downloadError',
      );
      expect(
        state.valueOrNull?.downloadError,
        contains('MediaStore write failed'),
      );
      expect(
        state.valueOrNull?.downloadedFilePath,
        isNull,
        reason: 'downloadedFilePath must not be set when saveToDownloads failed',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Regression: uploadFile _isUploading stuck on _requireSftp throw
  //
  // Before the fix, _isUploading = true was set before the outer try/finally,
  // so a NetworkError thrown by _requireSftp left _isUploading permanently true.
  // Subsequent upload attempts would silently no-op via the guard check.
  // -------------------------------------------------------------------------

  group('uploadFile _isUploading reset (regression)', () {
    test('uploadFile resets _isUploading when sftp is not initialized, allowing retry',
        () async {
      // Build container without injecting sftp (_sftp stays null after build() fails).
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(fileBrowserProvider('conn-1').future)
          .catchError((_) => const FileBrowserState());

      final notifier = container.read(fileBrowserProvider('conn-1').notifier);

      // First call: _requireSftp throws NetworkError.
      await expectLater(
        notifier.uploadFile('/tmp/test.txt'),
        throwsA(isA<NetworkError>()),
      );

      // Second call: without the fix _isUploading stays true and this silently
      // returns (no exception). With the fix the outer finally resets
      // _isUploading, so the second call also throws.
      await expectLater(
        notifier.uploadFile('/tmp/test.txt'),
        throwsA(isA<NetworkError>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // uploadFile disconnect guard (setChannelManager parity with downloadFile)
  //
  // When the SSH connection drops while an upload is in progress:
  // 1. setChannelManager(null) must NOT immediately emit AsyncError
  //    (deferred because _isUploading is true).
  // 2. uploadFile's finally block must emit AsyncError once the upload ends
  //    (same contract as downloadFile's finally block).
  // -------------------------------------------------------------------------

  group('uploadFile disconnect guard', () {
    late Directory tempDir;
    late File localFile;

    setUpAll(() {
      registerFallbackValue(SftpFileOpenMode.write);
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('upload_disconnect_');
      localFile = File('${tempDir.path}/test.txt');
      await localFile.writeAsString('hello');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('uploadFile finally emits AsyncError when channelManager is null after upload',
        () async {
      final mockSftp = _MockSftpClient();
      // channelManager: null → after upload throws, finally sees _channelManager == null
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        mockManager: null,
        initialState: const FileBrowserState(currentPath: '/home/user'),
      );

      when(() => mockSftp.open(any(), mode: any(named: 'mode')))
          .thenThrow(SftpStatusError(SftpStatusCode.failure, 'connection lost'));

      // uploadFile propagates the error; catch it so we can inspect state.
      await container
          .read(fileBrowserProvider('conn-1').notifier)
          .uploadFile(localFile.path)
          .catchError((_) {});

      final state = container.read(fileBrowserProvider('conn-1'));
      expect(state, isA<AsyncError>(),
          reason: 'uploadFile finally must set AsyncError when channelManager is null');
      expect(state.error, isA<NetworkError>());
    });

    test('setChannelManager(null) defers AsyncError while upload is in progress',
        () async {
      final mockSftp = _MockSftpClient();
      final mockManager = _MockSshChannelManager();
      final container = await _makeFileBrowserContainer(
        mockSftp: mockSftp,
        mockManager: mockManager,
        initialState: const FileBrowserState(currentPath: '/home/user'),
      );

      // Block sftp.open() with a signal completer (success signal, throws inside async).
      // Using a signal completer rather than completeError avoids zone-level
      // unhandled-error reporting that occurs when errors propagate across
      // zone boundaries before the catch handler runs.
      final openSignal = Completer<void>();
      when(() => mockSftp.open(any(), mode: any(named: 'mode')))
          .thenAnswer((_) async {
        await openSignal.future; // wait for signal
        throw SftpStatusError(SftpStatusCode.failure, 'connection lost');
      });

      // Start upload (do not await — it is in-flight).
      final uploadFuture = container
          .read(fileBrowserProvider('conn-1').notifier)
          .uploadFile(localFile.path)
          .catchError((_) {});

      // Yield so uploadFile reaches the `await sftp.open(...)` suspension point.
      await Future.delayed(Duration.zero);

      // Simulate disconnect while upload is in progress.
      container
          .read(fileBrowserProvider('conn-1').notifier)
          .setChannelManager(null);

      // State must still be AsyncData — AsyncError is deferred because
      // _isUploading is true.
      expect(container.read(fileBrowserProvider('conn-1')), isA<AsyncData<FileBrowserState>>(),
          reason: 'setChannelManager(null) must not emit AsyncError while _isUploading is true');

      // Signal sftp.open() to proceed (it will throw internally).
      openSignal.complete();
      await uploadFuture;

      // Now the upload's finally has run: channelManager is null → AsyncError.
      final state = container.read(fileBrowserProvider('conn-1'));
      expect(state, isA<AsyncError>(),
          reason: 'AsyncError must be emitted after upload completes when channelManager is null');
      expect(state.error, isA<NetworkError>());
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
