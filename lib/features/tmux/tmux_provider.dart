import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error/app_error.dart';
import '../../core/ssh/ssh_channel_manager.dart';
import '../../core/utils/app_logger.dart';
import '../../core/utils/shell_utils.dart';
import '../terminal/terminal_connection_provider.dart';
import 'tmux_session_model.dart';

class TmuxNotifier extends FamilyAsyncNotifier<TmuxState, String> {
  // Safe printable separator — '\x1F' can be corrupted by some SSH exec channels.
  static const _sep = '|||';

  SshChannelManager? _channelManager;
  Timer? _refreshTimer;
  bool _isOperating = false;

  /// Called by TerminalScreen when the SSH channelManager changes.
  void setChannelManager(SshChannelManager? channelManager) {
    if (_channelManager == channelManager) return;
    _channelManager = channelManager;
    if (channelManager != null && !_isOperating) {
      _initializeState(channelManager);
    } else if (channelManager == null) {
      state = const AsyncData(TmuxState(availability: TmuxNotInstalled()));
    }
  }

  Future<void> _initializeState(SshChannelManager channelManager) async {
    final prev = state.valueOrNull;
    if (prev == null) {
      state = const AsyncLoading();
    }
    try {
      final availability = await _checkAvailability(channelManager);
      // Stale check: channelManager was replaced or cleared while we were working.
      // Aborting prevents overwriting state set by a later setChannelManager() call.
      if (_channelManager != channelManager) return;
      if (availability is TmuxNotInstalled) {
        state = AsyncData(TmuxState(availability: availability));
        return;
      }
      final sessions = await _fetchSessions(channelManager);
      if (_channelManager != channelManager) return; // stale
      state = AsyncData(TmuxState(availability: availability, sessions: sessions));
    } catch (e, st) {
      // AsyncError にしない — 前回データを維持するか安全なデフォルトを使う
      AppLogger.instance.log('tmux _initializeState error: $e\n$st');
      if (_channelManager != channelManager) return; // stale: do not overwrite newer state
      if (prev != null) {
        state = AsyncData(prev);
      } else {
        state = const AsyncData(TmuxState(availability: TmuxNotInstalled()));
      }
    }
  }

  @override
  Future<TmuxState> build(String arg) async {
    // ドロワーが閉じられても provider を維持する（明示的に invalidate するまで生存）
    ref.keepAlive();
    ref.onDispose(() {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    });
    final channelManager = _channelManager;
    if (channelManager == null) {
      return const TmuxState(availability: TmuxNotInstalled());
    }

    final availability = await _checkAvailability(channelManager);
    if (availability is TmuxNotInstalled) {
      return TmuxState(availability: availability);
    }

    final sessions = await _fetchSessions(channelManager);
    return TmuxState(availability: availability, sessions: sessions);
  }

  Future<void> refresh() async {
    final channelManager = _channelManager;
    if (channelManager == null) return; // AsyncError にしない

    final current = state.valueOrNull;
    if (current == null) {
      // build がまだ完了していない場合も安全に初期化できる
      _initializeState(channelManager);
      return;
    }

    try {
      final sessions = await _fetchSessions(channelManager);
      state = AsyncData(current.copyWith(sessions: sessions));
    } catch (_) {
      // エラーでも前回データを維持
      state = AsyncData(current);
    }
  }

  /// channelManager が null またはエラーが発生しても既存 state を壊さない安全な refresh。
  Future<void> _safeRefresh() async {
    try {
      final channelManager = _channelManager;
      if (channelManager == null) return;
      final current = state.valueOrNull;
      if (current == null) return;
      final sessions = await _fetchSessions(channelManager);
      // stale check: 非同期待機中に channelManager が別インスタンスへ切り替わっていたら
      // 古い結果で新しい channelManager の state を上書きしない。
      if (_channelManager == channelManager) {
        state = AsyncData(current.copyWith(sessions: sessions));
      }
    } catch (_) {
      // refresh 失敗は無視（既存データを維持）
    }
  }

