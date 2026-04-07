import 'package:flutter/foundation.dart';
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
    return _createSession(connectionId: connectionId, label: label);
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
    state = state.copyWith(
      sessions: updated,
      activeSessionId: newActive,
      clearActiveSessionId: newActive == null,
    );

    // 全セッション終了時にサービスを停止、それ以外は通知更新
    if (updated.isEmpty) {
      SshForegroundService.stop();
    } else {
      _updateForegroundService(updated.length);
    }
  }

  /// Reorders sessions by moving the item at [oldIndex] to [newIndex].
  void reorderSessions(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    final updated = List<TerminalSession>.from(state.sessions);
    final item = updated.removeAt(oldIndex);
    updated.insert(newIndex, item);
    state = state.copyWith(sessions: updated);
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
    return _createSession(
      connectionId: connectionId,
      label: 'tmux: $tmuxSessionName',
      tmuxSessionName: tmuxSessionName,
    );
  }

  /// Creates a session, appends it to state, and starts the foreground service.
  /// Returns the generated sessionId.
  String _createSession({
    required int connectionId,
    required String label,
    String? tmuxSessionName,
  }) {
    _sessionCounter++;
    final sessionId = 'session_${connectionId}_$_sessionCounter';
    final session = TerminalSession(
      sessionId: sessionId,
      connectionId: connectionId,
      label: label,
      tmuxSessionName: tmuxSessionName,
    );
    final updated = [...state.sessions, session];
    state = state.copyWith(sessions: updated, activeSessionId: sessionId);
    _updateForegroundService(updated.length);
    return sessionId;
  }

  /// テスト専用: batteryWarning フラグを直接設定する。
  @visibleForTesting
  void setBatteryWarningForTesting(bool value) {
    state = state.copyWith(batteryWarning: value);
  }

  /// フォアグラウンドサービスを開始/更新し、バッテリー最適化警告を処理する。
  void _updateForegroundService(int sessionCount) {
    SshForegroundService.ensureRunning(sessionCount: sessionCount)
        .then((batteryOk) {
      if (!batteryOk) {
        state = state.copyWith(batteryWarning: true);
      }
    });
  }
}

final sessionManagerProvider =
    NotifierProvider<SessionManagerNotifier, SessionManagerState>(
  SessionManagerNotifier.new,
);
