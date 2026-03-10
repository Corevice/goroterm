---
goal: "Phase 31 - ダウンロード中の UI フリーズ修正（Isolate によるファイル I/O オフロード + Android バックグラウンドスレッド化）"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 31: ダウンロード中の UI フリーズ修正

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題

Phase 30 でダウンロード停止バグと速度改善を行ったが、以下の問題が残る:
1. **重めのファイルダウンロード中に UI が固まる（フリーズ）**
2. **ダウンロード速度がまだ遅い**

---

## 根本原因分析

### 原因 1: メインアイソレートでのファイル I/O

SSH ストリーム受信 → `sink.add()` → IOSink バッファリング → ファイル書き込みが **すべてメインの Dart アイソレート**で実行されている。
重いファイルではこの I/O 処理がイベントループを占有し、UI フレーム描画がブロックされる。

**証拠**: `lib/` 以下に `Isolate`、`compute()`、`IsolateChannel` の使用が一切ない。

### 原因 2: Android MediaStore コピーが UI スレッドで同期実行

`MainActivity.kt` の `saveToDownloads()` 内で:
```kotlin
inputStream.copyTo(outputStream, bufferSize = 65536)
```
これは MethodChannel のコールバック内、つまり **Android の UI スレッド**で実行される。
大容量ファイルではこのコピー処理中に Android 側の UI も固まる。

---

## 修正方針

### 方針 A: Dart 側 — ファイル書き込みを別 Isolate にオフロード

SSH ストリームから受信した chunk を **SendPort 経由でバックグラウンド Isolate に転送**し、
そちらでファイル書き込みを行う。メインアイソレートは chunk の受け渡しとカウンタ更新のみ。

`dart:isolate` の `Isolate.spawn()` + `ReceivePort`/`SendPort` を使用。
`compute()` はストリーミング処理に不向きなため使わない。

### 方針 B: Android 側 — MediaStore コピーをバックグラウンドスレッドに移動

`kotlinx.coroutines` の `withContext(Dispatchers.IO)` でファイルコピーをバックグラウンドスレッドに移す。

---

## 変更対象ファイル

1. `lib/core/platform/file_writer_isolate.dart` — **新規作成**
2. `lib/features/file_browser/file_browser_provider.dart` — 修正
3. `android/app/src/main/kotlin/com/example/terminal_ssh_app/MainActivity.kt` — 修正

---

## Step 1: バックグラウンド Isolate でのファイル書き込みユーティリティ作成

### 新規ファイル: `lib/core/platform/file_writer_isolate.dart`

```dart
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// バックグラウンド Isolate でファイル書き込みを行うユーティリティ。
/// メインアイソレートから SendPort 経由で chunk を送信し、
/// バックグラウンド側で IOSink.add() + flush + close を行う。
class FileWriterIsolate {
  FileWriterIsolate._(this._sendPort, this._isolate, this._exitPort);

  final SendPort _sendPort;
  final Isolate _isolate;
  final ReceivePort _exitPort;
  bool _closed = false;

  /// バックグラウンド Isolate を起動し、書き込み先ファイルを開く。
  static Future<FileWriterIsolate> open(String filePath) async {
    final receivePort = ReceivePort();
    final exitPort = ReceivePort();
    final errorPort = ReceivePort();

    final isolate = await Isolate.spawn(
      _isolateEntry,
      _InitMessage(filePath, receivePort.sendPort),
      onExit: exitPort.sendPort,
      onError: errorPort.sendPort,
    );

    // エラーポートのリスナー（デバッグ用、致命的エラーのログ出力）
    errorPort.listen((_) {});

    // Isolate 側から SendPort を受け取る
    final sendPort = await receivePort.first as SendPort;
    receivePort.close();
    errorPort.close();

    return FileWriterIsolate._(sendPort, isolate, exitPort);
  }

  /// chunk をバックグラウンド Isolate に送信して書き込む。
  /// メインアイソレートでは chunk のコピーオーバーヘッドのみ。
  void addChunk(Uint8List chunk) {
    if (_closed) return;
    _sendPort.send(chunk);
  }

  /// 書き込みを完了し、flush → close → Isolate 終了を待つ。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _sendPort.send(null); // null = 終了シグナル
    await _exitPort.first; // Isolate 終了を待つ
    _exitPort.close();
  }

  /// エラー時に Isolate を強制終了する。
  void kill() {
    if (_closed) return;
    _closed = true;
    _isolate.kill(priority: Isolate.immediate);
    _exitPort.close();
  }

  /// Isolate エントリポイント。
  static Future<void> _isolateEntry(_InitMessage msg) async {
    final port = ReceivePort();
    msg.sendPort.send(port.sendPort);

    final sink = File(msg.filePath).openWrite();

    await for (final data in port) {
      if (data == null) break; // 終了シグナル
      sink.add(data as Uint8List);
    }

    await sink.flush();
    await sink.close();
    port.close();
  }
}

class _InitMessage {
  const _InitMessage(this.filePath, this.sendPort);
  final String filePath;
  final SendPort sendPort;
}
```

