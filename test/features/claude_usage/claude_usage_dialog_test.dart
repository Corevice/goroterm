import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:terminal_ssh_app/core/ssh/ssh_channel_manager.dart';
import 'package:terminal_ssh_app/features/claude_usage/claude_usage_dialog.dart';
import 'package:terminal_ssh_app/features/terminal/terminal_connection_provider.dart';

import '../../test_localizations.dart';

// ---------------------------------------------------------------------------
// Mock / Fake helpers
// ---------------------------------------------------------------------------

class MockSshChannelManager extends Mock implements SshChannelManager {}

class FakeTerminalConnectionNotifier extends TerminalConnectionNotifier {
  FakeTerminalConnectionNotifier(this._channelManager);
  final SshChannelManager? _channelManager;

  @override
  TerminalConnectionState build(String arg) {
    return TerminalConnectionState(
      status: _channelManager != null
          ? ConnectionStatus.connected
          : ConnectionStatus.disconnected,
      channelManager: _channelManager,
    );
  }
}

// ---------------------------------------------------------------------------
// Sample JSON responses
// ---------------------------------------------------------------------------

/// Full Claude Max usage response with all limit types.
final _sampleResponse = json.encode({
  'subscription': 'max',
  'rateLimitTier': 'standard',
  'usage': {
    'five_hour': {
      'utilization': 25.5,
      'resets_at': DateTime.utc(2099, 1, 1, 12).toIso8601String(),
    },
    'seven_day': {
      'utilization': 40.0,
      'resets_at': DateTime.utc(2099, 1, 7).toIso8601String(),
    },
    'seven_day_opus': {
      'utilization': 15.0,
      'resets_at': DateTime.utc(2099, 1, 7).toIso8601String(),
    },
    'seven_day_sonnet': {
      'utilization': 0.0,
      'resets_at': DateTime.utc(2099, 1, 7).toIso8601String(),
    },
    'extra_usage': {
      'is_enabled': false,
    },
  },
});

/// Response with extra usage enabled.
final _extraUsageResponse = json.encode({
  'subscription': 'pro',
  'rateLimitTier': 'standard',
  'usage': {
    'five_hour': {
      'utilization': 92.0,
      'resets_at': DateTime.utc(2099, 1, 1, 4).toIso8601String(),
    },
    'seven_day': null,
    'seven_day_opus': null,
    'seven_day_sonnet': null,
    'extra_usage': {
      'is_enabled': true,
      'utilization': 55.0,
      'used_credits': 1250,
    },
  },
});

/// Error response from the python script.
final _errorResponse = json.encode({
  'error': 'Claude Code not found (~/.claude/.credentials.json missing)',
});

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

