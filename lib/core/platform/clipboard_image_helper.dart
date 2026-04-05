import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class ClipboardImageHelper {
  static const _channel =
      MethodChannel('com.example.terminalSshApp/clipboard_image');

  /// クリップボードに画像があれば一時ファイルとして保存しパスを返す。
  /// 画像がなければ null。macOS / Android 対応。
  static Future<String?> getClipboardImageFile() async {
    if (!Platform.isMacOS && !Platform.isAndroid) return null;

    final Uint8List? bytes;
    try {
      bytes = await _channel.invokeMethod<Uint8List>('getClipboardImage');
    } on MissingPluginException {
      return null;
    }
    if (bytes == null || bytes.isEmpty) return null;

    final dir = await getTemporaryDirectory();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final file = File(p.join(dir.path, 'clipboard_$ts.png'));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}
