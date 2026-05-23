import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/paragraph_cache.dart';

const _style = TextStyle(fontSize: 14, fontFamily: 'monospace');
const _scaler = TextScaler.noScaling;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ParagraphCache', () {
    test('returns null for an unknown key', () {
      final cache = ParagraphCache(8);
      expect(cache.getLayoutFromCache(42), isNull);
      expect(cache.length, 0);
    });

    test('performAndCacheLayout stores and returns the same Paragraph', () {
      final cache = ParagraphCache(8);
      final p = cache.performAndCacheLayout('a', _style, _scaler, 1);
      expect(cache.getLayoutFromCache(1), same(p));
      expect(cache.length, 1);
    });

    test('different keys produce independent entries', () {
      final cache = ParagraphCache(8);
      final a = cache.performAndCacheLayout('a', _style, _scaler, 1);
      final b = cache.performAndCacheLayout('b', _style, _scaler, 2);
      expect(a, isNot(same(b)));
      expect(cache.length, 2);
    });

    test('LRU evicts the oldest entry when capacity is exceeded', () {
      final cache = ParagraphCache(2);
      cache.performAndCacheLayout('a', _style, _scaler, 1);
      cache.performAndCacheLayout('b', _style, _scaler, 2);
      // Touch key 1 so key 2 becomes the least-recently used.
      cache.getLayoutFromCache(1);
      cache.performAndCacheLayout('c', _style, _scaler, 3);

      expect(cache.length, 2);
      expect(cache.getLayoutFromCache(1), isNotNull,
          reason: 'recently touched entry must survive eviction');
      expect(cache.getLayoutFromCache(2), isNull,
          reason: 'least-recently-used entry must be evicted');
      expect(cache.getLayoutFromCache(3), isNotNull);
    });

    test('clear empties the cache', () {
      final cache = ParagraphCache(8);
      cache.performAndCacheLayout('a', _style, _scaler, 1);
      cache.performAndCacheLayout('b', _style, _scaler, 2);
      expect(cache.length, 2);

      cache.clear();
      expect(cache.length, 0);
      expect(cache.getLayoutFromCache(1), isNull);
      expect(cache.getLayoutFromCache(2), isNull);
    });

    test('performAndCacheLayout on an existing key overwrites the entry', () {
      final cache = ParagraphCache(8);
      final first = cache.performAndCacheLayout('a', _style, _scaler, 1);
      final second = cache.performAndCacheLayout('b', _style, _scaler, 1);
      expect(first, isNot(same(second)));
      expect(cache.getLayoutFromCache(1), same(second));
      expect(cache.length, 1);
    });

    test('returned Paragraph reports a positive intrinsic width', () {
      final cache = ParagraphCache(8);
      final p = cache.performAndCacheLayout('m', _style, _scaler, 1);
      expect(p.maxIntrinsicWidth, greaterThan(0));
      expect(p.height, greaterThan(0));
    });

    test('getLayoutFromCache promotes the entry to most-recently used', () {
      // capacity 2 で a, b を入れ、a を touch → c を入れたら b が evict される。
      // touch を get で行う点が performAndCacheLayout 経由の LRU テストと違う。
      final cache = ParagraphCache(2);
      cache.performAndCacheLayout('a', _style, _scaler, 1);
      cache.performAndCacheLayout('b', _style, _scaler, 2);
      cache.getLayoutFromCache(1); // a を MRU に
      cache.performAndCacheLayout('c', _style, _scaler, 3);

      expect(cache.getLayoutFromCache(1), isNotNull);
      expect(cache.getLayoutFromCache(2), isNull);
      expect(cache.getLayoutFromCache(3), isNotNull);
    });

    test('evicted Paragraphs are disposed', () {
      final cache = ParagraphCache(1);
      final first = cache.performAndCacheLayout('a', _style, _scaler, 1);
      expect(first.debugDisposed, isFalse);

      // Insert a second entry: first should be evicted and disposed.
      cache.performAndCacheLayout('b', _style, _scaler, 2);
      expect(first.debugDisposed, isTrue,
          reason: 'LRU evict must release the Paragraph native handle');
    });

    test('clear disposes all cached Paragraphs', () {
      final cache = ParagraphCache(4);
      final a = cache.performAndCacheLayout('a', _style, _scaler, 1);
      final b = cache.performAndCacheLayout('b', _style, _scaler, 2);

      cache.clear();
      expect(cache.length, 0);
      expect(a.debugDisposed, isTrue);
      expect(b.debugDisposed, isTrue);
    });

    test('overwriting a key disposes the previous Paragraph', () {
      final cache = ParagraphCache(4);
      final first = cache.performAndCacheLayout('a', _style, _scaler, 1);
      final second = cache.performAndCacheLayout('b', _style, _scaler, 1);

      expect(first.debugDisposed, isTrue,
          reason: 'same key replacement must dispose the old Paragraph');
      expect(second.debugDisposed, isFalse);
      expect(cache.getLayoutFromCache(1), same(second));
    });
  });
}