---

## Step 2: `_downloadFileCore()` を Isolate ベースに書き換え

### ファイル: `lib/features/file_browser/file_browser_provider.dart`

#### 2-1. import 追加

**before:**
```dart
import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../core/platform/download_helper.dart';
import 'dart:io';

import '../../core/error/app_error.dart';
import '../../core/ssh/ssh_channel_manager.dart';
import '../../core/utils/shell_utils.dart';
```

**after:**
```dart
import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../core/platform/download_helper.dart';
import '../../core/platform/file_writer_isolate.dart';
import 'dart:io';

import '../../core/error/app_error.dart';
import '../../core/ssh/ssh_channel_manager.dart';
import '../../core/utils/shell_utils.dart';
```

#### 2-2. `_downloadFileCore()` メソッドの修正

**IOSink → FileWriterIsolate に置き換え。メインアイソレートでは chunk を SendPort に送るだけ。**

**before:**
```dart
  Future<void> _downloadFileCore(
    String remotePath,
    FileBrowserState baseState,
  ) async {
    final sftp = _sftp ?? (throw NetworkError('SFTP not initialized'));
    final filename = p.basename(remotePath);
    final generation = _downloadGeneration;

    // 一時ファイルにダウンロード
    final tempDir = await getTemporaryDirectory();
    final tempPath = p.join(tempDir.path, filename);
    final tempFile = File(tempPath);
    if (await tempFile.exists()) await tempFile.delete();

    // ファイルサイズを SFTP で取得（進捗表示用）
    int totalBytes = 0;
    try {
      final stat = await sftp.stat(remotePath);
      totalBytes = stat.size ?? 0;
    } catch (_) {}

    // cat コマンドで高速ダウンロード（SSHSession を保持してメモリリーク防止）
    final channelManager = _channelManager ??
        (throw NetworkError('Channel manager not initialized'));
    final execSession = await channelManager.openExecStream(remotePath);

    int received = 0;
    final sink = tempFile.openWrite();
    try {
      // 進捗更新はタイマーベース（200ms 間隔）。
      // ストリームリスナー内では state 更新や flush を行わない。
      // これにより Dart イベントループを軽量に保ち、
      // dartssh2 の SSH ウィンドウ調整が遅延なく処理される。
      final completer = Completer<void>();
      StreamSubscription<Uint8List>? subscription;
      Object? streamError;

      // 進捗タイマー: 200ms ごとに UI を更新
      // AsyncError/Loading 状態を上書きしないよう valueOrNull の null チェックを行う
      final progressTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) {
          if (totalBytes > 0 && received > 0) {
            final cur = state.valueOrNull;
            if (cur == null) return; // AsyncError/Loading を上書きしない
            state = AsyncData(
              cur.copyWith(downloadProgress: received / totalBytes),
            );
          }
        },
      );

      subscription = execSession.stdout.listen(
        (chunk) {
          if (completer.isCompleted) return;
          if (_downloadGeneration != generation) {
            streamError = NetworkError('Download cancelled');
            subscription?.cancel();
            if (!completer.isCompleted) completer.complete();
            return;
          }
          // リスナーは最小限の処理のみ:
          // sink.add() + カウンタ更新（state 更新や flush は行わない）
          sink.add(chunk);
          received += chunk.length;
          // 全データ受信済み → ストリーム終了を待たずに完了
          if (totalBytes > 0 && received >= totalBytes) {
            subscription?.cancel();
            if (!completer.isCompleted) completer.complete();
          }
        },
        onError: (Object e) {
          // エラー連発でリスナーが動き続けるのを防ぐため、即座にキャンセル
          if (completer.isCompleted) return;
          streamError ??= e;
          subscription?.cancel();
          completer.complete();
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
        cancelOnError: false,
      );

      // session.done フォールバック:
      // データ受信が止まってから 1 秒経過したら発動。
      // 大容量ファイルのバッファ drain に最大 30 秒待機。
      final doneFallback = execSession.done.then((_) async {
        var idleTicks = 0;
        var prev = received;
        for (var i = 0; i < 300 && !completer.isCompleted; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (received == prev) {
            idleTicks++;
            if (idleTicks >= 10) break; // 1 秒間データなし → 発動
          } else {
            prev = received;
            idleTicks = 0;
          }
        }
        if (!completer.isCompleted) {
          streamError ??= NetworkError('Channel closed before stdout done');
          completer.complete();
        }
      });

      await completer.future;
      progressTimer.cancel();
      await subscription.cancel();
      await doneFallback.catchError((_) {});

      if (streamError != null) throw streamError!;

      if (totalBytes > 0) {
        final cur = state.valueOrNull ?? baseState;
        state = AsyncData(cur.copyWith(downloadProgress: 1.0));
      }
    } finally {
      // IOSink.close() は OS レベルの flush を保証しないため、明示的に flush する
      await sink.flush();
      await sink.close();
      // SSH チャネル（2MB バッファ）を解放
      execSession.close();
    }

    // cat コマンドの終了コードをチェック（ファイル不在等のエラー検出）
    final exitCode = execSession.exitCode;
    if (exitCode != null && exitCode != 0) {
      throw NetworkError('cat command failed with exit code $exitCode');
    }

    // 整合性チェック
    if (totalBytes > 0 && received != totalBytes) {
      throw NetworkError(
        'Download incomplete: received $received of $totalBytes bytes',
      );
    }

    // キャンセル済みなら保存しない
    if (_downloadGeneration != generation) {
      throw NetworkError('Download cancelled');
    }

    // MediaStore で Downloads に保存（Android）/ シェアシート（iOS）
    String savedName;
    try {
      savedName = await DownloadHelper.saveToDownloads(
        tempFilePath: tempPath,
        fileName: filename,
      );
    } catch (e) {
      debugPrint('saveToDownloads error: $e');
      savedName = filename;
    }

    if (_downloadGeneration != generation) {
      throw NetworkError('Download cancelled');
    }

    final cur = state.valueOrNull ?? baseState;
    state = AsyncData(
      cur.copyWith(
        downloadProgress: null,
        downloadedFilePath: savedName,
      ),
    );
  }
```

