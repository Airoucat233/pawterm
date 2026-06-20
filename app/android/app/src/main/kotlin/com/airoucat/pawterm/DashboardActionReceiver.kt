package com.airoucat.pawterm

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper

/**
 * 仪表盘通知里「允许 / 拒绝」按钮的接收端。点按钮**不打开 App**，而是把决定
 * 通过方法通道转发给（前台服务保活下仍存活的）Dart isolate，由它调服务端审批接口。
 *
 * onReceive 在主线程，方法通道调用需在主线程——这里直接用主线程 Handler 兜底。
 */
class DashboardActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION = "pawterm.dashboard.ACTION"
        const val EXTRA_DECISION = "decision" // "allow" | "deny"
        const val EXTRA_UUID = "uuid"
        const val EXTRA_AGENT = "agent"
        const val EXTRA_REQUEST_ID = "request_id"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return
        val decision = intent.getStringExtra(EXTRA_DECISION) ?: return
        val uuid = intent.getStringExtra(EXTRA_UUID) ?: return
        val agent = intent.getStringExtra(EXTRA_AGENT) ?: ""
        val requestId = intent.getStringExtra(EXTRA_REQUEST_ID) ?: ""

        val payload = mapOf(
            "decision" to decision,
            "uuid" to uuid,
            "agent" to agent,
            "request_id" to requestId,
        )
        Handler(Looper.getMainLooper()).post {
            MainActivity.dashboardChannel?.invokeMethod("dashboardApproval", payload)
        }
    }
}
