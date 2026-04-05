/// Human-readable file size (e.g. "1.2 MB").
/// Returns empty string for null. Negative values are treated as 0.
String humanReadableSize(int? bytes) {
  if (bytes == null) return '';
  final b = bytes < 0 ? 0 : bytes;
  const kb = 1024;
  const mb = 1024 * kb;
  const gb = 1024 * mb;
  const tb = 1024 * gb;
  if (b < kb) return '$b B';
  if (b < mb) return '${(b / kb).toStringAsFixed(1)} KB';
  if (b < gb) return '${(b / mb).toStringAsFixed(1)} MB';
  if (b < tb) return '${(b / gb).toStringAsFixed(1)} GB';
  return '${(b / tb).toStringAsFixed(1)} TB';
}
