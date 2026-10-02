/// 自然順比較。数字の連続を数値として扱う (`a2` < `a10`)。
///
/// 文字列を数字チャンクと非数字チャンクに分けて先頭から比較する。
/// - 数字同士: 先頭ゼロを除いた桁数 → 同桁数なら文字列比較 (オーバーフローしない)。
///   数値が等しければ先頭ゼロが少ない方が先 (`a1` < `a01`)。
/// - 非数字同士: 大文字小文字を無視して比較。
/// - 数字 vs 非数字: 数字が先。
/// - 片方が先に尽きたら短い方が先。
/// 全チャンクが同値なら元の文字列の通常比較で決定的にする。
int compareNatural(String a, String b) {
  final ca = _chunks(a);
  final cb = _chunks(b);
  final n = ca.length < cb.length ? ca.length : cb.length;

  // 数値が等しく先頭ゼロ数だけが違う場合のタイブレーク用 (最初の差を採用)。
  var zeroTie = 0;

  for (var i = 0; i < n; i++) {
    final x = ca[i];
    final y = cb[i];
    final xDigit = _isDigit(x.codeUnitAt(0));
    final yDigit = _isDigit(y.codeUnitAt(0));
    if (xDigit != yDigit) return xDigit ? -1 : 1;

    if (xDigit) {
      final xs = _stripZeros(x);
      final ys = _stripZeros(y);
      if (xs.length != ys.length) return xs.length < ys.length ? -1 : 1;
      final c = xs.compareTo(ys);
      if (c != 0) return c < 0 ? -1 : 1;
      if (zeroTie == 0 && x.length != y.length) {
        zeroTie = x.length < y.length ? -1 : 1;
      }
    } else {
      final c = x.toLowerCase().compareTo(y.toLowerCase());
      if (c != 0) return c < 0 ? -1 : 1;
    }
  }

  if (ca.length != cb.length) return ca.length < cb.length ? -1 : 1;
  if (zeroTie != 0) return zeroTie;
  final c = a.compareTo(b);
  return c == 0 ? 0 : (c < 0 ? -1 : 1);
}

bool _isDigit(int u) => u >= 0x30 && u <= 0x39;

String _stripZeros(String s) {
  var i = 0;
  while (i < s.length - 1 && s.codeUnitAt(i) == 0x30) {
    i++;
  }
  return s.substring(i);
}

List<String> _chunks(String s) {
  final out = <String>[];
  var start = 0;
  for (var i = 1; i <= s.length; i++) {
    if (i == s.length ||
        _isDigit(s.codeUnitAt(i)) != _isDigit(s.codeUnitAt(i - 1))) {
      out.add(s.substring(start, i));
      start = i;
    }
  }
  return out;
}
