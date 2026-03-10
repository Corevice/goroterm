---
goal: "Phase 28 - ファイルダウンロード全面改修: 黒画面バグ修正 + MediaStore直接保存 + メモリ効率改善"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 28: ファイルダウンロード全面改修

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題一覧

### 問題 1: ダウンロード中にアプリを切り替えると画面が真っ黒になる

`downloadFile()` の `await for` ループ中にアプリがバックグラウンドへ → SSH 切断 → `setChannelManager(null)` → `state = AsyncError` → Drawer に黒画面エラー表示。`downloadFile()` は unawaited で例外が握りつぶされ、`downloadProgress` がクリアされない。

### 問題 2: ダウンロード完了後（進捗 100%）に次のステップに進まない

`await for (chunk in session.stdout)` が永遠に終了しない。dartssh2 の `_handleChannelClose()` が `_remoteStream.close()` を呼ばないバグにより、SSH サーバーが Channel_EOF なしで Channel_Close を送信した場合（またはタイミング問題）、stdout ストリームが閉じず `await for` がハングする。

### 問題 3: FlutterFileDialog.saveFile がバックグラウンドでハングする

SAF ダイアログはフォアグラウンド必須。バックグラウンドで到達すると Future がハングする。さらに一時ファイル → 保存先の二重コピーでディスク使用量が倍増する。

### 問題 4: SSHSession のメモリリーク（2MB/ダウンロード）

`readFileViaExec()` が `Stream<List<int>>` を返すため `SSHSession` への参照が失われ、`session.close()` が呼ばれない。dartssh2 の `SSHClient._channels` マップにチャネルが残り、2MB のウィンドウバッファがリークする。

---

## 修正方針

### A. FlutterFileDialog を廃止し、Android MediaStore で直接 Downloads に保存

**現在**: SSH ストリーム → 一時ファイル → SAF ダイアログ（ユーザー操作必要、バックグラウンドでハング）
**変更後**: SSH ストリーム → 一時ファイル → MethodChannel で MediaStore Downloads に移動（ユーザー操作不要、バックグラウンド動作可能）

Android の `ContentResolver.insert()` + `MediaStore.Downloads.EXTERNAL_CONTENT_URI` を使い、ダウンロード完了後に一時ファイルを Downloads に保存する。ファイルはシステムの「ファイル」アプリに自動的に表示される。iOS では `share_plus`（既に pubspec.yaml に存在）を使ってシェアシートを表示する。

### B. `await for` を `.listen()` + `Completer` + `session.done` に置き換え

dartssh2 のバグ回避。3 つの終了条件を OR で待機:
- `onDone`: ストリームが正常に閉じた場合
- `received >= totalBytes`: 全データ受信済み → ストリーム終了を待たずに完了
- `session.done`: SSH チャネル閉鎖のフォールバック

### C. 世代番号によるキャンセル + baseState によるクリーンアップ

Codex レビュー指摘対応:
- `_downloadGeneration` で `setChannelManager()` 呼び出しを検知しキャンセル
- `baseState` でダウンロード開始時の状態を保持し、`AsyncError` 状態でも確実にクリア
- `_isDownloading` 中は `AsyncError` 遷移を遅延

### D. SSHSession の明示的 close + IOSink の定期 flush

- `readFileViaExec()` → `openExecStream()` に変更、`SSHSession` を返す
- ダウンロード後に `session.close()` で 2MB チャネルバッファを解放
- 1MB ごとに `sink.flush()` で Dart ヒープのメモリ圧縮

---

## 実装手順

### 手順 1: Android ネイティブ — MediaStore ヘルパー

ファイル: `android/app/src/main/kotlin/com/example/terminal_ssh_app/MainActivity.kt`

`MainActivity` に `MethodChannel` を追加し、一時ファイルを MediaStore Downloads にコピーするメソッドを実装する。

変更前:
```kotlin
package com.example.terminal_ssh_app

import io.flutter.embedding.android.FlutterActivity

class MainActivity: FlutterActivity()
```

