/// A tmux session.
class TmuxSession {
  const TmuxSession({
    required this.name,
    required this.windowCount,
    required this.isAttached,
    required this.createdAt,
    this.claudeRunning = false,
  });

  final String name;
  final int windowCount;
  final bool isAttached;
  final DateTime createdAt;

  /// Claude Code がこの tmux セッションで稼働中かどうか。
  /// `tmux capture-pane` の出力から spinner / "esc to interrupt" 等を検知。
  final bool claudeRunning;

  TmuxSession copyWith({bool? claudeRunning}) => TmuxSession(
        name: name,
        windowCount: windowCount,
        isAttached: isAttached,
        createdAt: createdAt,
        claudeRunning: claudeRunning ?? this.claudeRunning,
      );

  @override
  String toString() =>
      'TmuxSession(name: $name, windows: $windowCount, '
      'attached: $isAttached, created: $createdAt, '
      'claudeRunning: $claudeRunning)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TmuxSession &&
          name == other.name &&
          windowCount == other.windowCount &&
          isAttached == other.isAttached &&
          createdAt == other.createdAt &&
          claudeRunning == other.claudeRunning;

  @override
  int get hashCode =>
      Object.hash(name, windowCount, isAttached, createdAt, claudeRunning);
}

/// Whether tmux is installed on the remote server.
sealed class TmuxAvailability {
  const TmuxAvailability();
}

class TmuxAvailable extends TmuxAvailability {
  const TmuxAvailable({required this.version});
  final String version;
}

class TmuxNotInstalled extends TmuxAvailability {
  const TmuxNotInstalled();
}

/// Combined state returned by [TmuxNotifier].
class TmuxState {
  const TmuxState({
    required this.availability,
    this.sessions = const [],
  });

  final TmuxAvailability availability;
  final List<TmuxSession> sessions;

  bool get isAvailable => availability is TmuxAvailable;

  TmuxState copyWith({
    TmuxAvailability? availability,
    List<TmuxSession>? sessions,
  }) {
    return TmuxState(
      availability: availability ?? this.availability,
      sessions: sessions ?? this.sessions,
    );
  }
}
