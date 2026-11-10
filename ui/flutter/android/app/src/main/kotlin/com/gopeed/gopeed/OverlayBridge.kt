package com.gopeed.gopeed

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * 悬浮窗/通知的统一入口。
 *
 * 静默模式下的下载反馈必须完全脱离 Activity：
 * 想要悬浮窗就起 DownloadOverlayService（系统级 overlay），
 * 用户关掉了悬浮窗就只发通知。
 */
object OverlayBridge {

    private const val KEY_OVERLAY = "overlay_enabled"
    private const val KEY_MODE = "silent_mode"

    fun overlayEnabled(ctx: Context): Boolean =
        RootHelper.prefs(ctx).getBoolean(KEY_OVERLAY, true)

    fun setOverlayEnabled(ctx: Context, on: Boolean) {
        RootHelper.prefs(ctx).edit().putBoolean(KEY_OVERLAY, on).apply()
    }

    /** 静默下载已成功投递：按用户偏好显示系统悬浮窗或通知。 */
    fun showIfEnabled(ctx: Context, url: String, name: String) {
        if (overlayEnabled(ctx) && DownloadOverlayService.canDraw(ctx)) {
            DownloadOverlayService.show(ctx, url, name)
        } else {
            notify(ctx, "已开始下载", name)
        }
    }

    fun notifyFailed(ctx: Context, name: String) {
        notify(ctx, "下载启动失败", "$name\n请确认模块服务正在运行（设置 → 模块）")
    }

    fun hide(ctx: Context) {
        DownloadOverlayService.hide(ctx)
    }

    fun notify(ctx: Context, title: String, text: String) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        val id = "gopeed_notify"
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(id) == null) {
            nm.createNotificationChannel(
                NotificationChannel(id, "下载通知", NotificationManager.IMPORTANCE_DEFAULT),
            )
        }
        val intent = Intent(ctx, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val flags = if (Build.VERSION.SDK_INT >= 23)
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        else PendingIntent.FLAG_UPDATE_CURRENT
        val pi = PendingIntent.getActivity(ctx, 3, intent, flags)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, id)
        else @Suppress("DEPRECATION") Notification.Builder(ctx)
        val n = b.setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        try {
            nm.notify(0x6F70, n)
        } catch (_: Throwable) {
        }
    }
}
