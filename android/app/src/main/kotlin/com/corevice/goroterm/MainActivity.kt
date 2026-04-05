package com.corevice.goroterm

import android.content.ContentValues
import android.net.Uri
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
    private val channel = "com.corevice.goroterm/downloads"
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

    /// MediaStore に挿入し、実際に付与された DISPLAY_NAME を返す。
    /// スコープドストレージでは他アプリのファイルをクエリできないため、
    /// 挿入→実名確認→自動リネームされていたら削除して正しい形式で再試行する。
    private fun insertAndGetActualName(
        targetName: String,
        mimeType: String,
    ): Pair<Uri, String> {
        val resolver = contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, targetName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("Failed to create MediaStore entry")

        // 実際に MediaStore が付与した DISPLAY_NAME を取得
        val actualName = resolver.query(
            uri,
            arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
            null, null, null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        } ?: targetName

        return Pair(uri, actualName)
    }

    private suspend fun saveToDownloads(sourcePath: String, fileName: String, mimeType: String): String {
        return withContext(Dispatchers.IO) {
            val sourceFile = File(sourcePath)
            if (!sourceFile.exists()) throw IllegalArgumentException("Source file not found: $sourcePath")

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val resolver = contentResolver
                val dotIdx = fileName.lastIndexOf('.')
                val baseName = if (dotIdx > 0) fileName.substring(0, dotIdx) else fileName
                val ext = if (dotIdx > 0) fileName.substring(dotIdx) else ""

                var savedUri: Uri? = null
                var savedName = fileName

                // 最大100回まで試行
                for (counter in 0..99) {
                    val targetName = if (counter == 0) fileName else "$baseName ($counter)$ext"
                    val (uri, actualName) = insertAndGetActualName(targetName, mimeType)

                    if (actualName == targetName) {
                        // MediaStore がリネームしなかった → この名前で確定
                        savedUri = uri
                        savedName = targetName
                        break
                    } else {
                        // MediaStore が自動リネームした → 削除して次の連番を試す
                        resolver.delete(uri, null, null)
                    }
                }

                val uri = savedUri
                    ?: throw IllegalStateException("Failed to find unique filename after 100 attempts")

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
                    resolver.delete(uri, null, null)
                    throw e
                }
                sourceFile.delete()
                savedName
            } else {
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
