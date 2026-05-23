import 'dart:ui';

import 'package:flutter/widgets.dart';

/// A cache of laid out [Paragraph]s. This is used to avoid laying out the same
/// text multiple times, which is expensive.
///
/// Evicted [Paragraph] handles are disposed so that the underlying Skia
/// resources can be released; otherwise they would only be reclaimed by GC,
/// which is best-effort and slow under sustained terminal output.
class ParagraphCache {
  ParagraphCache(this.maximumSize);

  /// Maximum number of [Paragraph] entries to keep.
  final int maximumSize;

  /// Insertion-ordered (LinkedHashMap) map. The first entry is the LRU.
  final _cache = <int, Paragraph>{};

  /// Returns a [Paragraph] for the given [key]. Marks the entry as
  /// most-recently used.
  Paragraph? getLayoutFromCache(int key) {
    final paragraph = _cache.remove(key);
    if (paragraph == null) return null;
    _cache[key] = paragraph;
    return paragraph;
  }

  /// Applies [style] and [textScaler] to [text] and lays it out to create
  /// a [Paragraph]. The [Paragraph] is cached and can be retrieved with the
  /// same [key] by calling [getLayoutFromCache].
  Paragraph performAndCacheLayout(
    String text,
    TextStyle style,
    TextScaler textScaler,
    int key,
  ) {
    final builder = ParagraphBuilder(style.getParagraphStyle());
    builder.pushStyle(style.getTextStyle(textScaler: textScaler));
    builder.addText(text);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: double.infinity));

    // Replace an existing entry under the same key (e.g. hash collision):
    // release the old Paragraph before overwriting.
    _cache.remove(key)?.dispose();
    _cache[key] = paragraph;

    // Evict least-recently used entries until under capacity. The Dart Map
    // literal preserves insertion order, so `keys.first` is the oldest.
    while (_cache.length > maximumSize) {
      final oldestKey = _cache.keys.first;
      _cache.remove(oldestKey)?.dispose();
    }

    return paragraph;
  }

  /// Clears the cache. This should be called when the same text and style
  /// pair no longer produces the same layout. For example, when a font is
  /// loaded.
  void clear() {
    for (final paragraph in _cache.values) {
      paragraph.dispose();
    }
    _cache.clear();
  }

  /// Returns the number of [Paragraph]s in the cache.
  int get length {
    return _cache.length;
  }
}
