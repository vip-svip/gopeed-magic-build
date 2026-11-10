package com.gopeed.gopeed

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * 系统级下载悬浮窗。
 *
 * 之前「浮窗」是首页里的一个 Flutter Positioned 组件，只能在 App 界面内部显示，
 * 本质就是 App 自己的弹窗，App 不在前台时根本不存在。
 *
 * 这里改成真正的系统悬浮窗（WindowManager + TYPE_APPLICATION_OVERLAY），
 * 独立于任何 Activity，App 不在前台、甚至没有界面时也能显示。
 *
 * 尺寸按用户要求压到最小：单行 40dp，只保留【文件名 + 取消 + 下载】。
 */
class DownloadOverlayService : Service() {

    companion object {
        const val ACTION_SHOW = "com.gopeed.gopeed.overlay.SHOW"
        const val ACTION_HIDE = "com.gopeed.gopeed.overlay.HIDE"
        const val EXTRA_URL = "url"
        const val EXTRA_NAME = "name"

        private const val CHANNEL_ID = "gopeed_overlay"
        private const val NOTIFY_ID = 0x6F76

        fun show(ctx: Context, url: String, name: String) {
            val i = Intent(ctx, DownloadOverlayService::class.java).apply {
                action = ACTION_SHOW
                putExtra(EXTRA_URL, url)
                putExtra(EXTRA_NAME, name)
            }
            @Suppress("DEPRECATION") ctx.startService(i)
        }

        fun hide(ctx: Context) {
            val i = Intent(ctx, DownloadOverlayService::class.java).apply { action = ACTION_HIDE }
            try {
                ctx.startService(i)
            } catch (_: Throwable) {
            }
        }

        /** 悬浮窗权限是否已授予。 */
        fun canDraw(ctx: Context): Boolean {
            if (Build.VERSION.SDK_INT < 23) return true
            return android.provider.Settings.canDrawOverlays(ctx)
        }

        /** 从 URL 猜一个可读文件名，避免请求头开销。 */
        fun guessName(url: String): String {
            return try {
                val noQuery = url.substringBefore('#').substringBefore('?')
                val seg = noQuery.trimEnd('/').substringAfterLast('/')
                val decoded = java.net.URLDecoder.decode(seg, "UTF-8")
                if (decoded.isBlank() || decoded.contains("://")) "新下载任务"
                else if (!decoded.contains('.')) "$decoded.bin"
                else decoded
            } catch (_: Throwable) {
                "新下载任务"
            }
        }
    }