**after:**
```dart
  Future<void> _downloadFileCore(
    String remotePath,
    FileBrowserState baseState,
  ) async {
    final sftp = _sftp ?? (throw NetworkError('SFTP not initialized'));
    final filename = p.basename(remotePath);
    final generation = _downloadGeneration;

    // 一時ファイルにダウンロード
    final tempDir = await getTemporaryDirectory();
    final tempPath = p.join(tempDir.path, filename);
    final tempFile = File(tempPath);
    if (await tempFile.exists()) await tempFile.delete();

    // ファイルサイズを SFTP で取得（進捗表示用）
    int totalBytes = 0;
    try {
      final stat = await sftp.stat(remotePath);
      totalBytes = stat.size ?? 0;
    } catch (_) {}

    // cat コマンドで高速ダウンロード（SSHSession を保持してメモリリーク防止）
    final channelManager = _channelManager ??
        (throw NetworkError('Channel manager not initialized'));
    final execSession = await channelManager.openExecStream(remotePath);

    int received = 0;
    // ファイル書き込みをバックグラウンド Isolate にオフロード。
    // メインアイソレートは chunk を SendPort 経由で転送するだけ。
    final writer = await FileWriterIsolate.open(tempPath);
    try {
      // 進捗更新はタイマーベース（200ms 間隔）。
      // ストリームリスナー内では state 更新や flush を行わない。
      // これにより Dart イベントループを軽量に保ち、
      // dartssh2 の SSH ウィンドウ調整が遅延なく処理される。
      final completer = Completer<void>();
      StreamSubscription<Uint8List>? subscription;
      Object? streamError;

      // 進捗タイマー: 200ms ごとに UI を更新
      // AsyncError/Loading 状態を上書きしないよう valueOrNull の null チェックを行う
      final progressTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) {
          if (totalBytes > 0 && received > 0) {
            final cur = state.valueOrNull;
            if (cur == null) return; // AsyncError/Loading を上書きしない
            state = AsyncData(
              cur.copyWith(downloadProgress: received / totalBytes),
            );
          }
        },
      );

      subscription = execSession.stdout.listen(
        (chunk) {
          if (completer.isCompleted) return;
          if (_downloadGeneration != generation) {
            streamError = NetworkError('Download cancelled');
            subscription?.cancel();
            if (!completer.isCompleted) completer.complete();
            return;
          }
          // リスナーは最小限の処理のみ:
          // chunk を Isolate に転送 + カウンタ更新（state 更新や flush は行わない）
          writer.addChunk(chunk);
          received += chunk.length;
          // 全データ受信済み → ストリーム終了を待たずに完了
          if (totalBytes > 0 && received >= totalBytes) {
            subscription?.cancel();
            if (!completer.isCompleted) completer.complete();
          }
        },
        onError: (Object e) {
          // エラー連発でリスナーが動き続けるのを防ぐため、即座にキャンセル
          if (completer.isCompleted) return;
          streamError ??= e;
          subscription?.cancel();
          completer.complete();
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
        cancelOnError: false,
      );

      // session.done フォールバック:
      // データ受信が止まってから 1 秒経過したら発動。
      // 大容量ファイルのバッファ drain に最大 30 秒待機。
      final doneFallback = execSession.done.then((_) async {
        var idleTicks = 0;
        var prev = received;
        for (var i = 0; i < 300 && !completer.isCompleted; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (received == prev) {
            idleTicks++;
            if (idleTicks >= 10) break; // 1 秒間データなし → 発動
          } else {
            prev = received;
            idleTicks = 0;
          }
        }
        if (!completer.isCompleted) {
          streamError ??= NetworkError('Channel closed before stdout done');
          completer.complete();
        }
      });

      await completer.future;
      progressTimer.cancel();
      await subscription.cancel();
      await doneFallback.catchError((_) {});

      if (streamError != null) throw streamError!;

      if (totalBytes > 0) {
        final cur = state.valueOrNull ?? baseState;
        state = AsyncData(cur.copyWith(downloadProgress: 1.0));
      }
    } finally {
      // Isolate 側で flush + close を行い、Isolate 終了を待つ。
      // エラー時は Isolate を強制終了。
      try {
        await writer.close();
      } catch (_) {
        writer.kill();
      }
      // SSH チャネル（2MB バッファ）を解放
      execSession.close();
    }

    // cat コマンドの終了コードをチェック（ファイル不在等のエラー検出）
    final exitCode = execSession.exitCode;
    if (exitCode != null && exitCode != 0) {
      throw NetworkError('cat command failed with exit code $exitCode');
    }

    // 整合性チェック
    if (totalBytes > 0 && received != totalBytes) {
      throw NetworkError(
        'Download incomplete: received $received of $totalBytes bytes',
      );
    }

    // キャンセル済みなら保存しない
    if (_downloadGeneration != generation) {
      throw NetworkError('Download cancelled');
    }

    // MediaStore で Downloads に保存（Android）/ シェアシート（iOS）
    String savedName;
    try {
      savedName = await DownloadHelper.saveToDownloads(
        tempFilePath: tempPath,
        fileName: filename,
      );
    } catch (e) {
      debugPrint('saveToDownloads error: $e');
      savedName = filename;
    }

    if (_downloadGeneration != generation) {
      throw NetworkError('Download cancelled');
    }

    final cur = state.valueOrNull ?? baseState;
    state = AsyncData(
      cur.copyWith(
        downloadProgress: null,
        downloadedFilePath: savedName,
      ),
    );
  }
```