Widget buildTestWidget({SshChannelManager? channelManager}) {
  return ProviderScope(
    overrides: [
      terminalConnectionProvider.overrideWith(
        () => FakeTerminalConnectionNotifier(channelManager),
      ),
    ],
    child: localizedTestApp(
      home: const Scaffold(body: SizedBox.shrink()),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ClaudeUsageDialog', () {
    late MockSshChannelManager mockChannelManager;

    setUp(() {
      mockChannelManager = MockSshChannelManager();
    });

    testWidgets('shows loading indicator initially', (tester) async {
      // Never completes → stays in loading state
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) => Completer<Uint8List>().future,
      );

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ClaudeUsageDialog.show(context, 'test-session');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Claude Code Usage'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('displays usage data after successful fetch', (tester) async {
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List.fromList(utf8.encode(_sampleResponse)),
      );

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ClaudeUsageDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      // Header
      expect(find.text('Claude Code Usage'), findsOneWidget);

      // Subscription badge
      expect(find.textContaining('Claude Max'), findsOneWidget);

      // Usage bars (remaining percentages)
      expect(find.textContaining('74.5% remaining'), findsOneWidget); // 5-Hour
      expect(find.textContaining('60.0% remaining'), findsOneWidget); // 7-Day

      // 7-Day Opus is 15% used → 85% remaining, should show
      expect(find.textContaining('85.0% remaining'), findsOneWidget);

      // Refresh button visible (not loading)
      expect(find.byIcon(Icons.refresh), findsOneWidget);
    });

    testWidgets('shows error when SSH not connected', (tester) async {
      await tester.pumpWidget(buildTestWidget(channelManager: null));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ClaudeUsageDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      expect(find.text('SSH not connected'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('shows error when command throws', (tester) async {
      when(() => mockChannelManager.runCommand(any()))
          .thenThrow(Exception('Connection timeout'));

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ClaudeUsageDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      expect(find.textContaining('Connection timeout'), findsOneWidget);
    });

    testWidgets('shows error from JSON error field', (tester) async {
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List.fromList(utf8.encode(_errorResponse)),
      );

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ClaudeUsageDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Claude Code not found'),
        findsOneWidget,
      );
    });

    testWidgets('shows error for empty output', (tester) async {
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List(0),
      );

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ClaudeUsageDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      expect(find.textContaining('No output from remote server'), findsOneWidget);
    });

    testWidgets('shows error for invalid JSON', (tester) async {
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List.fromList(utf8.encode('not json at all')),
      );

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ClaudeUsageDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      expect(find.textContaining('Invalid response'), findsOneWidget);
    });

    testWidgets('refresh button re-fetches data', (tester) async {
      var callCount = 0;
      when(() => mockChannelManager.runCommand(any())).thenAnswer((_) async {
        callCount++;
        return Uint8List.fromList(utf8.encode(_sampleResponse));
      });

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ClaudeUsageDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      expect(callCount, 1);

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();

      expect(callCount, 2);
    });

    testWidgets('error clears and data shown after successful refresh',
        (tester) async {
      var callCount = 0;
      when(() => mockChannelManager.runCommand(any())).thenAnswer((_) async {
        callCount++;
        if (callCount == 1) throw Exception('network error');
        return Uint8List.fromList(utf8.encode(_sampleResponse));
      });

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ClaudeUsageDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      expect(find.textContaining('network error'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();

      expect(find.textContaining('network error'), findsNothing);
      expect(find.textContaining('Claude Max'), findsOneWidget);
    });

    testWidgets('extra usage bar is shown when enabled', (tester) async {
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List.fromList(utf8.encode(_extraUsageResponse)),
      );

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ClaudeUsageDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      expect(find.text('Extra Usage'), findsOneWidget);
      // $12.50 used (1250 cents)
      expect(find.textContaining('\$12.50'), findsOneWidget);
    });

    testWidgets('high usage shows warning style (< 20% remaining)',
        (tester) async {
      final highUsageResponse = json.encode({
        'subscription': 'max',
        'rateLimitTier': 'standard',
        'usage': {
          'five_hour': {
            'utilization': 95.0,
            'resets_at': DateTime.utc(2099).toIso8601String(),
          },
          'seven_day': null,
          'seven_day_opus': null,
          'seven_day_sonnet': null,
          'extra_usage': {'is_enabled': false},
        },
      });
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List.fromList(utf8.encode(highUsageResponse)),
      );

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ClaudeUsageDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      // 5% remaining → warning text
      expect(find.textContaining('5.0% remaining'), findsOneWidget);
    });

    group('subscription label', () {
      for (final tc in [
        ('max', 'Claude Max'),
        ('max_5x', 'Claude Max 5x'),
        ('max_20x', 'Claude Max 20x'),
        ('pro', 'Claude Pro'),
        ('enterprise', 'enterprise'), // unknown → raw value
      ]) {
        final sub = tc.$1;
        final label = tc.$2;
        testWidgets('$sub → $label', (tester) async {
          final resp = json.encode({
            'subscription': sub,
            'rateLimitTier': 'standard',
            'usage': {
              'five_hour': null,
              'seven_day': null,
              'seven_day_opus': null,
              'seven_day_sonnet': null,
              'extra_usage': {'is_enabled': false},
            },
          });
          when(() => mockChannelManager.runCommand(any())).thenAnswer(
            (_) async => Uint8List.fromList(utf8.encode(resp)),
          );

          await tester
              .pumpWidget(buildTestWidget(channelManager: mockChannelManager));
          await tester.pumpAndSettle();

          final context = tester.element(find.byType(Scaffold));
          ClaudeUsageDialog.show(context, 'test-session');
          await tester.pumpAndSettle();

          expect(find.textContaining(label), findsOneWidget);
        });
      }
    });

    testWidgets('uses last JSON line when output has multiple lines',
        (tester) async {
      // The python script might emit warnings/debug lines before the JSON
      final multiLineOutput = 'some warning line\n$_sampleResponse';
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List.fromList(utf8.encode(multiLineOutput)),
      );

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ClaudeUsageDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      // Should parse successfully despite leading non-JSON line
      expect(find.textContaining('Claude Max'), findsOneWidget);
    });
  });
}