変更後:
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

### 手順 2: Dart 側 — DownloadHelper プラットフォームヘルパー

ファイル: `lib/core/platform/download_helper.dart`（新規作成）

```dart
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

/// プラットフォーム固有のファイル保存ヘルパー。
/// Android: MediaStore API で Downloads フォルダに保存（ユーザー操作不要）。
/// iOS/その他: share_plus でシェアシートを表示。
class DownloadHelper {
  static const _channel = MethodChannel('com.example.terminal_ssh_app/downloads');

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
      // share_plus 10.x API: Share.shareXFiles
      await Share.shareXFiles([XFile(tempFilePath)]);
      return fileName;
    }
  }
}
```

### 手順 3: readFileViaExec → openExecStream（メモリリーク修正）

ファイル: `lib/core/ssh/ssh_channel_manager.dart`

変更前:
```dart
Future<Stream<List<int>>> readFileViaExec(String remotePath) async {
  try {
    final escaped = remotePath.replaceAll("'", r"'\''");
    final session = await client.execute("cat '$escaped'");
    return session.stdout.cast<List<int>>();
  } catch (e) {
    throw NetworkError('Failed to read file via exec: $e');
  }
}
```

変更後:
```dart
/// 高速ファイルダウンロード: cat コマンドの SSHSession を返す。
/// 呼び出し元で session.stdout を消費後、session.close() を呼んで
/// SSH チャネル（2MB ウィンドウバッファ）を解放すること。
Future<SSHSession> openExecStream(String remotePath) async {
  try {
    final escaped = remotePath.replaceAll("'", r"'\''");
    return await client.execute("cat '$escaped'");
  } catch (e) {
    throw NetworkError('Failed to open exec stream: $e');
  }
}
```

### 手順 4: downloadFile() の全面リファクタリング

ファイル: `lib/features/file_browser/file_browser_provider.dart`

#### 4a. import 変更

変更前:
```dart
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
```

変更後:
```dart
import '../../core/platform/download_helper.dart';
```

#### 4b. 状態変数の追加

`FileBrowserNotifier` クラスの既存フィールドの近くに追加:
```dart
bool _isDownloading = false;
int _downloadGeneration = 0;
```

#### 4c. downloadFile() + _downloadFileCore() の書き換え

変更前（既存の downloadFile メソッド全体を置き換え）:
```dart
Future<void> downloadFile(String remotePath) async {
  final sftp = _sftp ?? (throw NetworkError('SFTP not initialized'));
  final current = state.valueOrNull ?? const FileBrowserState();
  final filename = p.basename(remotePath);

  // 一時ファイルにダウンロード（Android Scoped Storage / iOS を問わず権限不要）
  final tempDir = await getTemporaryDirectory();
  final tempPath = p.join(tempDir.path, filename);
  final tempFile = File(tempPath);
  // 前回ダウンロードの残りがあれば削除
  if (await tempFile.exists()) await tempFile.delete();

  // ファイルサイズを SFTP で取得（進捗表示用）
  int totalBytes = 0;
  try {
    final stat = await sftp.stat(remotePath);
    totalBytes = stat.size ?? 0;
  } catch (_) {
    // stat 失敗時は進捗なしでダウンロード継続
  }

  // cat コマンドで高速ダウンロード（SFTP の 16KB チャンク制限を回避）
  final channelManager = _channelManager ??
      (throw NetworkError('Channel manager not initialized'));
  final stdout = await channelManager.readFileViaExec(remotePath);

  int received = 0;
  int lastProgressUpdate = 0;
  final sink = tempFile.openWrite();
  try {
    await for (final chunk in stdout) {
      // バイナリデータをそのまま書き込み（String 変換しないこと！）
      sink.add(chunk);
      received += chunk.length;
      // 64KB ごとに進捗更新（UI 負荷を軽減）
      if (totalBytes > 0 && received - lastProgressUpdate >= 65536) {
        lastProgressUpdate = received;
        final progress = received / totalBytes;
        final cur = state.valueOrNull ?? current;
        state = AsyncData(cur.copyWith(downloadProgress: progress));
      }
    }
    // 最終進捗
    if (totalBytes > 0) {
      final cur = state.valueOrNull ?? current;
      state = AsyncData(cur.copyWith(downloadProgress: 1.0));
    }
  } finally {
    await sink.close();
  }

  // 整合性チェック: 受信バイト数とファイルサイズを比較
  if (totalBytes > 0 && received != totalBytes) {
    throw NetworkError(
      'Download incomplete: received $received of $totalBytes bytes',
    );
  }

  // システムの保存ダイアログを開く（Android: SAF, iOS: UIDocumentPickerViewController）
  // 権限不要で Download フォルダがデフォルト選択される
  String? savedPath;
  try {
    final params = SaveFileDialogParams(
      sourceFilePath: tempPath,
      fileName: filename,
    );
    savedPath = await FlutterFileDialog.saveFile(params: params);
  } catch (e) {
    debugPrint('FlutterFileDialog.saveFile error: $e');
    savedPath = tempPath; // フォールバック: 一時ファイルパスを返す
  }

  final cur = state.valueOrNull ?? current;
  state = AsyncData(
    cur.copyWith(
      downloadProgress: null,
      downloadedFilePath: savedPath ?? tempPath,
    ),
  );
}
```

