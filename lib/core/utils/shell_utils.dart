/// Wraps [value] in single quotes and escapes any embedded single quotes.
/// Safe against all shell metacharacters (spaces, $, ;, |, backticks, etc.).
///
/// This is the canonical implementation used by both the file browser and
/// tmux features. Do not duplicate this logic — import from here instead.
String shellQuote(String value) {
  final escaped = value.replaceAll("'", r"'\''");
  return "'$escaped'";
}

/// Normalizes line endings in [text] for terminal/SSH input.
/// Converts CRLF (\r\n) and bare LF (\n) to CR (\r), which is the
/// canonical line-feed character for PTY-based terminal sessions.
///
/// This is the canonical implementation shared by [TerminalInputService] and
/// [ImeInputHandler]. Do not duplicate this logic — import from here instead.
String sanitizeForTerminal(String text) {
  return text.replaceAll('\r\n', '\r').replaceAll('\n', '\r');
}
