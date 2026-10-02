import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_ssh_app/core/utils/natural_sort.dart';

List<String> _sorted(List<String> xs) => [...xs]..sort(compareNatural);

void main() {
  group('compareNatural', () {
    test('numeric suffixes are compared as numbers', () {
      expect(
        _sorted(['uninote-1', 'uninote-10', 'uninote-2', 'uninote-11', 'uninote-9']),
        ['uninote-1', 'uninote-2', 'uninote-9', 'uninote-10', 'uninote-11'],
      );
    });

    test('names without digits sort normally', () {
      expect(_sorted(['tennis', 'amore', 'work']), ['amore', 'tennis', 'work']);
    });

    test('mixed names', () {
      expect(
        _sorted(['work-1', 'amore-2', 'amore-10', 'tennis']),
        ['amore-2', 'amore-10', 'tennis', 'work-1'],
      );
    });

    test('leading zeros: a1 before a01, deterministic', () {
      expect(compareNatural('a1', 'a01'), lessThan(0));
      expect(compareNatural('a01', 'a1'), greaterThan(0));
      expect(compareNatural('a01', 'a2'), lessThan(0));
    });

    test('very long digit strings do not overflow', () {
      const a = '123456789012345678901234567890';
      const b = '123456789012345678901234567891';
      expect(compareNatural('x$a', 'x$b'), lessThan(0));
      expect(compareNatural('x$b', 'x$a'), greaterThan(0));
      expect(compareNatural('x${a}0', 'x$b'), greaterThan(0));
    });

    test('case differences are deterministic', () {
      final r1 = compareNatural('Abc', 'abc');
      final r2 = compareNatural('abc', 'Abc');
      expect(r1, isNot(0));
      expect(r1.sign, -r2.sign);
      expect(_sorted(['abc', 'Abc']), _sorted(['Abc', 'abc']));
    });

    test('case is ignored before tie-break', () {
      expect(compareNatural('a-2', 'B-1'), lessThan(0));
    });

    test('digits sort before non-digits; shorter first', () {
      expect(compareNatural('1a', 'aa'), lessThan(0));
      expect(compareNatural('a', 'a1'), lessThan(0));
    });

    test('identical strings return 0', () {
      expect(compareNatural('uninote-10', 'uninote-10'), 0);
      expect(compareNatural('', ''), 0);
    });

    test('antisymmetric', () {
      const xs = ['a1', 'a01', 'a2', 'A1', 'a', '1', '01', 'b-10', 'b-9', ''];
      for (final a in xs) {
        for (final b in xs) {
          expect(compareNatural(a, b).sign, -compareNatural(b, a).sign,
              reason: '$a vs $b');
        }
      }
    });
  });
}
