/// 接続時に SSH exec で実行する、`claude` ラッパー関数をサーバのシェル rc に
/// 管理するコマンドを組み立てる。
///
/// 目的: 接続ごとに設定された「Claude システムプロンプトファイル」のパスを使い、
/// ユーザーが `claude` を実行したときに自動で `--system-prompt-file <path>` が
/// 付くようにする。PTY ではなく exec で rc を書き換えるため、実行中の claude に
/// 割り込まない。
///
/// 仕様:
///  - [path] が空/null のときは、既存の管理ブロックを除去するだけ
///    （= 従来どおり素の `claude`。設定なしの接続では rc を変更しない）。
///  - [path] が設定されているときは、~/.bashrc / ~/.zshrc の管理ブロックを
///    更新（除去してから再追記）して関数を定義する。
///  - 関数はプロンプトファイルが存在しない場合は素の `claude` にフォールバック。
library;

const _beginMarker = '# >>> goroterm claude >>>';
const _endMarker = '# <<< goroterm claude <<<';

/// awk の状態機械で管理ブロック（開始〜終了マーカー含む）を 1 ファイルから除去。
/// sed -i の GNU/BSD 差異を避けるため awk + 一時ファイルで実装。
const _removeBlock =
    "awk '/>>> goroterm claude >>>/{s=1} /<<< goroterm claude <<</{s=0;next} !s' "
    "\"\$rc\" > \"\$rc.gtmp\" && mv \"\$rc.gtmp\" \"\$rc\"";

/// 単一引用符で囲んだシェル文字列リテラルにする（内部の ' を '\'' に退避）。
String _singleQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// rc に書き込む関数定義内で、パスをダブルクォート内に置くためのエスケープ。
/// `$HOME` 等の環境変数は実行時に展開させたいので `$` はエスケープしない。
String _escapeForDoubleQuotes(String s) =>
    s.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('`', r'\`');

/// 先頭の `~` を `$HOME` に正規化し、ダブルクォート用にエスケープしたパス式を返す。
String _pathExpr(String rawPath) {
  var p = rawPath.trim();
  if (p == '~') {
    p = r'$HOME';
  } else if (p.startsWith('~/')) {
    p = '\$HOME/${p.substring(2)}';
  }
  return _escapeForDoubleQuotes(p);
}

/// [path] が設定されていれば true（空白のみは未設定扱い）。
bool claudeRcPathIsSet(String? path) => path != null && path.trim().isNotEmpty;

/// rc 管理コマンドを返す。サーバ上のログインシェルで実行される前提。
String buildClaudeRcSetupCommand(String? path) {
  // どのファイルが存在しても確実に除去できるよう、両 rc を走査して除去する。
  const removeForAllRcs = '''
for rc in "\$HOME/.bashrc" "\$HOME/.zshrc"; do
  if [ -e "\$rc" ] && grep -q '>>> goroterm claude >>>' "\$rc" 2>/dev/null; then
    $_removeBlock
  fi
done''';

  if (!claudeRcPathIsSet(path)) {
    // 未設定: 既存ブロックの除去のみ（設定なしの接続では実質 no-op）。
    return removeForAllRcs;
  }

  final p = _pathExpr(path!);
  // プロンプトファイルが無ければ素の claude にフォールバックする安全な関数。
  final func =
      'claude() { if [ -f "$p" ]; then command claude --system-prompt-file "$p" "\$@"; '
      'else command claude "\$@"; fi; }';

  final beginQ = _singleQuote(_beginMarker);
  final funcQ = _singleQuote(func);
  final endQ = _singleQuote(_endMarker);
  final append = "printf '%s\\n' $beginQ $funcQ $endQ >> \"\$rc\"";

  // 既存ブロックを除去してから新しいブロックを追記。存在する rc に対して行い、
  // どちらも無ければ ~/.bashrc を作成して追記する。
  return '''
__gt_apply() {
  rc="\$1"
  if [ -e "\$rc" ] && grep -q '>>> goroterm claude >>>' "\$rc" 2>/dev/null; then
    $_removeBlock
  fi
  $append
}
__gt_any=0
for rc in "\$HOME/.bashrc" "\$HOME/.zshrc"; do
  if [ -e "\$rc" ]; then __gt_apply "\$rc"; __gt_any=1; fi
done
if [ "\$__gt_any" = 0 ]; then rc="\$HOME/.bashrc"; __gt_apply "\$rc"; fi''';
}