  Future<void> createSession(String name) => _runExclusive(() async {
        final channelManager = _channelManager;
        if (channelManager == null) return;
        final escaped = shellQuote(name);
        await _execCommand(channelManager, 'tmux new-session -d -s $escaped');
        // 新規セッションの mouse mode を有効化（スワイプスクロール対応）
        await _execCommand(
          channelManager,
          'tmux set-option -t $escaped mouse on',
        ).catchError((_) {});
      });

  Future<void> killSession(String name) => _runExclusive(
        () async {
          final channelManager = _channelManager;
          if (channelManager == null) return;
          final escaped = shellQuote(name);
          await _execCommand(channelManager, 'tmux kill-session -t $escaped');
        },
        swallowErrors: true, // セッション不在等は正常扱い
      );

  Future<void> renameSession(String oldName, String newName) => _runExclusive(
        () async {
          final channelManager = _channelManager;
          if (channelManager == null) return;
          final escapedOld = shellQuote(oldName);
          final escapedNew = shellQuote(newName);
          await _execCommand(
            channelManager,
            'tmux rename-session -t $escapedOld $escapedNew',
          );
        },
        swallowErrors: true, // セッション不在・名前衝突等は正常扱い
      );

  /// Runs [operation] exclusively under the [_isOperating] guard.
  /// Returns early (no-op) if another operation is already in progress.
  /// If [swallowErrors] is true, exceptions from [operation] are silently
  /// discarded; otherwise they propagate to the caller.
  Future<void> _runExclusive(
    Future<void> Function() operation, {
    bool swallowErrors = false,
  }) async {
    if (_isOperating) return;
    _isOperating = true;
    try {
      await operation();
    } catch (_) {
      if (!swallowErrors) rethrow;
    } finally {
      _isOperating = false;
      await _safeRefresh();
    }
  }

  /// Attaches to a session by writing the command to the PTY channel.
  /// attach 前に mouse mode をオンにし、スワイプスクロールを有効化する。
  void attachSession(String name) {
    final connectionState = ref.read(terminalConnectionProvider(arg));
    final terminal = connectionState.terminal;
    if (terminal == null) return;
    final escaped = shellQuote(name);
    // セッションレベルで mouse mode を有効化（グローバル設定には影響しない）
    _enableTmuxMouse(name);
    terminal.textInput('tmux attach -t $escaped\r');
  }

  /// tmux セッションの mouse mode をオンにする。
  /// exec チャネルで実行するため PTY 出力には影響しない。
  void _enableTmuxMouse(String sessionName) {
    final channelManager = _channelManager;
    if (channelManager == null) return;
    final escaped = shellQuote(sessionName);
    // fire-and-forget: 失敗しても attach 自体に影響しない
    _execCommand(channelManager, 'tmux set-option -t $escaped mouse on')
        .catchError((_) {});
  }

