package com.airoucat.pawterm

import android.app.ActivityManager
import android.app.DownloadManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
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
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val apkInstallerChannel = "pawterm/apk_installer"
    private val notificationsChannel = "pawterm/notifications"
    private val sessionEventsChannelId = "session_events"
    private val sessionEventsGroup = "pawterm.session_events"
    private val sessionEventsSummaryId = 876501
    private val sessionEvents = ArrayDeque<String>()
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, notificationsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "addSessionEvent" -> {
                        val title = call.argument<String>("title") ?: "PawTerm"
                        val line = call.argument<String>("line") ?: ""
                        val payload = call.argument<String>("payload")
                        try {
                            addSessionEvent(title, line, payload)
                            result.success(null)
                        } catch (e: SecurityException) {
                            result.error("permission_denied", e.message, null)
                        } catch (e: Exception) {
                            result.error("notification_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        updateTaskLabel()
        ensureDownloadReceiver()
        ensureSessionEventsChannel()
    }

    @Suppress("DEPRECATION")
    private fun updateTaskLabel() {
        setTaskDescription(
            ActivityManager.TaskDescription(
                getString(R.string.app_name),
                R.mipmap.ic_launcher,
                0,
            ),
        )
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

    private fun showChatCompletionNotification(
        title: String,
        line: String,
        payload: String?,
    ) {
        addSessionEvent(title, line, payload)
    }

    private fun addSessionEvent(title: String, line: String, payload: String?) {
        ensureSessionEventsChannel()
        val cleanLine = line.ifBlank { title }
        sessionEvents.addFirst(cleanLine)
        while (sessionEvents.size > 8) sessionEvents.removeLast()

        val intent = Intent(this, MainActivity::class.java)
            .setAction("pawterm.SESSION_EVENTS")
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (!payload.isNullOrBlank()) {
            intent.putExtra("payload", payload)
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        val pendingIntent = PendingIntent.getActivity(this, sessionEventsSummaryId, intent, flags)
        val summaryTitle = "你收到了 ${sessionEvents.size} 条任务更新"
        val inboxStyle = NotificationCompat.InboxStyle()
        sessionEvents.take(5).forEach { inboxStyle.addLine(it) }
        if (sessionEvents.size > 5) inboxStyle.setSummaryText("+ ${sessionEvents.size - 5}")
        val eventId = (System.currentTimeMillis() and 0x7fffffff).toInt()

        val summaryNotification = NotificationCompat.Builder(this, sessionEventsChannelId)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("PawTerm")
            .setContentText(summaryTitle)
            .setStyle(inboxStyle)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setGroup(sessionEventsGroup)
            .setGroupSummary(true)
            .build()

        val eventNotification = NotificationCompat.Builder(this, sessionEventsChannelId)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(cleanLine)
            .setStyle(NotificationCompat.BigTextStyle().bigText(cleanLine))
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setGroup(sessionEventsGroup)
            .build()

        val manager = NotificationManagerCompat.from(this)
        Log.i("PawTermNotify", "addSessionEvent enabled=${manager.areNotificationsEnabled()} count=${sessionEvents.size} line=$cleanLine")
        manager.notify(sessionEventsSummaryId, summaryNotification)
        manager.notify(eventId, eventNotification)
    }

    private fun ensureSessionEventsChannel() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        manager.deleteNotificationChannel("chat_completion")
        manager.deleteNotificationChannel("chat_completion_native")
        val existing = manager.getNotificationChannel(sessionEventsChannelId)
        if (existing != null) return
        val channel = NotificationChannel(
            sessionEventsChannelId,
            "Session events",
            NotificationManager.IMPORTANCE_HIGH,
        )
        channel.description = "Completed replies and approval requests"
        manager.createNotificationChannel(channel)
    }

    private fun sanitizeFileName(input: String): String =
        input.replace(Regex("""[\\/:*?"<>|]"""), "_")
}