**変更点まとめ:**
- `final sink = tempFile.openWrite();` → `final writer = await FileWriterIsolate.open(tempPath);`
- `sink.add(chunk);` → `writer.addChunk(chunk);`
- finally ブロック: `sink.flush()` / `sink.close()` → `writer.close()` (Isolate 側で flush + close)、エラー時は `writer.kill()`

---

## Step 3: Android MediaStore コピーをバックグラウンドスレッドに移動

### ファイル: `android/app/src/main/kotlin/com/example/terminal_ssh_app/MainActivity.kt`

**before:**
```kotlin
package com.example.terminal_ssh_app

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private val channel = "com.example.terminal_ssh_app/downloads"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveToDownloads" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val fileName = call.argument<String>("fileName")
                        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                        if (sourcePath == null || fileName == null) {
                            result.error("INVALID_ARGS", "sourcePath and fileName required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val savedPath = saveToDownloads(sourcePath, fileName, mimeType)
                            result.success(savedPath)
                        } catch (e: Exception) {
                            result.error("SAVE_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun saveToDownloads(sourcePath: String, fileName: String, mimeType: String): String {
        val sourceFile = File(sourcePath)
        if (!sourceFile.exists()) throw IllegalArgumentException("Source file not found: $sourcePath")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+ : MediaStore API
            val contentValues = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, contentValues)
                ?: throw IllegalStateException("Failed to create MediaStore entry")
            try {
                resolver.openOutputStream(uri)?.use { outputStream ->
                    FileInputStream(sourceFile).use { inputStream ->
                        inputStream.copyTo(outputStream, bufferSize = 65536)
                    }
                } ?: throw IllegalStateException("Failed to open output stream")
                resolver.update(uri, ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }, null, null)
            } catch (e: Exception) {
                // コピー失敗時に孤立した pending 行を削除（ロールバック）
                resolver.delete(uri, null, null)
                throw e
            }
            // 一時ファイルを削除
            sourceFile.delete()
            return fileName // URI ではなくファイル名を返す（UI 表示用）
        } else {
            // Android 9 以下: 直接 Downloads ディレクトリにコピー
            @Suppress("DEPRECATION")
            val downloadsDir = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS
            )
            downloadsDir.mkdirs()
            val destFile = File(downloadsDir, fileName)
            sourceFile.copyTo(destFile, overwrite = true)
            sourceFile.delete()
            return destFile.absolutePath
        }
    }
}
```

