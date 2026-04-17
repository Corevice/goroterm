// URL detection utilities for terminal output.

/// Matches http/https URLs, excluding whitespace, ASCII shell metacharacters,
/// and Japanese closing brackets that are unlikely to be part of a URL.
final urlRegExp = RegExp(
  r'https?://[^\s\x00-\x1F\x7F<>"{}|\\^`\[\]）】」』]+',
);

/// Pre-compiled pattern for trailing punctuation unlikely to be part of a URL.
final _trailingPunct = RegExp(r'[.,:;!?)>」』）】]+$');

/// Removes trailing punctuation that is unlikely to be part of a URL.
/// Examples: trailing `.`, `,`, `)`, `>`, Japanese closing brackets.
String cleanUrl(String url) => url.replaceFirst(_trailingPunct, '');

/// Finds a URL in [lineText] near column [startX].
///
/// If [startX] is provided, returns the URL whose match range contains that
/// column (i.e. the URL the cursor is on).  Falls back to the first URL in
/// the line when no match contains [startX].  Returns `null` when the line
/// contains no URL.
String? detectUrlInLine(String lineText, {int? startX}) {
  if (startX == null) {
    final first = urlRegExp.firstMatch(lineText);
    return first != null ? cleanUrl(first.group(0)!) : null;
  }

  // Walk matches once: track the first match for fallback while checking
  // whether the cursor falls inside any match.
  RegExpMatch? firstMatch;
  for (final match in urlRegExp.allMatches(lineText)) {
    firstMatch ??= match;
    if (startX >= match.start && startX < match.end) {
      return cleanUrl(match.group(0)!);
    }
  }

  // Fallback: cursor is not on any URL — return the first URL in the line.
  return firstMatch != null ? cleanUrl(firstMatch.group(0)!) : null;
}