変更後:
```dart
bool _isDownloading = false;
int _downloadGeneration = 0;

Future<void> downloadFile(String remotePath) async {
  if (_isDownloading) return;
  _isDownloading = true;
  final baseState = state.valueOrNull ?? const FileBrowserState();
  try {
    await _downloadFileCore(remotePath, baseState);
  } catch (e) {
    debugPrint('downloadFile error: $e');
  } finally {
    _isDownloading = false;
    // AsyncError 状態を clobber しないよう、valueOrNull が null なら baseState にフォールバックしない
    final cur = state.valueOrNull;
    if (cur != null && cur.downloadProgress != null) {
      state = AsyncData(cur.copyWith(downloadProgress: null));
    }
    // ダウンロード終了後、接続が切れていたら AsyncError に遷移
    if (_channelManager == null) {
      state = AsyncError(NetworkError('SSH not connected'), StackTrace.current);
    }
  }
}

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
  int lastProgressUpdate = 0;
  int lastFlush = 0;
  final sink = tempFile.openWrite();
  try {
    // 【重要】await for を使わない。dartssh2 のバグにより stdout ストリームが
    // 閉じない場合がある。.listen() + Completer + session.done で回避。
    final completer = Completer<void>();
    StreamSubscription<List<int>>? subscription;
    Object? streamError;

    subscription = execSession.stdout.cast<List<int>>().listen(
      (chunk) {
        if (completer.isCompleted) return;
        if (_downloadGeneration != generation) {
          streamError = NetworkError('Download cancelled');
          subscription?.cancel();
          if (!completer.isCompleted) completer.complete();
          return;
        }
        sink.add(chunk);
        received += chunk.length;
        // 1MB ごとに flush（メモリ効率改善）
        if (received - lastFlush >= 1024 * 1024) {
          lastFlush = received;
          sink.flush();
        }
        if (totalBytes > 0 && received - lastProgressUpdate >= 65536) {
          lastProgressUpdate = received;
          final cur = state.valueOrNull ?? baseState;
          state = AsyncData(
            cur.copyWith(downloadProgress: received / totalBytes),
          );
        }
        // 全データ受信済み → ストリーム終了を待たずに完了
        if (totalBytes > 0 && received >= totalBytes) {
          subscription?.cancel();
          if (!completer.isCompleted) completer.complete();
        }
      },
      onError: (Object e) {
        streamError = e;
        if (!completer.isCompleted) completer.complete();
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: true,
    );

    // session.done は stdout が完全に drain される前に完了する可能性がある。
    // 200ms 遅延を入れて tail bytes のドロップを防ぐ。
    final doneFallback = execSession.done.then((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!completer.isCompleted) {
        streamError ??= NetworkError('Channel closed before stdout done');
        completer.complete();
      }
    });

    await completer.future;
    await subscription.cancel();
    await doneFallback.catchError((_) {});

    if (streamError != null) throw streamError!;

    if (totalBytes > 0) {
      final cur = state.valueOrNull ?? baseState;
      state = AsyncData(cur.copyWith(downloadProgress: 1.0));
    }
  } finally {
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
  // ユーザー操作不要・バックグラウンドでも動作する
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

### 手順 5: setChannelManager() で世代番号をインクリメント

ファイル: `lib/features/file_browser/file_browser_provider.dart`

変更前:
```dart
void setChannelManager(SshChannelManager? channelManager) {
  if (_channelManager == channelManager) return;
  _channelManager = channelManager;
  _sftp = null;
  if (channelManager != null) {
    _initializeState(channelManager);
  } else {
    state = AsyncError(NetworkError('SSH not connected'), StackTrace.current);
  }
}
```

変更後:
```dart
void setChannelManager(SshChannelManager? channelManager) {
  if (_channelManager == channelManager) return;
  _channelManager = channelManager;
  _sftp = null;
  _downloadGeneration++;
  if (channelManager != null) {
    _initializeState(channelManager);
  } else {
    // ダウンロード中は AsyncError 遷移を遅延
    // downloadFile() の finally で _channelManager == null をチェックし遷移する
    if (!_isDownloading) {
      state = AsyncError(NetworkError('SSH not connected'), StackTrace.current);
    }
  }
}
```

### 手順 6: pubspec.yaml から flutter_file_dialog を削除

ファイル: `pubspec.yaml`

変更前:
```yaml
  flutter_file_dialog: ^3.0.0
