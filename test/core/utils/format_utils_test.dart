import 'package:flutter_test/flutter_test.dart';

import 'package:terminal_ssh_app/core/utils/format_utils.dart';

void main() {
  group('humanReadableSize()', () {
    // null
    test('returns empty string for null', () {
      expect(humanReadableSize(null), '');
    });

    // bytes range (< 1024)
    test('returns "0 B" for 0 bytes', () {
      expect(humanReadableSize(0), '0 B');
    });

    test('returns "1 B" for 1 byte', () {
      expect(humanReadableSize(1), '1 B');
    });

    test('returns "1023 B" for 1023 bytes (just below 1 KB)', () {
      expect(humanReadableSize(1023), '1023 B');
    });

    // kilobytes range (>= 1024, < 1024^2)
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

    // megabytes range (>= 1024^2, < 1024^3)
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

    // gigabytes range (>= 1024^3)
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

    // terabytes range (>= 1024^4)
    test('returns "1.0 TB" for exactly 1024^4 bytes', () {
      expect(humanReadableSize(1024 * 1024 * 1024 * 1024), '1.0 TB');
    });

    test('returns "1.5 TB" for 1.5 * 1024^4 bytes', () {
      expect(humanReadableSize((1.5 * 1024 * 1024 * 1024 * 1024).round()), '1.5 TB');
    });

    test('returns "4.0 TB" for 4 * 1024^4 bytes', () {
      expect(humanReadableSize(4 * 1024 * 1024 * 1024 * 1024), '4.0 TB');
    });

    // negative values
    test('returns "0 B" for -1 (negative treated as 0)', () {
      expect(humanReadableSize(-1), '0 B');
    });

    test('returns "0 B" for large negative value', () {
      expect(humanReadableSize(-1024 * 1024), '0 B');
    });
  });
}