  /// Starts periodic auto-refresh (every 10 seconds). Called when tmux drawer opens.
  void startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      refresh();
    });
  }

  /// Stops periodic auto-refresh. Called when tmux drawer closes.
  void stopAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  /// テスト専用: state を直接設定する。
  /// _initializeState のエラーリカバリー（prev != null のデータ維持）を
  /// テストするために使用する。
  @visibleForTesting
  void setStateForTesting(TmuxState value) {
    state = AsyncData(value);
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Future<TmuxAvailability> _checkAvailability(
      SshChannelManager channelManager) async {
    try {
      // tmux -V はインストールされていなければ失敗するため
      // command -v tmux との2段階チェックは不要
      final (versionOutput, _, exitCode) =
          await _runCommand(channelManager, 'tmux -V');
      if (exitCode != null && exitCode != 0) return const TmuxNotInstalled();
      final version = versionOutput.trim();
      // exitCode が null（dartssh2 の制約）かつ出力が tmux バージョン形式でない場合は
      // tmux 未インストールと判断する
      if (version.isEmpty || !version.toLowerCase().startsWith('tmux')) {
        return const TmuxNotInstalled();
      }
      return TmuxAvailable(version: version);
    } catch (_) {
      return const TmuxNotInstalled();
    }
  }

  Future<List<TmuxSession>> _fetchSessions(
      SshChannelManager channelManager) async {
    final formatCmd =
        "tmux list-sessions -F "
        "'#{session_name}$_sep#{session_windows}$_sep"
        "#{session_attached}$_sep#{session_created}'";

    final (output, stderr, exitCode) =
        await _runCommand(channelManager, formatCmd);

    // exit code != 0 means no sessions or tmux server not running.
    // exitCode == null は dartssh2 の制約として成功扱い。
    if (exitCode != null && exitCode != 0) {
      if (stderr.toLowerCase().contains('no server running') ||
          stderr.toLowerCase().contains('no sessions')) {
        return [];
      }
      AppLogger.instance.log('tmux list-sessions error (exit $exitCode): $stderr');
      return [];
    }

    final sessions = <TmuxSession>[];
    for (final line in output.trim().split('\n')) {
      if (line.isEmpty) continue;
      final parts = line.split(_sep);
      if (parts.length != 4) {
        AppLogger.instance.log('tmux parse skip (${parts.length} fields): $line');
        continue;
      }
      sessions.add(TmuxSession(
        name: parts[0],
        windowCount: int.tryParse(parts[1]) ?? 0,
        isAttached: parts[2] == '1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (int.tryParse(parts[3]) ?? 0) * 1000,
        ),
      ));
    }

    // 各セッションの全 pane を capture-pane して Claude 稼働状態を判定。
    // 失敗してもセッション一覧自体には影響させない（best-effort）。
    if (sessions.isNotEmpty) {
      final claudeMap =
          await _detectClaudeRunningPerSession(channelManager, sessions);
      return [
        for (final s in sessions)
          s.copyWith(claudeRunning: claudeMap[s.name] ?? false),
      ];
    }
    return sessions;
  }

  /// 各 tmux セッションの全 pane の見える内容を取得し、
  /// Claude Code 稼働中シグナル（spinner / "esc to interrupt" / Tip）を検出。
  /// セッション名 → 稼働中 bool のマップを返す。
  Future<Map<String, bool>> _detectClaudeRunningPerSession(
    SshChannelManager channelManager,
    List<TmuxSession> sessions,
  ) async {
    // 区切りマーカーで各セッションの出力を 1 回の SSH exec にまとめる。
    const sessionMarker = '=GoroSess:';
    final cmds = sessions.map((s) {
      final name = shellQuote(s.name);
      return "echo '$sessionMarker${s.name}'; "
          "tmux list-panes -s -t $name -F '#{pane_id}' 2>/dev/null | "
          "while read p; do tmux capture-pane -t \"\$p\" -p -S -15 2>/dev/null; done";
    }).join('; ');

    try {
      final (output, _, _) = await _runCommand(
        channelManager,
        cmds,
        timeout: const Duration(seconds: 8),
      );
      return _parseClaudeRunningOutput(output, sessionMarker);
    } catch (e) {
      AppLogger.instance.log('tmux capture-pane failed: $e');
      return const {};
    }
  }

  /// `_detectClaudeRunningPerSession` の出力をパース。
  /// テスト容易性のため別メソッドに切り出し。
  static Map<String, bool> _parseClaudeRunningOutput(
    String output,
    String marker,
  ) {
    final map = <String, bool>{};
    String? currentSession;
    final buf = StringBuffer();

    void flush() {
      final s = currentSession;
      if (s != null) {
        map[s] = _bufferLooksLikeClaudeRunning(buf.toString());
        buf.clear();
      }
    }

    for (final line in output.split('\n')) {
      if (line.startsWith(marker)) {
        flush();
        currentSession = line.substring(marker.length);
      } else {
        buf.writeln(line);
      }
    }
    flush();
    return map;
  }

  /// バッファ末尾を見て Claude Code 稼働中シグナルを検出。
  /// terminal_connection_provider.dart の判定と同等。
  static bool _bufferLooksLikeClaudeRunning(String text) {
    if (text.isEmpty) return false;
    final lines = text.split('\n');
    final start = (lines.length - 12).clamp(0, lines.length);
    for (var i = start; i < lines.length; i++) {
      final line = lines[i];
      if (line.contains('esc to interrupt')) return true;
      if (line.contains('tokens') && _spinnerVerbPattern.hasMatch(line)) {
        return true;
      }
      if (line.contains('Tip: Use /')) return true;
    }
    return false;
  }

  /// `Forming…`, `Thinking…`, `Pondering…` 等の動名詞 + 三点リーダパターン。
  static final RegExp _spinnerVerbPattern =
      RegExp(r'\w+(ing|ed)\s*[…\.]');

  /// Runs a command via exec channel and collects stdout, stderr, and exit code.
  /// Throws [TimeoutException] if the command does not complete within [timeout].
  /// The SSH exec channel is always closed in a finally block (even on timeout).
  Future<(String output, String error, int? exitCode)> _runCommand(
    SshChannelManager channelManager,
    String command, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final session = await channelManager.executeCommand(command);
    try {
      // Collect stdout and stderr in parallel to avoid serial timeout accumulation.
      // cast<List<int>>() is required because Stream<Uint8List> is not a subtype
      // of Stream<List<int>> in Dart's type system despite Uint8List implementing
      // List<int>.  This matches the pattern used in _readAbsolutePath().
      const decoder = Utf8Decoder(allowMalformed: true);
      final results = await Future.wait<String>([
        session.stdout.cast<List<int>>().transform(decoder).join(),
        session.stderr.cast<List<int>>().transform(decoder).join(),
      ]).timeout(timeout);
      // Use a short close-ACK timeout: once both streams are drained the server
      // has sent EOF, so the channel close handshake should complete within a
      // network round-trip.  Reusing the full `timeout` here would double the
      // worst-case blocking time (e.g. 15 s → 30 s).
      // Swallow TimeoutException: the output has already been collected, so a
      // slow close-ACK must not discard the result.  session.close() in the
      // finally block will clean up the SSH channel regardless.
      try {
        await session.done.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // Close-ACK was slow but output is already available — treat as success.
      }
      return (results[0], results[1], session.exitCode);
    } finally {
      try { session.close(); } catch (_) {}
    }
  }

  Future<void> _execCommand(
    SshChannelManager channelManager,
    String command,
  ) async {
    final (_, _, exitCode) = await _runCommand(channelManager, command);
    // exitCode == null は dartssh2 の制約として成功扱い
    if (exitCode != null && exitCode != 0) {
      throw TmuxError(
        'Command failed (exit $exitCode): $command',
        reason: TmuxErrorReason.unknown,
      );
    }
  }
}

final tmuxProvider =
    AsyncNotifierProvider.family<TmuxNotifier, TmuxState, String>(
  TmuxNotifier.new,
);

/// Validates a tmux session name (no spaces, no dots, non-empty).
String? validateTmuxSessionName(String name, List<String> existingNames) {
  if (name.isEmpty) return 'Session name cannot be empty';
  if (name.contains(' ')) return 'Session name cannot contain spaces';
  if (name.contains('.')) return 'Session name cannot contain dots';
  if (name.contains(':')) return 'Session name cannot contain colons';
  if (name.contains(TmuxNotifier._sep)) {
    return "Session name cannot contain '${TmuxNotifier._sep}'";
  }
  if (existingNames.contains(name)) return 'Session "$name" already exists';
  return null;
}
