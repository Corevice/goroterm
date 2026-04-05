import 'dart:io';

import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

/// プラットフォーム固有のファイル保存ヘルパー。
/// Android: MediaStore API で Downloads フォルダに保存（ユーザー操作不要）。
/// iOS/その他: share_plus でシェアシートを表示。
class DownloadHelper {
  static const _channel = MethodChannel('com.corevice.goroterm/downloads');

  /// 一時ファイルを Downloads に保存し、ファイル名を返す。
  /// 一時ファイルは保存後に削除される（Android）。
  static Future<String> saveToDownloads({
    required String tempFilePath,
    required String fileName,
    String mimeType = 'application/octet-stream',
  }) async {
    if (Platform.isAndroid) {
      final result = await _channel.invokeMethod<String>('saveToDownloads', {
        'sourcePath': tempFilePath,
        'fileName': fileName,
        'mimeType': mimeType,
      });
      return result ?? fileName;
    } else {
      // iOS / その他: share_plus でシェアシートを表示
      await Share.shareXFiles([XFile(tempFilePath)]);
      return fileName;
    }
  }
}