    private var windowManager: WindowManager? = null
    private var root: View? = null
    private var nameView: TextView? = null
    private var currentUrl: String = ""
    private var currentName: String = ""

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(Context.WINDOW_SERVICE) as? WindowManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_HIDE -> {
                removeOverlay()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_SHOW -> {
                currentUrl = intent.getStringExtra(EXTRA_URL) ?: ""
                currentName = intent.getStringExtra(EXTRA_NAME)
                    ?: guessName(currentUrl)
                if (currentUrl.isNotBlank()) showOverlay()
            }
        }
        return START_STICKY
    }

    private fun dp(v: Int): Int =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    private fun roundBg(color: Int, radiusDp: Int, strokeColor: Int?, strokeDp: Int = 0): GradientDrawable {
        val d = GradientDrawable()
        d.shape = GradientDrawable.RECTANGLE
        d.cornerRadius = dp(radiusDp).toFloat()
        d.setColor(color)
        if (strokeColor != null && strokeDp > 0) d.setStroke(dp(strokeDp), strokeColor)
        return d
    }

    private fun showOverlay() {
        if (root != null) {
            nameView?.text = currentName
            return
        }
        if (!canDraw(this)) {
            // 没有悬浮窗权限：退化为通知，绝不弹 Activity 界面
            notifyBlocked()
            stopSelf()
            return
        }
        val wm = windowManager ?: run { stopSelf(); return }

        // ---- 单行容器：铺满左右，仅留 8dp 边距 ----
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), 0, dp(6), 0)
            background = roundBg(0xF21C1D22.toInt(), 20, 0x33FFFFFF, 1)
        }

        val label = TextView(this).apply {
            text = currentName
            setTextColor(Color.WHITE)
            textSize = 13f
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
            typeface = Typeface.DEFAULT
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        nameView = label

        val cancel = actionBtn("✕", 0x33FFFFFF) {
            removeOverlay()
            stopSelf()
        }
        val confirm = actionBtn("↓", 0xFF0A84FF.toInt()) {
            val url = currentUrl
            val name = currentName
            removeOverlay()
            Thread {
                val ok = postTask(url)
                if (!ok) runCatching {
                    RootHelper.ctl("start")
                    Thread.sleep(2500)
                }
                val done = ok || postTask(url)
                notifyResult(name, done)
            }.start()
            stopSelf()
        }

        row.addView(label)
        row.addView(cancel)
        row.addView(confirm)

        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            dp(40),
            if (Build.VERSION.SDK_INT >= 26)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            x = 0
            y = dp(88)
            horizontalMargin = 0.03f
        }

        try {
            wm.addView(row, lp)
            root = row
        } catch (t: Throwable) {
            notifyBlocked()
            stopSelf()
        }
    }

    private fun actionBtn(text: String, bg: Int, onClick: () -> Unit): TextView {
        return TextView(this).apply {
            this.text = text
            setTextColor(Color.WHITE)
            textSize = 14f
            gravity = Gravity.CENTER
            background = roundBg(bg, 16, null)
            layoutParams = LinearLayout.LayoutParams(dp(30), dp(30)).apply {
                marginStart = dp(6)
            }
            setOnClickListener { onClick() }
        }
    }

    private fun removeOverlay() {
        val v = root ?: return
        root = null
        nameView = null
        try {
            windowManager?.removeView(v)
        } catch (_: Throwable) {
        }
    }

    /** 直接投递到本机内核（模块以 root 常驻监听 127.0.0.1:port）。 */
    private fun postTask(url: String): Boolean {
        val port = RootHelper.modulePort(this)
        if (port <= 0) return false
        var conn: HttpURLConnection? = null
        return try {
            val body = "{\"req\":{\"url\":\"" + url.replace("\\", "\\\\").replace("\"", "\\\"") + "\"}}"
            conn = (URL("http://127.0.0.1:$port/api/v1/tasks").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 4000
                readTimeout = 6000
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
            }
            conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val code = conn.responseCode
            code in 200..299
        } catch (_: Throwable) {
            false
        } finally {
            try { conn?.disconnect() } catch (_: Throwable) {}
        }
    }

    private fun notifyBlocked() {
        notify("无法显示悬浮窗", "请在系统设置中允许 Gopeed 显示悬浮窗")
    }

    private fun notifyResult(name: String, ok: Boolean) {
        notify(if (ok) "已开始下载" else "下载启动失败", if (ok) name else "$name\n请检查模块服务是否运行")
    }

    private fun notify(title: String, text: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        // 按需建渠道：悬浮窗本身不常驻通知，只有结果通知需要渠道。
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL_ID) == null) {
            val ch = NotificationChannel(CHANNEL_ID, "下载通知", NotificationManager.IMPORTANCE_DEFAULT)
            nm.createNotificationChannel(ch)
        }
        val intent = Intent(this, MainActivity::class.java)
        val flags = if (Build.VERSION.SDK_INT >= 23)
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        else PendingIntent.FLAG_UPDATE_CURRENT
        val pi = PendingIntent.getActivity(this, 1, intent, flags)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
        else @Suppress("DEPRECATION") Notification.Builder(this)
        val n = b.setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        try {
            nm.notify(NOTIFY_ID + 1, n)
        } catch (_: Throwable) {
        }
    }
}
