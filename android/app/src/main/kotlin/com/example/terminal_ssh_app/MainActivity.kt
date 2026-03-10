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
