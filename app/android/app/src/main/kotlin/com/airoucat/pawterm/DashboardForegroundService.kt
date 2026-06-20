package com.airoucat.pawterm

import android.app.Notification
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 单条「会话仪表盘」前台服务。
 *
 * 设计要点（替代 flutter_foreground_task 做这块的保活 + 富通知）：
 * - 一个前台服务 = 一条常驻通知，整套后台会话状态就这一条（多行 InboxStyle）。
 * - 通知由 [MainActivity] 用现有 NotificationCompat 代码构建好，作为 Parcelable
 *   extra 传进来，服务 startForeground 展示；后续更新走
 *   NotificationManager.notify(同 [NOTIF_ID])，前台状态保持不变。
 * - 服务存活让 Dart isolate + SSE 在熄屏/后台不被 Doze 冻结（配合电池豁免）。
 */
class DashboardForegroundService : Service() {
    companion object {
        const val NOTIF_ID = 876510
        const val EXTRA_NOTIFICATION = "dashboard_notification"
        const val ACTION_START = "pawterm.dashboard.START"
        const val ACTION_STOP = "pawterm.dashboard.STOP"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        val notification: Notification? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent?.getParcelableExtra(EXTRA_NOTIFICATION, Notification::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent?.getParcelableExtra(EXTRA_NOTIFICATION)
            }
        if (notification == null) {
            stopSelf()
            return START_NOT_STICKY
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }
        // START_STICKY：被系统杀掉后尽量重建（重建时 intent 为 null，上面会 stopSelf）。
        return START_STICKY
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }
}
