import 'package:flutter_test/flutter_test.dart';

import 'package:terminal_ssh_app/core/utils/shell_utils.dart';

void main() {
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
      // it's  →  'it'\''s'
      expect(shellQuote("it's"), r"'it'\''s'");
    });

    test('escapes multiple embedded single quotes', () {
      // a'b'c  →  'a'\''b'\''c'
      expect(shellQuote("a'b'c"), r"'a'\''b'\''c'");
    });

    test('escapes a leading single quote', () {
      // 'hello  →  ''\''hello'
      expect(shellQuote("'hello"), r"''\''hello'");
    });

    test('escapes a trailing single quote', () {
      // hello'  →  'hello'\'''
      expect(shellQuote("hello'"), r"'hello'\'''");
    });

    test('string consisting only of single quotes', () {
      // '''  →  ''\'''\'''\'''
      expect(shellQuote("'''"), r"''\'''\'''\'''");
    });

    // Shell metacharacter safety
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
      // /user's docs/file  →  '/user'\''s docs/file'
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
}
