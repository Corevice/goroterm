// Merged from: format_utils_test.dart, app_logger_test.dart, shell_utils_test.dart

// Merged from: format_utils_test.dart, app_logger_test.dart, shell_utils_test.dart,
// url_utils_test.dart, widget_test.dart

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:terminal_ssh_app/core/utils/app_logger.dart';
import 'package:terminal_ssh_app/core/utils/format_utils.dart';
import 'package:terminal_ssh_app/core/utils/shell_utils.dart';
import 'package:terminal_ssh_app/core/utils/url_utils.dart';

void main() {
  // =====================================================================
  // format_utils.dart
  // =====================================================================
  group('humanReadableSize()', () {
    test('returns empty string for null', () {
      expect(humanReadableSize(null), '');
    });

    test('returns "0 B" for 0 bytes', () {
      expect(humanReadableSize(0), '0 B');
    });

    test('returns "1 B" for 1 byte', () {
      expect(humanReadableSize(1), '1 B');
    });

    test('returns "1023 B" for 1023 bytes (just below 1 KB)', () {
      expect(humanReadableSize(1023), '1023 B');
    });

    test('returns "1.0 KB" for exactly 1024 bytes', () {
      expect(humanReadableSize(1024), '1.0 KB');
    });

    test('returns "1.5 KB" for 1536 bytes', () {
      expect(humanReadableSize(1536), '1.5 KB');
    });

    test('returns "10.0 KB" for 10 * 1024 bytes', () {
      expect(humanReadableSize(10 * 1024), '10.0 KB');
    });

    test('returns "1023.0 KB" for 1023 * 1024 bytes (just below 1 MB)', () {
      expect(humanReadableSize(1023 * 1024), '1023.0 KB');
    });

    test('returns "1.0 MB" for exactly 1024^2 bytes', () {
      expect(humanReadableSize(1024 * 1024), '1.0 MB');
    });

    test('returns "1.5 MB" for 1.5 * 1024^2 bytes', () {
      expect(humanReadableSize((1.5 * 1024 * 1024).round()), '1.5 MB');
    });

    test('returns "100.0 MB" for 100 * 1024^2 bytes', () {
      expect(humanReadableSize(100 * 1024 * 1024), '100.0 MB');
    });

    test('returns "1023.0 MB" for 1023 * 1024^2 bytes (just below 1 GB)', () {
      expect(humanReadableSize(1023 * 1024 * 1024), '1023.0 MB');
    });

    test('returns "1.0 GB" for exactly 1024^3 bytes', () {
      expect(humanReadableSize(1024 * 1024 * 1024), '1.0 GB');
    });

    test('returns "1.5 GB" for 1.5 * 1024^3 bytes', () {
      expect(humanReadableSize((1.5 * 1024 * 1024 * 1024).round()), '1.5 GB');
    });

    test('returns "2.0 GB" for 2 * 1024^3 bytes', () {
      expect(humanReadableSize(2 * 1024 * 1024 * 1024), '2.0 GB');
    });

    test('returns "1023.0 GB" for 1023 * 1024^3 bytes (just below 1 TB)', () {
      expect(humanReadableSize(1023 * 1024 * 1024 * 1024), '1023.0 GB');
    });

    test('returns "1.0 TB" for exactly 1024^4 bytes', () {
      expect(humanReadableSize(1024 * 1024 * 1024 * 1024), '1.0 TB');
    });

    test('returns "1.5 TB" for 1.5 * 1024^4 bytes', () {
      expect(humanReadableSize((1.5 * 1024 * 1024 * 1024 * 1024).round()), '1.5 TB');
    });

    test('returns "4.0 TB" for 4 * 1024^4 bytes', () {
      expect(humanReadableSize(4 * 1024 * 1024 * 1024 * 1024), '4.0 TB');
    });

    test('returns "0 B" for -1 (negative treated as 0)', () {
      expect(humanReadableSize(-1), '0 B');
    });

    test('returns "0 B" for large negative value', () {
      expect(humanReadableSize(-1024 * 1024), '0 B');
    });
  });

  // =====================================================================
  // app_logger.dart
  // =====================================================================
  group('AppLogger', () {
    final logger = AppLogger.instance;

    setUp(() {
      logger.clear();
    });

    group('log()', () {
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

    group('ring buffer (maxEntries = ${AppLogger.maxEntries})', () {
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

    group('toText()', () {
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

    group('clear()', () {
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
  });

  // =====================================================================
  // shell_utils.dart
  // =====================================================================
  group('shellQuote()', () {
    test('wraps a plain string in single quotes', () {
      expect(shellQuote('hello'), "'hello'");
    });

    test('wraps empty string in single quotes', () {
      expect(shellQuote(''), "''");
    });

    test('wraps string with spaces', () {
      expect(shellQuote('hello world'), "'hello world'");
    });

    test('escapes an embedded single quote', () {
      expect(shellQuote("it's"), r"'it'\''s'");
    });

    test('escapes multiple embedded single quotes', () {
      expect(shellQuote("a'b'c"), r"'a'\''b'\''c'");
    });

    test('escapes a leading single quote', () {
      expect(shellQuote("'hello"), r"''\''hello'");
    });

    test('escapes a trailing single quote', () {
      expect(shellQuote("hello'"), r"'hello'\'''");
    });

    test('string consisting only of single quotes', () {
      expect(shellQuote("'''"), r"''\'''\'''\'''");
    });

    test('does not escape dollar sign (safe inside single quotes)', () {
      expect(shellQuote(r'$HOME'), r"'$HOME'");
    });

    test('does not escape backtick (safe inside single quotes)', () {
      expect(shellQuote('`whoami`'), "'`whoami`'");
    });

    test('does not escape semicolon (safe inside single quotes)', () {
      expect(shellQuote('a;b'), "'a;b'");
    });

    test('does not escape pipe (safe inside single quotes)', () {
      expect(shellQuote('a|b'), "'a|b'");
    });

    test('does not escape backslash (safe inside single quotes)', () {
      expect(shellQuote(r'a\b'), r"'a\b'");
    });

    test('handles path with spaces and special chars', () {
      expect(shellQuote('/my docs/file name.txt'), "'/my docs/file name.txt'");
    });

    test('handles path containing single quote in directory name', () {
      expect(shellQuote("/user's docs/file"), r"'/user'\''s docs/file'");
    });
  });

  group('sanitizeForTerminal()', () {
    test('converts CRLF to CR', () {
      expect(sanitizeForTerminal('hello\r\nworld'), 'hello\rworld');
    });

    test('converts bare LF to CR', () {
      expect(sanitizeForTerminal('hello\nworld'), 'hello\rworld');
    });

    test('converts mixed CRLF and LF', () {
      expect(sanitizeForTerminal('a\r\nb\nc'), 'a\rb\rc');
    });

    test('leaves plain text unchanged', () {
      expect(sanitizeForTerminal('hello world'), 'hello world');
    });

    test('returns empty string unchanged', () {
      expect(sanitizeForTerminal(''), '');
    });

    test('leaves lone CR unchanged', () {
      expect(sanitizeForTerminal('hello\rworld'), 'hello\rworld');
    });

    test('handles multiple consecutive CRLFs', () {
      expect(sanitizeForTerminal('a\r\n\r\nb'), 'a\r\rb');
    });
  });

  // =====================================================================
  // url_utils.dart
  // =====================================================================
  group('cleanUrl()', () {
    test('returns url unchanged when no trailing punctuation', () {
      expect(cleanUrl('https://example.com'), 'https://example.com');
    });

    test('removes trailing period', () {
      expect(cleanUrl('https://example.com.'), 'https://example.com');
    });

    test('removes trailing comma', () {
      expect(cleanUrl('https://example.com,'), 'https://example.com');
    });

    test('removes trailing colon', () {
      expect(cleanUrl('https://example.com:'), 'https://example.com');
    });

    test('removes trailing semicolon', () {
      expect(cleanUrl('https://example.com;'), 'https://example.com');
    });

    test('removes trailing exclamation mark', () {
      expect(cleanUrl('https://example.com!'), 'https://example.com');
    });

    test('removes trailing question mark', () {
      expect(cleanUrl('https://example.com?'), 'https://example.com');
    });

    test('removes trailing closing parenthesis', () {
      expect(cleanUrl('https://example.com)'), 'https://example.com');
    });

    test('removes trailing greater-than sign', () {
      expect(cleanUrl('https://example.com>'), 'https://example.com');
    });

    test('removes trailing Japanese closing bracket 」', () {
      expect(cleanUrl('https://example.com」'), 'https://example.com');
    });

    test('removes trailing Japanese closing bracket 』', () {
      expect(cleanUrl('https://example.com』'), 'https://example.com');
    });

    test('removes trailing Japanese closing bracket ）', () {
      expect(cleanUrl('https://example.com）'), 'https://example.com');
    });

    test('removes trailing Japanese closing bracket 】', () {
      expect(cleanUrl('https://example.com】'), 'https://example.com');
    });

    test('removes multiple trailing punctuation characters', () {
      expect(cleanUrl('https://example.com).'), 'https://example.com');
    });

    test('preserves query string (no trailing punctuation)', () {
      const url = 'https://example.com/path?q=1&foo=bar';
      expect(cleanUrl(url), url);
    });

    test('preserves fragment', () {
      const url = 'https://example.com/page#section';
      expect(cleanUrl(url), url);
    });

    test('preserves port in URL', () {
      const url = 'https://example.com:8080/path';
      expect(cleanUrl(url), url);
    });

    test('returns empty string unchanged', () {
      expect(cleanUrl(''), '');
    });

    test('single punctuation character is stripped entirely', () {
      expect(cleanUrl('.'), '');
    });
  });

  group('urlRegExp', () {
    test('matches simple https URL', () {
      expect(urlRegExp.hasMatch('https://example.com'), isTrue);
    });

    test('matches simple http URL', () {
      expect(urlRegExp.hasMatch('http://example.com'), isTrue);
    });

    test('matches URL with path', () {
      expect(urlRegExp.hasMatch('https://example.com/path/to/page'), isTrue);
    });

    test('matches URL with query string', () {
      expect(urlRegExp.hasMatch('https://example.com?q=hello'), isTrue);
    });

    test('does not match ftp URL', () {
      expect(urlRegExp.hasMatch('ftp://example.com'), isFalse);
    });

    test('does not match bare hostname without scheme', () {
      expect(urlRegExp.hasMatch('example.com'), isFalse);
    });

    test('URL match stops at fullwidth right parenthesis ）', () {
      expect(
        urlRegExp.firstMatch('https://example.com）rest')?.group(0),
        'https://example.com',
      );
    });

    test('URL match stops at right black lenticular bracket 】', () {
      expect(
        urlRegExp.firstMatch('https://example.com】rest')?.group(0),
        'https://example.com',
      );
    });

    test('URL match stops at right corner bracket 」', () {
      expect(
        urlRegExp.firstMatch('https://example.com」rest')?.group(0),
        'https://example.com',
      );
    });

    test('URL match stops at right white corner bracket 』', () {
      expect(
        urlRegExp.firstMatch('https://example.com』rest')?.group(0),
        'https://example.com',
      );
    });

    test('URL match stops at space', () {
      expect(
        urlRegExp.firstMatch('https://example.com rest')?.group(0),
        'https://example.com',
      );
    });

    test('URL match stops at double-quote', () {
      expect(
        urlRegExp.firstMatch('https://example.com"rest')?.group(0),
        'https://example.com',
      );
    });
  });

  group('detectUrlInLine()', () {
    test('returns null for empty string', () {
      expect(detectUrlInLine(''), isNull);
    });

    test('returns null when line has no URL', () {
      expect(detectUrlInLine('hello world'), isNull);
    });

    test('returns URL when line contains a plain URL', () {
      expect(
        detectUrlInLine('visit https://example.com for info'),
        'https://example.com',
      );
    });

    test('returns URL at cursor position when startX is inside URL', () {
      const line = 'see https://example.com and https://other.com';
      expect(detectUrlInLine(line, startX: 10), 'https://example.com');
    });

    test('returns second URL when startX is inside the second URL', () {
      const line = 'see https://example.com and https://other.com';
      expect(detectUrlInLine(line, startX: 35), 'https://other.com');
    });

    test('falls back to first URL when startX is between URLs', () {
      const line = 'https://first.com  gap  https://second.com';
      expect(detectUrlInLine(line, startX: 19), 'https://first.com');
    });

    test('returns URL when startX is null (first URL in line)', () {
      const line = 'go to https://example.com now';
      expect(detectUrlInLine(line), 'https://example.com');
    });

    test('strips trailing period from detected URL', () {
      expect(
        detectUrlInLine('see https://example.com.'),
        'https://example.com',
      );
    });

    test('strips trailing parenthesis from detected URL', () {
      expect(
        detectUrlInLine('(see https://example.com)'),
        'https://example.com',
      );
    });

    test('handles URL with path and query', () {
      const url = 'https://example.com/search?q=hello+world';
      expect(detectUrlInLine('result: $url'), url);
    });

    test('startX at exact start of URL returns that URL', () {
      const line = 'https://example.com rest';
      expect(detectUrlInLine(line, startX: 0), 'https://example.com');
    });

    test('startX at last character of URL (match.end - 1) returns that URL', () {
      const line = 'https://example.com rest';
      expect(detectUrlInLine(line, startX: 18), 'https://example.com');
    });

    test('startX one past end of URL (match.end) falls back to first URL', () {
      const line = 'https://example.com rest';
      expect(detectUrlInLine(line, startX: 19), 'https://example.com');
    });

    test('startX past end of URL picks second URL when cursor is on it', () {
      const line = 'https://first.com  https://second.com';
      expect(detectUrlInLine(line, startX: 17), 'https://first.com');
    });
  });
}
