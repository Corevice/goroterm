import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:xterm/xterm.dart';

import 'package:terminal_ssh_app/core/storage/connection_repository.dart';
import 'package:terminal_ssh_app/features/connections/connection_provider.dart';
import 'package:terminal_ssh_app/features/terminal/terminal_connection_provider.dart';
import 'package:terminal_ssh_app/features/terminal/terminal_screen.dart';
import 'package:terminal_ssh_app/features/terminal/session_manager.dart';

import '../../test_localizations.dart';

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

class _MockConnectionRepository extends Mock implements ConnectionRepository {}

// ---------------------------------------------------------------------------
// Fakes for TerminalConnectionNotifier
// ---------------------------------------------------------------------------

class _ConnectingNotifier extends TerminalConnectionNotifier {
  @override
  TerminalConnectionState build(String arg) {
    return const TerminalConnectionState(
      status: ConnectionStatus.connecting,
      hostLabel: 'example.com',
    );
  }
}

class _ConnectedNotifier extends TerminalConnectionNotifier {
  @override
  TerminalConnectionState build(String arg) {
    return TerminalConnectionState(
      status: ConnectionStatus.connected,
      terminal: Terminal(maxLines: 50),
      hostLabel: 'My Server',
    );
  }
}

class _DisconnectedNotifier extends TerminalConnectionNotifier {
  @override
  TerminalConnectionState build(String arg) {
    return const TerminalConnectionState(
      status: ConnectionStatus.disconnected,
      hostLabel: 'example.com',
      errorMessage: 'Connection lost',
    );
  }
}

// ---------------------------------------------------------------------------
// Fake SessionManager with one pre-populated session
// ---------------------------------------------------------------------------

const _testSessionId = 'test_session_1';

class _FakeSessionManagerNotifier extends SessionManagerNotifier {
  @override
  SessionManagerState build() {
    return const SessionManagerState(
      sessions: [
        TerminalSession(
          sessionId: _testSessionId,
          connectionId: 1,
          label: 'My Server',
        ),
      ],
      activeSessionId: _testSessionId,
    );
  }
}

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

Widget _buildScreen(TerminalConnectionNotifier Function() notifierFactory) {
  final mockRepo = _MockConnectionRepository();
  // getById returns null → _startConnection exits early without SSH call.
  when(() => mockRepo.getById(any())).thenAnswer((_) async => null);

  return ProviderScope(
    overrides: [
      sessionManagerProvider.overrideWith(_FakeSessionManagerNotifier.new),
      terminalConnectionProvider.overrideWith(notifierFactory),
      connectionRepositoryProvider.overrideWithValue(mockRepo),
    ],
    child: localizedTestApp(home: const TerminalScreen()),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('TerminalScreen', () {
    testWidgets('shows CircularProgressIndicator while connecting',
        (tester) async {
      await tester.pumpWidget(_buildScreen(_ConnectingNotifier.new));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsWidgets);
    });

    testWidgets('shows host label in AppBar while connecting', (tester) async {
      await tester.pumpWidget(_buildScreen(_ConnectingNotifier.new));
      await tester.pump();
      expect(find.text('example.com'), findsOneWidget);
    });

    testWidgets('shows TerminalView when connected', (tester) async {
      await tester.pumpWidget(_buildScreen(_ConnectedNotifier.new));
      await tester.pump();
      expect(find.byType(TerminalView), findsOneWidget);
      // 'My Server' appears in both AppBar title and tab strip (always visible)
      expect(find.text('My Server'), findsWidgets);
    });

    testWidgets('shows reconnection banner when disconnected', (tester) async {
      await tester.pumpWidget(_buildScreen(_DisconnectedNotifier.new));
      await tester.pump();
      expect(find.text('Connection lost'), findsOneWidget);
      expect(find.text('Reconnect Now'), findsOneWidget);
    });

    testWidgets('AppBar has folder_open icon for file browser', (tester) async {
      await tester.pumpWidget(_buildScreen(_ConnectedNotifier.new));
      await tester.pump();
      expect(find.byIcon(Icons.folder_open), findsOneWidget);
    });

    testWidgets('AppBar has view_list icon for tmux', (tester) async {
      await tester.pumpWidget(_buildScreen(_ConnectedNotifier.new));
      await tester.pump();
      expect(find.byIcon(Icons.view_list), findsOneWidget);
    });

    testWidgets('QuickActionBar shows Ctrl shortcut', (tester) async {
      await tester.pumpWidget(_buildScreen(_ConnectedNotifier.new));
      await tester.pump();
      expect(find.text('Ctrl'), findsOneWidget);
    });
  });
}
