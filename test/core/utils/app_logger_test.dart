import 'package:flutter_test/flutter_test.dart';

import 'package:terminal_ssh_app/core/utils/app_logger.dart';

void main() {
  final logger = AppLogger.instance;

  setUp(() {
    logger.clear();
  });

  group('AppLogger.log()', () {
    test('adds a single entry', () {
      logger.log('hello');
      expect(logger.entries.length, 1);
      expect(logger.entries.first.message, 'hello');
    });

    test('appends entries in order', () {
      logger.log('first');
      logger.log('second');
      logger.log('third');
      final msgs = logger.entries.map((e) => e.message).toList();
      expect(msgs, ['first', 'second', 'third']);
    });

    test('records a timestamp close to now', () {
      final before = DateTime.now();
      logger.log('ts test');
      final after = DateTime.now();
      final ts = logger.entries.first.timestamp;
      expect(ts.isAfter(before) || ts.isAtSameMomentAs(before), isTrue);
      expect(ts.isBefore(after) || ts.isAtSameMomentAs(after), isTrue);
    });

    test('entries is unmodifiable', () {
      logger.log('x');
      expect(
        () => logger.entries.add(
          LogEntry(timestamp: DateTime.now(), message: 'y'),
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('AppLogger ring buffer (maxEntries = ${AppLogger.maxEntries})', () {
    test('does not exceed maxEntries', () {
      for (var i = 0; i < AppLogger.maxEntries + 10; i++) {
        logger.log('msg $i');
      }
      expect(logger.entries.length, AppLogger.maxEntries);
    });

    test('oldest entries are dropped first when over capacity', () {
      for (var i = 0; i < AppLogger.maxEntries + 3; i++) {
        logger.log('msg $i');
      }
      // First 3 are dropped; first surviving entry is 'msg 3'
      expect(logger.entries.first.message, 'msg 3');
      expect(logger.entries.last.message, 'msg ${AppLogger.maxEntries + 2}');
    });

    test('exactly maxEntries keeps all entries', () {
      for (var i = 0; i < AppLogger.maxEntries; i++) {
        logger.log('msg $i');
      }
      expect(logger.entries.length, AppLogger.maxEntries);
      expect(logger.entries.first.message, 'msg 0');
    });
  });

  group('AppLogger.toText()', () {
    test('returns empty string when no entries', () {
      expect(logger.toText(), '');
    });

    test('formats each entry as "ISO8601 message\\n"', () {
      logger.log('alpha');
      final text = logger.toText();
      final entry = logger.entries.first;
      expect(text, '${entry.timestamp.toIso8601String()} alpha\n');
    });

    test('includes all entries separated by newlines', () {
      logger.log('line1');
      logger.log('line2');
      final text = logger.toText();
      final lines = text.trimRight().split('\n');
      expect(lines.length, 2);
      expect(lines[0], endsWith(' line1'));
      expect(lines[1], endsWith(' line2'));
    });
  });

  group('AppLogger.clear()', () {
    test('removes all entries', () {
      logger.log('a');
      logger.log('b');
      logger.clear();
      expect(logger.entries, isEmpty);
    });

    test('allows logging again after clear', () {
      logger.log('before');
      logger.clear();
      logger.log('after');
      expect(logger.entries.length, 1);
      expect(logger.entries.first.message, 'after');
    });
  });
}