**after:**
```kotlin
package com.example.terminal_ssh_app

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private val channel = "com.example.terminal_ssh_app/downloads"
    private val scope = CoroutineScope(Dispatchers.Main)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveToDownloads" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val fileName = call.argument<String>("fileName")
                        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                        if (sourcePath == null || fileName == null) {
                            result.error("INVALID_ARGS", "sourcePath and fileName required", null)
                            return@setMethodCallHandler
                        }
                        // コルーチンでバックグラウンドスレッドに移動し、
                        // UI スレッドをブロックしない
                        scope.launch {
                            try {
                                val savedPath = saveToDownloads(sourcePath, fileName, mimeType)
                                result.success(savedPath)
                            } catch (e: Exception) {
                                result.error("SAVE_ERROR", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private suspend fun saveToDownloads(sourcePath: String, fileName: String, mimeType: String): String {
        return withContext(Dispatchers.IO) {
            val sourceFile = File(sourcePath)
            if (!sourceFile.exists()) throw IllegalArgumentException("Source file not found: $sourcePath")

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Android 10+ : MediaStore API
                val contentValues = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                    put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val resolver = contentResolver
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, contentValues)
                    ?: throw IllegalStateException("Failed to create MediaStore entry")
                try {
                    resolver.openOutputStream(uri)?.use { outputStream ->
                        FileInputStream(sourceFile).use { inputStream ->
                            inputStream.copyTo(outputStream, bufferSize = 65536)
                        }
                    } ?: throw IllegalStateException("Failed to open output stream")
                    resolver.update(uri, ContentValues().apply {
                        put(MediaStore.MediaColumns.IS_PENDING, 0)
                    }, null, null)
                } catch (e: Exception) {
                    // コピー失敗時に孤立した pending 行を削除（ロールバック）
                    resolver.delete(uri, null, null)
                    throw e
                }
                // 一時ファイルを削除
                sourceFile.delete()
                fileName // URI ではなくファイル名を返す（UI 表示用）
            } else {
                // Android 9 以下: 直接 Downloads ディレクトリにコピー
                @Suppress("DEPRECATION")
                val downloadsDir = Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_DOWNLOADS
                )
                downloadsDir.mkdirs()
                val destFile = File(downloadsDir, fileName)
                sourceFile.copyTo(destFile, overwrite = true)
                sourceFile.delete()
                destFile.absolutePath
            }
        }
    }
}
```

