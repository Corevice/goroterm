import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_ssh_app/core/ssh/keepalive_ssh_socket.dart';

// ---------------------------------------------------------------------------
// KeepaliveSSHSocket — unit tests for applyKeepaliveOptions
//
// Socket.connect() requires a live network; that path cannot be exercised
// here. What we CAN test is the option-application logic via a fake Socket
// that records every setRawOption() call.
// ---------------------------------------------------------------------------

/// Records all [setRawOption] calls without touching the OS.
/// Any unimplemented method throws [UnimplementedError] if accidentally called.
class _FakeSocket extends Fake implements Socket {
  final List<RawSocketOption> rawOptions = [];

  @override
  bool setRawOption(RawSocketOption option) {
    rawOptions.add(option);
    return true;
  }

  // setOption is called by the TCP_NODELAY path in connect(), not in
  // applyKeepaliveOptions. Provide a no-op so tests that call the method
  // directly never hit UnimplementedError for this method.
  @override
  bool setOption(SocketOption option, bool enabled) => true;
}

/// A [_FakeSocket] whose [setRawOption] always throws — used to verify that
/// errors are swallowed and do not propagate to the caller.
class _ThrowingSocket extends Fake implements Socket {
  @override
  bool setRawOption(RawSocketOption option) =>
      throw const SocketException('simulated failure');
}

void main() {
  group('KeepaliveSSHSocket.applyKeepaliveOptions', () {
    late _FakeSocket socket;

    setUp(() {
      socket = _FakeSocket();
    });

    test('sets exactly 4 options: 1 SO_KEEPALIVE + 3 TCP tuning', () {
      KeepaliveSSHSocket.applyKeepaliveOptions(socket);
      // SO_KEEPALIVE (levelSocket) + TCP_KEEPIDLE/INTVL/CNT (levelTcp)
      expect(socket.rawOptions.length, 4);
    });

    test('first option is at SOL_SOCKET level', () {
      KeepaliveSSHSocket.applyKeepaliveOptions(socket);
      expect(socket.rawOptions.first.level, RawSocketOption.levelSocket);
    });

    test('remaining 3 options are at IPPROTO_TCP level', () {
      KeepaliveSSHSocket.applyKeepaliveOptions(socket);
      final tcpOptions = socket.rawOptions.skip(1).toList();
      for (final opt in tcpOptions) {
        expect(opt.level, RawSocketOption.levelTcp);
      }
    });

    test('SO_KEEPALIVE value is 1 (enabled)', () {
      KeepaliveSSHSocket.applyKeepaliveOptions(socket);
      // fromBool(..., true) encodes as a 4-byte int with native endian value 1.
      final soOpt = socket.rawOptions.first;
      expect(soOpt.value.length, 4);
      final view = ByteData.sublistView(soOpt.value);
      expect(view.getInt32(0, Endian.host), 1);
    });

    test('TCP idle option value is 15 seconds', () {
      KeepaliveSSHSocket.applyKeepaliveOptions(socket);
      // The idle-time option is the second option (index 1).
      final idleOpt = socket.rawOptions[1];
      final view = ByteData.sublistView(idleOpt.value);
      expect(view.getInt32(0, Endian.host), 15);
    });

    test('does not throw even when socket setRawOption throws', () {
      expect(
        () => KeepaliveSSHSocket.applyKeepaliveOptions(_ThrowingSocket()),
        returnsNormally,
      );
    });

    test('applies options idempotently on repeated calls', () {
      KeepaliveSSHSocket.applyKeepaliveOptions(socket);
      KeepaliveSSHSocket.applyKeepaliveOptions(socket);
      // Each call adds 4 options; 2 calls → 8.
      expect(socket.rawOptions.length, 8);
    });
  });
}
