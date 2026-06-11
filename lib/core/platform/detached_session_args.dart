import 'dart:convert';

/// タブ分離ウィンドウ（macOS）の起動引数。
///
/// ネイティブ側（MainFlutterWindow.swift の DetachedWindowManager）が
/// 第二 Flutter エンジンを起動する際に dartEntrypointArguments として渡す。
/// tmux セッション名は任意文字列のため base64 で運ぶ。
class DetachedSessionArgs {
  const DetachedSessionArgs({
    required this.connectionId,
    required this.tmuxSessionName,
  });

  /// Drift DB 上の接続 ID。
  final int connectionId;

  /// attach する tmux セッション名。
  final String tmuxSessionName;

  static const _connectionIdPrefix = '--detach-connection-id=';
  static const _tmuxB64Prefix = '--detach-tmux-b64=';

  /// main(args) から分離ウィンドウ引数を取り出す。通常起動なら null。
  static DetachedSessionArgs? tryParse(List<String> args) {
    int? connectionId;
    String? tmuxSessionName;
    for (final arg in args) {
      if (arg.startsWith(_connectionIdPrefix)) {
        connectionId = int.tryParse(arg.substring(_connectionIdPrefix.length));
      } else if (arg.startsWith(_tmuxB64Prefix)) {
        try {
          tmuxSessionName =
              utf8.decode(base64.decode(arg.substring(_tmuxB64Prefix.length)));
        } catch (_) {
          return null;
        }
      }
    }
    if (connectionId == null || tmuxSessionName == null) return null;
    return DetachedSessionArgs(
      connectionId: connectionId,
      tmuxSessionName: tmuxSessionName,
    );
  }
}
