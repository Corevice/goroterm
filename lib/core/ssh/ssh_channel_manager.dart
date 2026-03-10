import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../error/app_error.dart';
import '../utils/shell_utils.dart';

class SshChannelManager {
  SshChannelManager({required this.client});

  final SSHClient client;
  SSHSession? _ptySession;
  SftpClient? _sftpClient;

  SSHSession? get ptySession => _ptySession;

  Future<SSHSession> openPtyChannel({
    int width = 80,
    int height = 24,
  }) async {
    try {
      _ptySession = await client.shell(
        pty: SSHPtyConfig(
          type: 'xterm-256color',
          width: width,
          height: height,
        ),
        environment: {'LANG': 'ja_JP.UTF-8'},
      );
      return _ptySession!;
    } catch (e) {
      throw NetworkError('Failed to open PTY channel: $e');
    }
  }

  Future<SSHSession> executeCommand(String command) async {
    try {
      return await client.execute(command);
    } catch (e) {
      throw NetworkError('Failed to execute command: $e');
    }
  }

  Future<Uint8List> runCommand(String command) async {
    try {
      return await client.run(command);
    } catch (e) {
      throw NetworkError('Failed to run command: $e');
    }
  }

  Future<SftpClient> openSftpChannel() async {
    try {
      _sftpClient = await client.sftp();
      return _sftpClient!;
    } catch (e) {
      throw NetworkError('Failed to open SFTP channel: $e');
    }
  }

  /// リモートシェルの推定カレントディレクトリを取得する。
  /// /proc ファイルシステムを利用して PTY シェルの CWD を読み取る。
  /// 取得できない場合（非 Linux、権限不足等）は null を返す。
  Future<String?> getShellCwd() async {
    try {
      // 方式1: $PPID = この exec チャネルの親 = この SSH 接続の sshd プロセス
      // 同じ sshd の子で pts 上のシェルプロセスの CWD を取得
      // → タブ（SSH 接続）ごとに正しい CWD が返る
      // 方式2 (フォールバック): tmux 内等で $PPID がマッチしない場合、
      //   従来の tail -1 で最新シェルの CWD を返す（1タブなら正確）
      final session = await client.execute(
        r"CWD=$(readlink /proc/$(ps --no-headers -o pid,ppid,tty,comm -u $(whoami) "
        r"| awk -v ppid=$PPID "
        r"'$2==ppid && $3 ~ /pts\// && $4 ~ /bash|zsh|fish|sh$/ {print $1; exit}'"
        r")/cwd 2>/dev/null); "
        r'if [ -n "$CWD" ]; then echo "$CWD"; else '
        r"readlink /proc/$(ps --no-headers -u $(whoami) -o pid,tty,comm "
        r"| grep 'pts/' | grep -E 'bash|zsh|fish|sh$' "
        r"| tail -1 | awk '{print $1}')/cwd 2>/dev/null; fi",
      );
      final output = await session.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 5), onTimeout: () => '');
      final cwd = output.trim();
      if (cwd.isNotEmpty && cwd.startsWith('/')) {
        return cwd;
      }
    } catch (_) {
      // コマンド実行失敗（非 Linux、権限不足等）→ null を返す
    }
    return null;
  }

  /// tmux セッションのアクティブペインの CWD を取得する。
  /// tmux がインストールされていない場合や対象セッションが存在しない場合は null。
  Future<String?> getTmuxPaneCwd(String tmuxSessionName) async {
    try {
      final session = await client.execute(
        "tmux display-message -p -t ${shellQuote(tmuxSessionName)} '#{pane_current_path}' 2>/dev/null",
      );
      final output = await session.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 5), onTimeout: () => '');
      final cwd = output.trim();
      if (cwd.isNotEmpty && cwd.startsWith('/')) {
        return cwd;
      }
    } catch (_) {
      // tmux が使えない場合は null
    }
    return null;
  }

  /// 高速ファイルダウンロード: cat コマンドの SSHSession を返す。
  /// 呼び出し元で session.stdout を消費後、session.close() を呼んで
  /// SSH チャネル（2MB ウィンドウバッファ）を解放すること。
  Future<SSHSession> openExecStream(String remotePath) async {
    try {
      return await client.execute("cat ${shellQuote(remotePath)}");
    } catch (e) {
      throw NetworkError('Failed to open exec stream: $e');
    }
  }

  void resizePty(int width, int height) {
    _ptySession?.resizeTerminal(width, height);
  }

  void dispose() {
    try { _ptySession?.close(); } catch (_) {}
    try { _sftpClient?.close(); } catch (_) {}
    _ptySession = null;
    _sftpClient = null;
  }
}
