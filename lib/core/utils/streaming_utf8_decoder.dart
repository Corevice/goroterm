import 'dart:convert';
import 'dart:typed_data';

/// チャンク境界を跨ぐ UTF-8 シーケンスを正しく復号するストリーミングデコーダ。
///
/// SSH の stdout はパケット境界が文字境界と無関係なため、チャンクごとに
/// `utf8.decode()` すると多バイト文字（罫線・日本語等）が分断されて
/// U+FFFD に化ける。本クラスは末尾の不完全なシーケンス（最大 3 バイト）を
/// 次のチャンクへ持ち越すことでこれを防ぐ。
///
/// 不正なバイト列（本物の文字化け）は持ち越さず、その場で
/// `allowMalformed: true` の挙動（U+FFFD 置換）に委ねる。
class StreamingUtf8Decoder {
  Uint8List _carry = Uint8List(0);

  /// [data] を復号して返す。末尾が多バイト文字の途中であれば、その分は
  /// 内部に保持し次回の [decode] 呼び出しで先頭に連結される。
  String decode(Uint8List data) {
    Uint8List bytes;
    if (_carry.isEmpty) {
      bytes = data;
    } else {
      bytes = Uint8List(_carry.length + data.length)
        ..setAll(0, _carry)
        ..setAll(_carry.length, data);
      _carry = Uint8List(0);
    }

    final cut = _completePrefixLength(bytes);
    if (cut == bytes.length) {
      return utf8.decode(bytes, allowMalformed: true);
    }
    _carry = bytes.sublist(cut);
    return utf8.decode(bytes.sublist(0, cut), allowMalformed: true);
  }

  /// 持ち越し中のバイトを破棄して初期状態に戻す（再接続時用）。
  void reset() {
    _carry = Uint8List(0);
  }

  /// 末尾の不完全な UTF-8 シーケンスを除いた長さを返す。
  /// 不完全なシーケンスが無ければ [bytes] の全長を返す。
  static int _completePrefixLength(Uint8List bytes) {
    final n = bytes.length;
    if (n == 0) return 0;

    // 末尾から継続バイト (10xxxxxx) を最大 3 つ遡ってリード文字を探す
    var i = n - 1;
    var back = 0;
    while (i >= 0 && back < 3 && (bytes[i] & 0xC0) == 0x80) {
      i--;
      back++;
    }
    if (i < 0) return n;

    final lead = bytes[i];
    final int expected;
    if (lead >= 0xF0) {
      expected = 4;
    } else if (lead >= 0xE0) {
      expected = 3;
    } else if (lead >= 0xC0) {
      expected = 2;
    } else {
      // ASCII または迷子の継続バイト: 不完全ではない（不正なら FFFD でよい）
      return n;
    }

    final have = n - i;
    // 期待長に満たない場合のみ持ち越す。期待長を超える継続バイトが
    // 続いている場合は不正な列なのでそのまま復号させる。
    return have < expected ? i : n;
  }
}
