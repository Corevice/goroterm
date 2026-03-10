import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error/app_error.dart';
import '../../core/ssh/ssh_channel_manager.dart';
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
      if (availability is TmuxNotInstalled) {
        state = AsyncData(TmuxState(availability: availability));
        return;
      }
      final sessions = await _fetchSessions(channelManager);
      state = AsyncData(TmuxState(availability: availability, sessions: sessions));
    } catch (e, st) {
      // AsyncError にしない — 前回データを維持するか安全なデフォルトを使う
      debugPrint('tmux _initializeState error: $e\n$st');
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
      // dispose 済みでないことを確認（channelManager が変わっていないか）
      if (_channelManager != null) {
        state = AsyncData(current.copyWith(sessions: sessions));
      }
    } catch (_) {
      // refresh 失敗は無視（既存データを維持）
    }
  }

  Future<void> createSession(String name) async {
    if (_isOperating) return;
    _isOperating = true;
    try {
      final channelManager = _channelManager;
      if (channelManager == null) return;
      final escaped = shellEscape(name);
      await _execCommand(channelManager, 'tmux new-session -d -s $escaped');
      // 新規セッションの mouse mode を有効化（スワイプスクロール対応）
      await _execCommand(
        channelManager,
        'tmux set-option -t $escaped mouse on',
      ).catchError((_) {});
    } finally {
      _isOperating = false;
      await _safeRefresh();
    }
  }

  Future<void> killSession(String name) async {
    if (_isOperating) return;
    _isOperating = true;
    try {
      final channelManager = _channelManager;
      if (channelManager == null) return;
      final escaped = shellEscape(name);
      await _execCommand(channelManager, 'tmux kill-session -t $escaped');
    } catch (_) {
      // エラーは握り潰す（セッション不在等は正常扱い）
    } finally {
      _isOperating = false;
      await _safeRefresh();
    }
  }

  Future<void> renameSession(String oldName, String newName) async {
    if (_isOperating) return;
    _isOperating = true;
    try {
      final channelManager = _channelManager;
      if (channelManager == null) return;
      final escapedOld = shellEscape(oldName);
      final escapedNew = shellEscape(newName);
      await _execCommand(
        channelManager,
        'tmux rename-session -t $escapedOld $escapedNew',
      );
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
    final escaped = shellEscape(name);
    // セッションレベルで mouse mode を有効化（グローバル設定には影響しない）
    _enableTmuxMouse(name);
    terminal.textInput('tmux attach -t $escaped\r');
  }

  /// tmux セッションの mouse mode をオンにする。
  /// exec チャネルで実行するため PTY 出力には影響しない。
  void _enableTmuxMouse(String sessionName) {
    final channelManager = _channelManager;
    if (channelManager == null) return;
    final escaped = shellEscape(sessionName);
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

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Future<TmuxAvailability> _checkAvailability(
      SshChannelManager channelManager) async {
    try {
      final (_, _, exitCode) =
          await _runCommand(channelManager, 'command -v tmux');
      if (exitCode != null && exitCode != 0) return const TmuxNotInstalled();

      final (versionOutput, _, _) =
          await _runCommand(channelManager, 'tmux -V');
      return TmuxAvailable(version: versionOutput.trim());
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
      debugPrint('tmux list-sessions error (exit $exitCode): $stderr');
      return [];
    }

    final sessions = <TmuxSession>[];
    for (final line in output.trim().split('\n')) {
      if (line.isEmpty) continue;
      final parts = line.split(_sep);
      if (parts.length != 4) {
        debugPrint('tmux parse skip (${parts.length} fields): $line');
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
    return sessions;
  }

  /// Runs a command via exec channel and collects stdout, stderr, and exit code.
  Future<(String output, String error, int? exitCode)> _runCommand(
    SshChannelManager channelManager,
    String command,
  ) async {
    final session = await channelManager.executeCommand(command);
    final stdoutChunks = await session.stdout.toList();
    final stderrChunks = await session.stderr.toList();
    await session.done;
    final output = utf8.decode(
      stdoutChunks.expand((e) => e).toList(),
      allowMalformed: true,
    );
    final error = utf8.decode(
      stderrChunks.expand((e) => e).toList(),
      allowMalformed: true,
    );
    return (output, error, session.exitCode);
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

// ---------------------------------------------------------------------------
// Shell escape utility for tmux session names
// ---------------------------------------------------------------------------

/// Wraps [value] in single quotes and escapes embedded single quotes.
String shellEscape(String value) => shellQuote(value);

/// Validates a tmux session name (no spaces, no dots, non-empty).
String? validateTmuxSessionName(String name, List<String> existingNames) {
  if (name.isEmpty) return 'Session name cannot be empty';
  if (name.contains(' ')) return 'Session name cannot contain spaces';
  if (name.contains('.')) return 'Session name cannot contain dots';
  if (name.contains(':')) return 'Session name cannot contain colons';
  if (existingNames.contains(name)) return 'Session "$name" already exists';
  return null;
}
