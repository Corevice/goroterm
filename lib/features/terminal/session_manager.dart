import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/background/ssh_foreground_service.dart';
import 'terminal_connection_provider.dart';

class TerminalSession {
  const TerminalSession({
    required this.sessionId,
    required this.connectionId,
    required this.label,
    this.tmuxSessionName,
  });

  final String sessionId;
  final int connectionId;
  final String label;

  /// The tmux session name this tab is attached to, or null for plain shells.
  final String? tmuxSessionName;
}

class SessionManagerState {
  const SessionManagerState({
    this.sessions = const [],
    this.activeSessionId,
    this.batteryWarning = false,
  });

  final List<TerminalSession> sessions;
  final String? activeSessionId;
  final bool batteryWarning;

  SessionManagerState copyWith({
    List<TerminalSession>? sessions,
    String? activeSessionId,
    bool clearActiveSessionId = false,
    bool? batteryWarning,
  }) {
    return SessionManagerState(
      sessions: sessions ?? this.sessions,
      activeSessionId: clearActiveSessionId
          ? null
          : (activeSessionId ?? this.activeSessionId),
      batteryWarning: batteryWarning ?? this.batteryWarning,
    );
  }
}

class SessionManagerNotifier extends Notifier<SessionManagerState> {
  int _sessionCounter = 0;

  @override
  SessionManagerState build() => const SessionManagerState();

  /// Adds a new terminal session for the given connection.
  /// Returns the generated sessionId.
  String addSession({required int connectionId, required String label}) {
    _sessionCounter++;
    final sessionId = 'session_${connectionId}_$_sessionCounter';
    final session = TerminalSession(
      sessionId: sessionId,
      connectionId: connectionId,
      label: label,
    );
    final updated = [...state.sessions, session];
    state = state.copyWith(sessions: updated, activeSessionId: sessionId);

    // フォアグラウンドサービスを開始/更新
    SshForegroundService.ensureRunning(sessionCount: updated.length)
        .then((batteryOk) {
      if (!batteryOk) {
        state = state.copyWith(batteryWarning: true);
      }
    });

    return sessionId;
  }

  /// Removes the session and invalidates its provider.
  void removeSession(String sessionId) {
    final updated =
        state.sessions.where((s) => s.sessionId != sessionId).toList();
    // Invalidate the connection provider for the removed session.
    ref.invalidate(terminalConnectionProvider(sessionId));

    String? newActive = state.activeSessionId;
    if (newActive == sessionId) {
      newActive = updated.isNotEmpty ? updated.last.sessionId : null;
    }
    state = SessionManagerState(sessions: updated, activeSessionId: newActive);

    // 全セッション終了時にサービスを停止、それ以外は通知更新
    if (updated.isEmpty) {
      SshForegroundService.stop();
    } else {
      SshForegroundService.ensureRunning(sessionCount: updated.length)
          .then((batteryOk) {
        if (!batteryOk) {
          state = state.copyWith(batteryWarning: true);
        }
      });
    }
  }

  /// Switches the active (visible) tab.
  void setActiveSession(String sessionId) {
    state = state.copyWith(activeSessionId: sessionId);
  }

  /// Returns the sessionId of an existing tab that is attached to the given
  /// tmux session on the same connection, or null if none exists.
  String? findSessionByTmux(int connectionId, String tmuxSessionName) {
    for (final session in state.sessions) {
      if (session.connectionId == connectionId &&
          session.tmuxSessionName == tmuxSessionName) {
        return session.sessionId;
      }
    }
    return null;
  }

  /// Adds a new tab for a tmux session attach and sets it active.
  /// Returns the generated sessionId.
  String addTmuxSession({
    required int connectionId,
    required String tmuxSessionName,
  }) {
    _sessionCounter++;
    final sessionId = 'session_${connectionId}_$_sessionCounter';
    final session = TerminalSession(
      sessionId: sessionId,
      connectionId: connectionId,
      label: 'tmux: $tmuxSessionName',
      tmuxSessionName: tmuxSessionName,
    );
    final updated = [...state.sessions, session];
    state = state.copyWith(sessions: updated, activeSessionId: sessionId);
    SshForegroundService.ensureRunning(sessionCount: updated.length)
        .then((batteryOk) {
      if (!batteryOk) {
        state = state.copyWith(batteryWarning: true);
      }
    });
    return sessionId;
  }
}

final sessionManagerProvider =
    NotifierProvider<SessionManagerNotifier, SessionManagerState>(
  SessionManagerNotifier.new,
);
