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

    /// 重複しないファイルパスを返す。
    /// 例: "file.txt" が存在する場合 → "file (1).txt", "file (2).txt", ...
    private fun uniqueFile(dir: File, fileName: String): File {
        var candidate = File(dir, fileName)
        if (!candidate.exists()) return candidate

        val dotIdx = fileName.lastIndexOf('.')
        val baseName = if (dotIdx > 0) fileName.substring(0, dotIdx) else fileName
        val ext = if (dotIdx > 0) fileName.substring(dotIdx) else ""

        var counter = 1
        while (true) {
            candidate = File(dir, "$baseName ($counter)$ext")
            if (!candidate.exists()) return candidate
            counter++
        }
    }

    /// MediaStore の Downloads 内で重複しないファイル名を返す。
    /// 例: "file.txt" が存在する場合 → "file (1).txt", "file (2).txt", ...
    /// 拡張子は変更しない。
    private fun uniqueMediaStoreName(fileName: String): String {
        val resolver = contentResolver
        val dotIdx = fileName.lastIndexOf('.')
        val baseName = if (dotIdx > 0) fileName.substring(0, dotIdx) else fileName
        val ext = if (dotIdx > 0) fileName.substring(dotIdx) else ""

        // まず元のファイル名が存在するかチェック
        if (!mediaStoreFileExists(fileName)) return fileName

        var counter = 1
        while (true) {
            val candidate = "$baseName ($counter)$ext"
            if (!mediaStoreFileExists(candidate)) return candidate
            counter++
        }
    }

    /// Downloads ディレクトリ内に指定ファイル名が存在するかチェック
    private fun mediaStoreFileExists(fileName: String): Boolean {
        val resolver = contentResolver
        val projection = arrayOf(MediaStore.MediaColumns._ID)
        val selection = "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.RELATIVE_PATH} = ?"
        val selectionArgs = arrayOf(fileName, "${Environment.DIRECTORY_DOWNLOADS}/")
        return resolver.query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            projection, selection, selectionArgs, null
        )?.use { cursor -> cursor.count > 0 } ?: false
    }

    private suspend fun saveToDownloads(sourcePath: String, fileName: String, mimeType: String): String {
        return withContext(Dispatchers.IO) {
            val sourceFile = File(sourcePath)
            if (!sourceFile.exists()) throw IllegalArgumentException("Source file not found: $sourcePath")

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Android 10+ : MediaStore API
                // MediaStore の自動リネームは拡張子の後ろに番号を付ける場合があるため、
                // 自前で重複チェックして拡張子の前に番号を付ける
                val resolver = contentResolver
                val uniqueName = uniqueMediaStoreName(fileName)
                val contentValues = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, uniqueName)
                    put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
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
                uniqueName
            } else {
                // Android 9 以下: 直接 Downloads ディレクトリにコピー
                @Suppress("DEPRECATION")
                val downloadsDir = Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_DOWNLOADS
                )
                downloadsDir.mkdirs()
                val destFile = uniqueFile(downloadsDir, fileName)
                sourceFile.copyTo(destFile, overwrite = false)
                sourceFile.delete()
                destFile.name
            }
        }
    }
}
