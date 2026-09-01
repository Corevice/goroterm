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

/// tmux がインストールされているかどうかを判定できなかった状態。
///
/// 「未インストールと確定した」(`TmuxNotInstalled`) とは区別する。接続直後は
/// SSH の exec チャネルがまだ不安定で `tmux -V` が一時的に失敗したり空応答を
/// 返したりすることがあり、それを未インストールと誤判定すると、実際には
/// tmux があるのに直前まで表示されていたセッション一覧が「未インストール」
/// 画面に置き換わってしまう（一瞬表示されて消えるフラッシュの原因）。
class TmuxUnknown extends TmuxAvailability {
  const TmuxUnknown();
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
