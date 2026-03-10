import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

class TerminalInputService {
  TerminalInputService({required this.session});

  final SSHSession session;

  void writeToSsh(String text) {
    session.write(utf8.encoder.convert(text));
  }

  void writeBytes(Uint8List bytes) {
    session.write(bytes);
  }

  void sendControlKey(String char) {
    // Ctrl+key: send the control character (char code - 64)
    final code = char.toUpperCase().codeUnitAt(0) - 64;
    writeBytes(Uint8List.fromList([code]));
  }

  void sendEscape() {
    writeBytes(Uint8List.fromList([0x1B]));
  }

  void sendTab() {
    writeBytes(Uint8List.fromList([0x09]));
  }

  void sendEnter() {
    writeToSsh('\r');
  }

  void sendArrowUp() {
    writeToSsh('\x1B[A');
  }

  void sendArrowDown() {
    writeToSsh('\x1B[B');
  }

  void sendArrowRight() {
    writeToSsh('\x1B[C');
  }

  void sendArrowLeft() {
    writeToSsh('\x1B[D');
  }

  String sanitizeForTerminal(String text) {
    // Replace Windows-style line endings with Unix-style
    return text.replaceAll('\r\n', '\r').replaceAll('\n', '\r');
  }

  void paste(String text) {
    writeToSsh(sanitizeForTerminal(text));
  }
}
