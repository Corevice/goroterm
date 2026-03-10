/// Wraps [value] in single quotes and escapes any embedded single quotes.
/// Safe against all shell metacharacters (spaces, $, ;, |, backticks, etc.).
///
/// This is the canonical implementation used by both the file browser and
/// tmux features. Do not duplicate this logic — import from here instead.
String shellQuote(String value) {
  final escaped = value.replaceAll("'", r"'\''");
  return "'$escaped'";
}
