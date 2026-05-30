package com.airoucat.pawterm

import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.webkit.MimeTypeMap
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val apkInstallerChannel = "pawterm/apk_installer"
    private val pendingApkDownloads = mutableSetOf<Long>()
    private var downloadReceiverRegistered = false
    private val downloadReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != DownloadManager.ACTION_DOWNLOAD_COMPLETE) return
            val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
            if (!pendingApkDownloads.remove(id)) return
            installDownloadedApk(id)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, apkInstallerChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "downloadAndInstallApk" -> {
                        val url = call.argument<String>("url")
                        val fileName = call.argument<String>("fileName") ?: "pawterm.apk"
                        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                        if (url.isNullOrBlank()) {
                            result.error("bad_args", "url required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val id = enqueueApkDownload(url, fileName, headers)
                            result.success(id)
                        } catch (e: Exception) {
                            result.error("download_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ensureDownloadReceiver()
    }

    override fun onDestroy() {
        if (downloadReceiverRegistered) {
            unregisterReceiver(downloadReceiver)
            downloadReceiverRegistered = false
        }
        super.onDestroy()
    }

    private fun ensureDownloadReceiver() {
        if (downloadReceiverRegistered) return
        val filter = IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(downloadReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(downloadReceiver, filter)
        }
        downloadReceiverRegistered = true
    }

    private fun enqueueApkDownload(
        url: String,
        fileName: String,
        headers: Map<String, String>,
    ): Long {
        ensureDownloadReceiver()
        val safeName = sanitizeFileName(fileName).ifBlank { "pawterm.apk" }
        val request = DownloadManager.Request(Uri.parse(url))
            .setTitle(safeName)
            .setDescription("下载完成后打开安装界面")
            .setMimeType("application/vnd.android.package-archive")
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            .setAllowedOverMetered(true)
            .setAllowedOverRoaming(true)
            .setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, safeName)
        headers.forEach { (key, value) ->
            if (key.isNotBlank() && value.isNotBlank()) request.addRequestHeader(key, value)
        }
        val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val id = manager.enqueue(request)
        pendingApkDownloads.add(id)
        return id
    }

    private fun installDownloadedApk(downloadId: Long) {
        val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val query = DownloadManager.Query().setFilterById(downloadId)
        val cursor: Cursor = manager.query(query) ?: return
        cursor.use {
            if (!it.moveToFirst()) return
            val statusIdx = it.getColumnIndex(DownloadManager.COLUMN_STATUS)
            val status = if (statusIdx >= 0) it.getInt(statusIdx) else -1
            if (status != DownloadManager.STATUS_SUCCESSFUL) return
            val uri = manager.getUriForDownloadedFile(downloadId) ?: return
            val mime = contentResolver.getType(uri)
                ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension("apk")
                ?: "application/vnd.android.package-archive"
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, mime)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            startActivity(intent)
        }
    }

    private fun sanitizeFileName(input: String): String =
        input.replace(Regex("""[\\/:*?"<>|]"""), "_")
}
