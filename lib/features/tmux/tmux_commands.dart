import '../../core/utils/shell_utils.dart';

/// PTY に送る tmux attach コマンド (末尾 CR つき) を組み立てる。
/// `new-session -A -D` で attach-or-create + 他クライアント detach を 1 発で行う。
/// `tmux_provider` (UI からの attach) と `terminal_connection_provider`
/// (再接続後の自動 re-attach) の両方から共有して、コマンドのズレを防ぐ。
String buildTmuxAttachCommand(String sessionName) {
  final escaped = shellQuote(sessionName);
  return 'tmux new-session -A -D -s $escaped\r';
}
