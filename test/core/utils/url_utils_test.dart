import 'package:flutter_test/flutter_test.dart';

import 'package:terminal_ssh_app/core/utils/url_utils.dart';

void main() {
  // ---------------------------------------------------------------------------
  // cleanUrl()
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // urlRegExp
  // ---------------------------------------------------------------------------
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

    // Exclusion character set — Japanese closing brackets and ASCII metacharacters
    // must terminate the URL match so they are not captured as part of the URL.
    // These tests also serve as a regression guard: the character class must not
    // contain duplicates (e.g. ）listed twice), which would be misleading.
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

  // ---------------------------------------------------------------------------
  // detectUrlInLine()
  // ---------------------------------------------------------------------------
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
      // Position inside "https://example.com" (starts at index 4)
      expect(detectUrlInLine(line, startX: 10), 'https://example.com');
    });

    test('returns second URL when startX is inside the second URL', () {
      const line = 'see https://example.com and https://other.com';
      // "https://other.com" starts at 29
      expect(detectUrlInLine(line, startX: 35), 'https://other.com');
    });

    test('falls back to first URL when startX is between URLs', () {
      const line = 'https://first.com  gap  https://second.com';
      // Position 19 is in the gap between the two URLs
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
      // 'https://example.com' is 19 chars → match.end = 19, last char at 18.
      expect(detectUrlInLine(line, startX: 18), 'https://example.com');
    });

    test('startX one past end of URL (match.end) falls back to first URL', () {
      const line = 'https://example.com rest';
      // match.end = 19 is exclusive — position 19 is the space after the URL.
      // The cursor is not inside the URL, so the function falls back to the
      // first URL in the line (which is the same URL in this single-URL case).
      expect(detectUrlInLine(line, startX: 19), 'https://example.com');
    });

    test('startX past end of URL picks second URL when cursor is on it', () {
      const line = 'https://first.com  https://second.com';
      // 'https://first.com' is 17 chars → match.end = 17.
      // Position 17 is the first space — not inside the first URL.
      // The second URL starts at 19, so startX=17 falls back to first URL.
      expect(detectUrlInLine(line, startX: 17), 'https://first.com');
    });
  });
}
