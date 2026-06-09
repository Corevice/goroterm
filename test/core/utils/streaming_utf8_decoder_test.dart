import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_ssh_app/core/utils/streaming_utf8_decoder.dart';

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('StreamingUtf8Decoder', () {
    test('ASCII passes through unchanged', () {
      final decoder = StreamingUtf8Decoder();
      expect(decoder.decode(bytes('hello')), 'hello');
    });

    test('complete multibyte chunk decodes normally', () {
      final decoder = StreamingUtf8Decoder();
      expect(decoder.decode(bytes('こんにちは')), 'こんにちは');
    });

    // SSH のチャンク境界は文字境界と無関係。3 バイト文字の途中で
    // 分断されても U+FFFD にならず次チャンクと連結して復号される。
    test('3-byte char split across chunks is reassembled', () {
      final decoder = StreamingUtf8Decoder();
      final data = bytes('こんにちは'); // 15 bytes
      final out = StringBuffer();
      out.write(decoder.decode(Uint8List.sublistView(data, 0, 7)));
      out.write(decoder.decode(Uint8List.sublistView(data, 7)));
      expect(out.toString(), 'こんにちは');
      expect(out.toString().contains('�'), isFalse);
    });

    test('4-byte emoji split across chunks is reassembled', () {
      final decoder = StreamingUtf8Decoder();
      final data = bytes('🎉🚀😀'); // 12 bytes
      final out = StringBuffer();
      for (var i = 0; i < data.length; i += 3) {
        final end = (i + 3 < data.length) ? i + 3 : data.length;
        out.write(decoder.decode(Uint8List.sublistView(data, i, end)));
      }
      expect(out.toString(), '🎉🚀😀');
    });

    test('every possible split point of mixed text is lossless', () {
      const text = 'a─b日本語🎉x';
      final data = bytes(text);
      for (var split = 1; split < data.length; split++) {
        final decoder = StreamingUtf8Decoder();
        final out = StringBuffer();
        out.write(decoder.decode(Uint8List.sublistView(data, 0, split)));
        out.write(decoder.decode(Uint8List.sublistView(data, split)));
        expect(out.toString(), text, reason: 'split at byte $split');
      }
    });

    test('chunk that is only a partial char returns empty string', () {
      final decoder = StreamingUtf8Decoder();
      final data = bytes('日'); // 3 bytes
      expect(decoder.decode(Uint8List.sublistView(data, 0, 1)), '');
      expect(decoder.decode(Uint8List.sublistView(data, 1, 2)), '');
      expect(decoder.decode(Uint8List.sublistView(data, 2)), '日');
    });

    // 本物の不正バイト列は持ち越さずその場で U+FFFD に置換する
    test('genuinely malformed bytes are replaced, not carried forever', () {
      final decoder = StreamingUtf8Decoder();
      // 孤立した継続バイト
      expect(decoder.decode(Uint8List.fromList([0x80, 0x41])), '�A');
      // 期待長を超える継続バイト (2 バイトリードに継続 2 つ)
      final out = decoder.decode(Uint8List.fromList([0xC3, 0xA9, 0x80]));
      expect(out.startsWith('é'), isTrue);
      expect(out.contains('�'), isTrue);
    });

    test('lead byte with no continuation at end of stream is held back', () {
      final decoder = StreamingUtf8Decoder();
      expect(decoder.decode(Uint8List.fromList([0x41, 0xE3])), 'A');
      // reset() で持ち越しを破棄できる（再接続時）
      decoder.reset();
      expect(decoder.decode(bytes('B')), 'B');
    });

    test('empty input is a no-op', () {
      final decoder = StreamingUtf8Decoder();
      expect(decoder.decode(Uint8List(0)), '');
      expect(decoder.decode(bytes('x')), 'x');
    });
  });
}
