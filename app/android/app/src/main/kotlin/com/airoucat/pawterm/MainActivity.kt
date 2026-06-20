package com.airoucat.pawterm

import android.app.ActivityManager
import android.app.DownloadManager
import android.app.Notification
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
    private val activeSessionsChannelId = "active_session_progress"
    private val sessionEventsGroup = "pawterm.session_events"
    private val sessionEventsSummaryId = 876501
    private val activeSessionsNotificationId = 876502
    private val dashboardChannelId = "session_dashboard"
    private var dashboardRunning = false
    private val sessionEvents = ArrayDeque<String>()
    private val pendingApkDownloads = mutableSetOf<Long>()
    private var notificationsMethodChannel: MethodChannel? = null
    private var pendingNotificationPayload: String? = null
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
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, notificationsChannel)
        notificationsMethodChannel = channel
        channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialNotificationPayload" -> {
                        val payload = pendingNotificationPayload ?: notificationPayloadFrom(intent)
                        pendingNotificationPayload = null
                        result.success(payload)
                    }
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
                    "updateActiveSessionProgress" -> {
                        val title = call.argument<String>("title") ?: "PawTerm 会话进度"
                        val summary = call.argument<String>("summary") ?: ""
                        val lines = call.argument<List<String>>("lines") ?: emptyList()
                        val payload = call.argument<String>("payload")
                        try {
                            updateActiveSessionProgress(title, summary, lines, payload)
                            result.success(null)
                        } catch (e: SecurityException) {
                            result.error("permission_denied", e.message, null)
                        } catch (e: Exception) {
                            result.error("notification_failed", e.message, null)
                        }
                    }
                    "clearActiveSessionProgress" -> {
                        NotificationManagerCompat.from(this).cancel(activeSessionsNotificationId)
                        result.success(null)
                    }
                    "clearSessionNotifications" -> {
                        clearSessionNotifications()
                        result.success(null)
                    }
                    "startDashboard", "updateDashboard" -> {
                        val title = call.argument<String>("title") ?: "PawTerm"
                        val summary = call.argument<String>("summary") ?: ""
                        val lines = call.argument<List<String>>("lines") ?: emptyList()
                        val alert = call.argument<Boolean>("alert") ?: false
                        val payload = call.argument<String>("payload")
                        try {
                            startOrUpdateDashboard(title, summary, lines, alert, payload)
                            result.success(null)
                        } catch (e: SecurityException) {
                            result.error("permission_denied", e.message, null)
                        } catch (e: Exception) {
                            result.error("dashboard_failed", e.message, null)
                        }
                    }
                    "stopDashboard" -> {
                        stopDashboard()
                        result.success(null)
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
        ensureActiveSessionsChannel()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        deliverNotificationPayload(intent)
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

    private fun deliverNotificationPayload(intent: Intent?) {
        val payload = notificationPayloadFrom(intent) ?: return
        clearSessionNotifications()
        val channel = notificationsMethodChannel
        if (channel == null) {
            pendingNotificationPayload = payload
            return
        }
        channel.invokeMethod("notificationTapped", payload)
    }

    private fun notificationPayloadFrom(intent: Intent?): String? {
        if (intent == null) return null
        val action = intent.action
        if (action != "pawterm.SESSION_EVENTS" &&
            action != "pawterm.ACTIVE_SESSION_PROGRESS" &&
            action != "pawterm.DASHBOARD"
        ) {
            return null
        }
        return intent.getStringExtra("payload")?.takeIf { it.isNotBlank() }
    }

    private fun clearSessionNotifications() {
        val manager = NotificationManagerCompat.from(this)
        manager.cancel(sessionEventsSummaryId)
        manager.cancel(activeSessionsNotificationId)
        sessionEvents.clear()
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
        val summaryPendingIntent = PendingIntent.getActivity(this, sessionEventsSummaryId, intent, flags)
        val singleEvent = sessionEvents.size == 1
        val summaryTitle = if (singleEvent) title else "${sessionEvents.size} 条会话更新"
        val summaryText = if (singleEvent) cleanLine else summaryTitle
        val inboxStyle = NotificationCompat.InboxStyle()
        sessionEvents.take(5).forEach { inboxStyle.addLine(it) }
        if (sessionEvents.size > 5) inboxStyle.setSummaryText("+ ${sessionEvents.size - 5}")

        val summaryNotification = NotificationCompat.Builder(this, sessionEventsChannelId)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(summaryTitle)
            .setContentText(summaryText)
            .setStyle(inboxStyle)
            .setContentIntent(summaryPendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .build()

        val manager = NotificationManagerCompat.from(this)
        Log.i("PawTermNotify", "addSessionEvent enabled=${manager.areNotificationsEnabled()} count=${sessionEvents.size} line=$cleanLine")
        manager.notify(sessionEventsSummaryId, summaryNotification)
    }

    private fun updateActiveSessionProgress(
        title: String,
        summary: String,
        lines: List<String>,
        payload: String?,
    ) {
        ensureActiveSessionsChannel()
        val intent = Intent(this, MainActivity::class.java)
            .setAction("pawterm.ACTIVE_SESSION_PROGRESS")
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (!payload.isNullOrBlank()) {
            intent.putExtra("payload", payload)
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        val pendingIntent = PendingIntent.getActivity(this, activeSessionsNotificationId, intent, flags)
        val inboxStyle = NotificationCompat.InboxStyle()
        lines.take(6).forEach { inboxStyle.addLine(it) }
        if (lines.size > 6) inboxStyle.setSummaryText("+ ${lines.size - 6}")

        val notification = NotificationCompat.Builder(this, activeSessionsChannelId)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(summary.ifBlank { title })
            .setStyle(inboxStyle)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .build()

        NotificationManagerCompat.from(this).notify(activeSessionsNotificationId, notification)
    }

    /** 启动或更新单条会话仪表盘前台服务（多行 InboxStyle 常驻通知）。 */
    private fun startOrUpdateDashboard(
        title: String,
        summary: String,
        lines: List<String>,
        alert: Boolean,
        payload: String?,
    ) {
        ensureDashboardChannel()
        val notification = buildDashboardNotification(title, summary, lines, alert, payload)
        if (!dashboardRunning) {
            val intent = Intent(this, DashboardForegroundService::class.java).apply {
                action = DashboardForegroundService.ACTION_START
                putExtra(DashboardForegroundService.EXTRA_NOTIFICATION, notification)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            dashboardRunning = true
        } else {
            // 已在前台：直接更新同 id 通知，前台状态不变；alert=true 时（事件）
            // onlyAlertOnce=false 让它再次 heads-up（在 buildDashboardNotification 里设）。
            NotificationManagerCompat.from(this)
                .notify(DashboardForegroundService.NOTIF_ID, notification)
        }
    }

    private fun stopDashboard() {
        if (!dashboardRunning) return
        dashboardRunning = false
        val intent = Intent(this, DashboardForegroundService::class.java).apply {
            action = DashboardForegroundService.ACTION_STOP
        }
        try {
            startService(intent)
        } catch (_: Exception) {
        }
        NotificationManagerCompat.from(this).cancel(DashboardForegroundService.NOTIF_ID)
    }

    private fun buildDashboardNotification(
        title: String,
        summary: String,
        lines: List<String>,
        alert: Boolean,
        payload: String?,
    ): Notification {
        val intent = Intent(this, MainActivity::class.java)
            .setAction("pawterm.DASHBOARD")
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (!payload.isNullOrBlank()) {
            intent.putExtra("payload", payload)
        }
        val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        val pendingIntent =
            PendingIntent.getActivity(this, DashboardForegroundService.NOTIF_ID, intent, piFlags)
        val inboxStyle = NotificationCompat.InboxStyle()
        lines.take(8).forEach { inboxStyle.addLine(it) }
        if (lines.size > 8) inboxStyle.setSummaryText("+ ${lines.size - 8}")
        return NotificationCompat.Builder(this, dashboardChannelId)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(summary.ifBlank { title })
            .setStyle(inboxStyle)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(!alert)
            .setPriority(
                if (alert) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_LOW,
            )
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .build()
    }

    private fun ensureDashboardChannel() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (manager.getNotificationChannel(dashboardChannelId) != null) return
        val channel = NotificationChannel(
            dashboardChannelId,
            "Session dashboard",
            // HIGH：事件(完成/审批)时 onlyAlertOnce=false 能再次 heads-up。
            NotificationManager.IMPORTANCE_HIGH,
        )
        channel.description = "Live multi-session dashboard"
        manager.createNotificationChannel(channel)
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

    private fun ensureActiveSessionsChannel() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val existing = manager.getNotificationChannel(activeSessionsChannelId)
        if (existing != null) return
        val channel = NotificationChannel(
            activeSessionsChannelId,
            "Active session progress",
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.description = "Live status for active background sessions"
        manager.createNotificationChannel(channel)
    }

    private fun sanitizeFileName(input: String): String =
        input.replace(Regex("""[\\/:*?"<>|]"""), "_")
}
