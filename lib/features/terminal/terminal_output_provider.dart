import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:xterm/xterm.dart';

class TerminalOutputService {
  TerminalOutputService({
    required this.terminal,
    required this.session,
  });

  final Terminal terminal;
  final SSHSession session;
  StreamSubscription? _subscription;

  void start() {
    _subscription = session.stdout.listen((data) {
      terminal.write(utf8.decode(data, allowMalformed: true));
    });
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
  }

  void dispose() {
    stop();
  }
}
