import '../../core/utils/shell_utils.dart';

/// PTY に送る tmux attach コマンド (末尾 CR つき) を組み立てる。
/// `new-session -A` で attach-or-create を 1 発で行う。
/// `tmux_provider` (UI からの attach) と `terminal_connection_provider`
/// (再接続後の自動 re-attach) の両方から共有して、コマンドのズレを防ぐ。
///
/// このコマンドはシェルのプロンプトにキー入力として打ち込まれるため、
/// 何もしないとユーザーのシェル履歴 (.bash_history 等) が
/// `tmux new-session -A -s ...` だらけになる。これを避けるため先頭に
/// 半角スペースを付ける: bash の `HISTCONTROL=ignorespace`/`ignoreboth`
/// (Ubuntu の既定) や zsh の `setopt HIST_IGNORE_SPACE` が有効なら、
/// スペースで始まるコマンドは履歴に記録されない。
///
/// 注: 以前は `-D` を付けて他クライアントを強制 detach していたが、
/// 「アプリがバックグラウンド復帰時に自分自身が detach される」現象が
/// 発生したため取り除いた。複数端末で同じセッションを奪いたい場合は、
/// ユーザーが手動で `tmux attach -d` を打てばよい。
String buildTmuxAttachCommand(String sessionName) {
  final escaped = shellQuote(sessionName);
  return ' tmux new-session -A -s $escaped\r';
}
