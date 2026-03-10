import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:terminal_ssh_app/features/terminal/terminal_input_provider.dart';

class MockSSHSession extends Mock implements SSHSession {}

void main() {
  late MockSSHSession mockSession;
  late TerminalInputService service;
  late List<Uint8List> written;

  setUpAll(() {
    registerFallbackValue(Uint8List(0));
  });

  setUp(() {
    mockSession = MockSSHSession();
    written = [];
    when(() => mockSession.write(any())).thenAnswer((invocation) {
      written.add(invocation.positionalArguments.first as Uint8List);
    });
    service = TerminalInputService(session: mockSession);
  });

  group('sendControlKey', () {
    test('Ctrl+A sends 0x01', () {
      service.sendControlKey('a');
      expect(written.single, Uint8List.fromList([1]));
    });

    test('Ctrl+C sends 0x03 (SIGINT)', () {
      service.sendControlKey('c');
      expect(written.single, Uint8List.fromList([3]));
    });

    test('Ctrl+D sends 0x04 (EOF)', () {
      service.sendControlKey('d');
      expect(written.single, Uint8List.fromList([4]));
    });

    test('Ctrl+Z sends 0x1A (SIGTSTP)', () {
      service.sendControlKey('z');
      expect(written.single, Uint8List.fromList([26]));
    });

    test('uppercase input works the same as lowercase', () {
      service.sendControlKey('C');
      expect(written.single, Uint8List.fromList([3]));
    });
  });

  group('sendEscape', () {
    test('sends 0x1B', () {
      service.sendEscape();
      expect(written.single, Uint8List.fromList([0x1B]));
    });
  });

  group('sendTab', () {
    test('sends 0x09', () {
      service.sendTab();
      expect(written.single, Uint8List.fromList([0x09]));
    });
  });

  group('sendEnter', () {
    test('sends carriage return', () {
      service.sendEnter();
      expect(written.single, Uint8List.fromList([0x0D])); // '\r'
    });
  });

  group('sendArrow keys', () {
    test('sendArrowUp sends ESC[A', () {
      service.sendArrowUp();
      expect(String.fromCharCodes(written.single), '\x1B[A');
    });

    test('sendArrowDown sends ESC[B', () {
      service.sendArrowDown();
      expect(String.fromCharCodes(written.single), '\x1B[B');
    });

    test('sendArrowRight sends ESC[C', () {
      service.sendArrowRight();
      expect(String.fromCharCodes(written.single), '\x1B[C');
    });

    test('sendArrowLeft sends ESC[D', () {
      service.sendArrowLeft();
      expect(String.fromCharCodes(written.single), '\x1B[D');
    });
  });

  group('sanitizeForTerminal', () {
    test('replaces CRLF with CR', () {
      expect(service.sanitizeForTerminal('hello\r\nworld'), 'hello\rworld');
    });

    test('replaces LF with CR', () {
      expect(service.sanitizeForTerminal('hello\nworld'), 'hello\rworld');
    });

    test('replaces multiple line endings', () {
      expect(
        service.sanitizeForTerminal('a\r\nb\nc\r\nd'),
        'a\rb\rc\rd',
      );
    });

    test('leaves text without line endings unchanged', () {
      expect(service.sanitizeForTerminal('hello world'), 'hello world');
    });

    test('handles empty string', () {
      expect(service.sanitizeForTerminal(''), '');
    });
  });

  group('paste', () {
    test('sanitizes and sends text', () {
      service.paste('line1\r\nline2\nline3');
      expect(written.length, 1);
      expect(String.fromCharCodes(written.single), 'line1\rline2\rline3');
    });
  });
}