```

変更後:（この行を削除）

削除後に `~/flutter/bin/flutter pub get` を実行すること。

### 手順 7: share_plus の API 確認

`share_plus: ^10.0.0` は既に pubspec.yaml に存在する。`DownloadHelper` で使用する `SharePlus.instance.share(ShareParams(...))` が share_plus 10.x の API に準拠していることを確認すること。もし API が異なる場合は `Share.shareXFiles([XFile(path)])` 等の互換 API を使用する。

---

## テストへの影響

- `file_browser_provider_test.dart`: `downloadFile()` の内部構造変更。`readFileViaExec` → `openExecStream` のモック変更が必要
- `downloadFile()` が例外を re-throw しなくなる
- `setChannelManager(null)` のダウンロード中挙動変更
- `FlutterFileDialog` のモック/テストは不要になる
- `DownloadHelper` は MethodChannel を使うため、テストでは `TestDefaultBinaryMessengerBinding` でモックが必要
- Android ネイティブコード（`MainActivity.kt`）は `~/flutter/bin/flutter build apk --debug` で検証

## 実装順序

1. `android/app/src/main/kotlin/com/example/terminal_ssh_app/MainActivity.kt`:
   - MethodChannel + `saveToDownloads` メソッド追加
2. `lib/core/platform/download_helper.dart`（新規作成）:
   - MethodChannel ラッパー + iOS share_plus フォールバック
3. `lib/core/ssh/ssh_channel_manager.dart`:
   - `readFileViaExec()` → `openExecStream()` に変更
4. `lib/features/file_browser/file_browser_provider.dart`:
   - import 変更（`flutter_file_dialog` → `download_helper`）
   - `_isDownloading` / `_downloadGeneration` 追加
   - `downloadFile()` + `_downloadFileCore()` 書き換え
   - `setChannelManager()` 変更
5. `pubspec.yaml`:
   - `flutter_file_dialog` 削除
   - `~/flutter/bin/flutter pub get`
6. テスト確認・修正
7. `~/flutter/bin/flutter analyze`
8. `~/flutter/bin/flutter test`
9. `~/flutter/bin/flutter build apk --debug`