**変更点まとめ:**
- `kotlinx.coroutines` の import 追加（`CoroutineScope`, `Dispatchers`, `launch`, `withContext`）
- `CoroutineScope(Dispatchers.Main)` フィールド追加
- MethodChannel ハンドラ: `try/catch` を `scope.launch { ... }` でラップ
- `saveToDownloads()`: `private fun` → `private suspend fun`、`return withContext(Dispatchers.IO) { ... }` でファイル I/O をバックグラウンドスレッドに移動
- `return` 文を Kotlin の「ブロック末尾の式」スタイルに変更（`withContext` のラムダ内では `return` ではなく式で値を返す）

### Gradle 依存関係確認

`android/app/build.gradle` に `kotlinx-coroutines` の依存が必要。
ただし、Flutter プロジェクトでは `org.jetbrains.kotlin:kotlin-stdlib` を通じて Kotlin coroutines が利用可能な場合がある。
**明示的に依存を追加する必要がある場合のみ**、以下を追加:

`android/app/build.gradle` の `dependencies` ブロックに:
```groovy
implementation 'org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3'
```

**注意**: `flutter create` で生成されたプロジェクトでは通常 kotlinx-coroutines は含まれていないため、**この依存追加は必須**。

---

## Step 4: `android/app/build.gradle` に coroutines 依存を追加

### ファイル: `android/app/build.gradle`

dependencies ブロックに以下を追加:

**before (dependencies ブロック末尾付近):**
```groovy
dependencies {
    // ... 既存の依存 ...
}
```

**after:**
```groovy
dependencies {
    // ... 既存の依存 ...
    implementation 'org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3'
}
```

---

## 検証手順

1. `~/flutter/bin/flutter analyze` — 静的解析エラーなし
2. `~/flutter/bin/flutter test` — 既存テスト全パス
3. `~/flutter/bin/flutter build apk --debug` — ビルド成功
4. 実機テスト:
   - 小さいファイル（< 1MB）のダウンロード → 正常に完了、進捗表示あり
   - 中程度のファイル（5-20MB）のダウンロード → UI がスムーズに動作（フリーズしない）
   - 大きいファイル（50MB+）のダウンロード → UI がスムーズ、ダウンロード完了
   - ダウンロード中にファイルブラウザの操作（スクロール、ディレクトリ移動）が滑らか
   - ダウンロード中にタブ切り替え → フリーズしない
   - ダウンロードキャンセル（接続切断）→ Isolate が正常終了
