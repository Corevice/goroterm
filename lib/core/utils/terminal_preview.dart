/// 端末バッファの行テキスト列から、通知に載せる「Claude が最後に何をしたか」の
/// プレビュー文字列を作る純関数。罫線・入力ボックス・ヒント等の UI 装飾を除いた
/// 意味のある行を末尾から数行拾って上から順に並べる。取れなければ null。
library;

final RegExp _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);
final RegExp _leadingDecoration = RegExp(r'^[\s─-╿│┃|>❯⏵◍●○•*\-]+');

/// [lines] は上から順の行テキスト（ANSI 除去済み）。
String? extractNotificationPreview(
  List<String> lines, {
  int maxLines = 20,
  int maxChars = 2000,
}) {
  final picked = <String>[];
  for (var y = lines.length - 1; y >= 0 && picked.length < maxLines; y--) {
    final raw = lines[y].trimRight();
    if (isChromeLine(raw)) continue;
    final cleaned = raw.replaceFirst(_leadingDecoration, '').trimRight();
    if (cleaned.trim().isEmpty) continue;
    picked.add(cleaned);
  }
  if (picked.isEmpty) return null;
  final preview = picked.reversed.join('\n');
  return preview.length > maxChars
      ? '${preview.substring(0, maxChars).trimRight()}…'
      : preview;
}

/// UI 装飾行（罫線・入力ボックス・ヒント・ステータス）かどうか。
bool isChromeLine(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return true;
  // 実質的な文字（各言語のレターや数字）が少ない行は枠線・記号とみなす。
  if (_letterOrDigit.allMatches(t).length < 3) return true;
  const markers = [
    'esc to interrupt',
    'bypass permissions',
    'shift+tab',
    'for shortcuts',
    '? for',
    '/effort',
    'Auto-update',
    'context left',
    'Tip: Use /',
    'Try "',
    '/model',
  ];
  for (final m in markers) {
    if (t.contains(m)) return true;
  }
  return false;
}
