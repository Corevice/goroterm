import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:terminal_ssh_app/features/file_browser/file_browser_provider.dart';
import 'package:terminal_ssh_app/features/file_browser/file_browser_screen.dart';
import 'package:terminal_ssh_app/features/terminal/terminal_connection_provider.dart';

// ---------------------------------------------------------------------------
// Shared state variable (set before pumpWidget in each test)
// ---------------------------------------------------------------------------

FileBrowserState _fakeState = const FileBrowserState();

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Fake that returns the module-level [_fakeState] without needing SSH.
class _FakeFileBrowserNotifier extends FileBrowserNotifier {
  @override
  Future<FileBrowserState> build(String arg) async => _fakeState;

  @override
  void toggleHidden() {}

  @override
  Future<void> refresh() async {}

  @override
  Future<void> navigateTo(String path) async {}

  @override
  Future<void> downloadFile(String remotePath) async {}

  @override
  void clearDownloadNotification() {}

  @override
  Future<void> uploadFile(String localPath) async {}

  @override
  void clearUploadNotification() {}

  @override
  Future<void> deleteFile(String remotePath, {bool isDirectory = false}) async {}

  @override
  Future<void> renameFile(String oldPath, String newPath) async {}
}

class _FakeTerminalNotifier extends TerminalConnectionNotifier {
  @override
  TerminalConnectionState build(String arg) =>
      const TerminalConnectionState(status: ConnectionStatus.connected);
}

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

SftpName _makeItem(String name, {bool isDirectory = false}) {
  final permBits = isDirectory
      ? (1 << 14) | (1 << 8) | (1 << 7) | (1 << 6)
      : (1 << 15) | (1 << 8) | (1 << 7);
  return SftpName(
    filename: name,
    longname: '-rw-r--r-- 1 u g 0 Jan 1 00:00 $name',
    attr: SftpFileAttrs(mode: SftpFileMode.value(permBits)),
  );
}

Widget _buildBrowser() {
  return ProviderScope(
    overrides: [
      fileBrowserProvider.overrideWith(_FakeFileBrowserNotifier.new),
      terminalConnectionProvider.overrideWith(_FakeTerminalNotifier.new),
    ],
    child: const MaterialApp(
      home: Scaffold(body: FileBrowserScreen(connectionId: 'conn1')),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('FileBrowserScreen', () {
    setUp(() {
      _fakeState = const FileBrowserState(currentPath: '/');
    });

    testWidgets('shows "File Browser" header', (tester) async {
      await tester.pumpWidget(_buildBrowser());
      await tester.pump();
      expect(find.text('File Browser'), findsOneWidget);
    });

    testWidgets('shows path bar segments for nested path', (tester) async {
      _fakeState = const FileBrowserState(currentPath: '/home/user');
      await tester.pumpWidget(_buildBrowser());
      await tester.pump();
      expect(find.text('home'), findsOneWidget);
      expect(find.text('user'), findsOneWidget);
    });

    testWidgets('shows "Empty directory" when no items', (tester) async {
      _fakeState = const FileBrowserState(
        currentPath: '/home/user',
        items: [],
      );
      await tester.pumpWidget(_buildBrowser());
      await tester.pump();
      expect(find.text('Empty directory'), findsOneWidget);
    });

    testWidgets('shows file list when items present', (tester) async {
      _fakeState = FileBrowserState(
        currentPath: '/home/user',
        items: [
          _makeItem('README.md'),
          _makeItem('src', isDirectory: true),
        ],
      );
      await tester.pumpWidget(_buildBrowser());
      await tester.pump();
      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('src'), findsOneWidget);
    });

    testWidgets('shows refresh and toggle hidden icons', (tester) async {
      await tester.pumpWidget(_buildBrowser());
      await tester.pump();
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    });

    testWidgets('shows visibility icon when showHidden is true', (tester) async {
      _fakeState = const FileBrowserState(currentPath: '/', showHidden: true);
      await tester.pumpWidget(_buildBrowser());
      await tester.pump();
      expect(find.byIcon(Icons.visibility), findsOneWidget);
    });

    testWidgets('shows back navigation ".." when not at root', (tester) async {
      _fakeState = const FileBrowserState(currentPath: '/home/user');
      await tester.pumpWidget(_buildBrowser());
      await tester.pump();
      expect(find.text('..'), findsOneWidget);
    });

    testWidgets('no back navigation ".." at root', (tester) async {
      _fakeState = const FileBrowserState(currentPath: '/');
      await tester.pumpWidget(_buildBrowser());
      await tester.pump();
      expect(find.text('..'), findsNothing);
    });

    testWidgets('path bar shows copy icon', (tester) async {
      await tester.pumpWidget(_buildBrowser());
      await tester.pump();
      expect(find.byIcon(Icons.copy), findsOneWidget);
    });

    testWidgets('download progress bar shown when downloading', (tester) async {
      _fakeState = const FileBrowserState(
        currentPath: '/home',
        downloadProgress: 0.5,
      );
      await tester.pumpWidget(_buildBrowser());
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('context menu shows Rename and Delete for a file (Phase 17)',
        (tester) async {
      _fakeState = FileBrowserState(
        currentPath: '/home/user',
        items: [_makeItem('notes.txt')],
      );
      await tester.pumpWidget(_buildBrowser());
      await tester.pump();

      // Long-press the file to open the context menu
      await tester.longPress(find.text('notes.txt'));
      await tester.pumpAndSettle();

      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('context menu shows Rename and Delete for a directory (Phase 17)',
        (tester) async {
      _fakeState = FileBrowserState(
        currentPath: '/home/user',
        items: [_makeItem('projects', isDirectory: true)],
      );
      await tester.pumpWidget(_buildBrowser());
      await tester.pump();

      await tester.longPress(find.text('projects'));
      await tester.pumpAndSettle();

      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('upload progress shown when uploading (Phase 16)', (tester) async {
      _fakeState = const FileBrowserState(
        currentPath: '/home',
        uploadProgress: 0.3,
      );
      await tester.pumpWidget(_buildBrowser());
      await tester.pump();
      expect(find.textContaining('Uploading'), findsOneWidget);
    });

    testWidgets('upload complete banner shown after upload (Phase 16)', (tester) async {
      _fakeState = const FileBrowserState(
        currentPath: '/home',
        uploadCompleteFile: 'photo.jpg',
      );
      await tester.pumpWidget(_buildBrowser());
      await tester.pump();
      expect(find.textContaining('photo.jpg'), findsOneWidget);
    });
  });
}
