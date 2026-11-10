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

/**
 * 系统级下载确认浮窗（真正的悬浮窗，不是 App 内组件）。
 *
 * 用户要求（本轮）：
 * * **居中**：做小，做成对话框样式，默认折叠，**不进入 App**。
 * * **底部**：占屏幕高度的 2/5，默认折叠。
 * * 两种形态折叠时都只显示【文件名 + 大小 + 取消 + 下载】。
 *
 * 以前这里是 40dp 通栏单行，且尺寸写死，所以用户反复反馈「还是太大」。
 * 现在由设置里的「下载弹窗样式」决定形态，尺寸按形态分别设定。
 */
class DownloadOverlayService : Service() {

    companion object {
        const val ACTION_SHOW = "com.gopeed.gopeed.overlay.SHOW"
        const val ACTION_HIDE = "com.gopeed.gopeed.overlay.HIDE"
        const val EXTRA_URL = "url"
        const val EXTRA_NAME = "name"
        const val EXTRA_STYLE = "style"

        private const val CHANNEL_ID = "gopeed_overlay"
        private const val NOTIFY_ID = 0x6F76

        /** 形态：居中对话框 / 底部面板。 */
        const val STYLE_CENTER = "center"
        const val STYLE_BOTTOM = "bottom"

        fun show(ctx: Context, url: String, name: String, style: String? = null) {
            val i = Intent(ctx, DownloadOverlayService::class.java).apply {
                action = ACTION_SHOW
                putExtra(EXTRA_URL, url)
                putExtra(EXTRA_NAME, name)
                if (style != null) putExtra(EXTRA_STYLE, style)
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

        /** 读取用户在设置里选的弹窗样式。 */
        fun readStyle(ctx: Context): String {
            val v = runCatching {
                RootHelper.prefs(ctx).getString("dialog_presentation", STYLE_CENTER)
            }.getOrNull()
            return if (v == STYLE_BOTTOM) STYLE_BOTTOM else STYLE_CENTER
        }

        /** 人类可读体积。 */
        fun humanSize(bytes: Long): String {
            if (bytes <= 0) return "未知大小"
            val kb = bytes / 1024.0
            if (kb < 1024) return String.format("%.0f KB", kb)
            val mb = kb / 1024.0
            if (mb < 1024) return String.format("%.1f MB", mb)
            return String.format("%.2f GB", mb / 1024.0)
        }
    }

    private var windowManager: WindowManager? = null
    private var root: View? = null
    private var nameView: TextView? = null
    private var sizeView: TextView? = null
    private var currentUrl: String = ""
    private var currentName: String = ""
    private var style: String = STYLE_CENTER

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
                currentName = intent.getStringExtra(EXTRA_NAME) ?: guessName(currentUrl)
                style = intent.getStringExtra(EXTRA_STYLE) ?: readStyle(this)
                if (currentUrl.isNotBlank()) showOverlay()
            }
        }
        return START_STICKY
    }

    private fun dp(v: Int): Int = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics
    ).toInt()

    private fun screenWidth(): Int = resources.displayMetrics.widthPixels
    private fun screenHeight(): Int = resources.displayMetrics.heightPixels

    private fun roundBg(color: Int, radiusDp: Int, strokeColor: Int?, strokeDp: Int = 0): GradientDrawable {
        val d = GradientDrawable()
        d.shape = GradientDrawable.RECTANGLE
        d.cornerRadius = dp(radiusDp).toFloat()
        d.setColor(color)
        if (strokeColor != null && strokeDp > 0) d.setStroke(dp(strokeDp), strokeColor)
        return d
    }

    /** 折叠态圆形动作按钮。 */
    private fun actionBtn(label: String, bg: Int, onTap: () -> Unit): TextView {
        return TextView(this).apply {
            text = label
            setTextColor(Color.WHITE)
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            background = roundBg(bg, 16, null)
            val lp = LinearLayout.LayoutParams(dp(44), dp(30))
            lp.marginStart = dp(6)
            layoutParams = lp
            isClickable = true
            setOnClickListener { onTap() }
        }
    }

    private fun showOverlay() {
        if (root != null) {
            nameView?.text = currentName
            return
        }
        if (!canDraw(this)) {
            notifyBlocked()
            stopSelf()
            return
        }
        val wm = windowManager ?: run { stopSelf(); return }

        // ---- 折叠态容器：只放 文件名 / 大小 / 取消 / 下载 ----
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = roundBg(
                if (style == STYLE_BOTTOM) 0xF21C1D22.toInt() else 0xF71C1D22.toInt(),
                if (style == STYLE_BOTTOM) 20 else 22,
                0x33FFFFFF, 1,
            )
            setPadding(dp(14), dp(12), dp(10), dp(14))
        }

        // 第一行：文件名 + 取消 + 下载
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        val label = TextView(this).apply {
            text = currentName
            setTextColor(Color.WHITE)
            textSize = 13.5f
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
            typeface = Typeface.DEFAULT_BOLD
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        nameView = label

        val cancel = actionBtn("取消", 0x3DFFFFFF) {
            removeOverlay()
            stopSelf()
        }
        val confirm = actionBtn("下载", 0xFF0A84FF.toInt()) {
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
        container.addView(row)

        // 第二行：大小（折叠态唯一附加信息，用户明确要求保留）
        val size = TextView(this).apply {
            text = "正在获取大小…"
            setTextColor(0xB3FFFFFF.toInt())
            textSize = 11.5f
            setPadding(0, dp(6), 0, 0)
        }
        sizeView = size
        container.addView(size)

        // 异步补真实大小，失败则显示未知
        Thread {
            val bytes = probeSize(currentUrl)
            runOnUiThreadSafe {
                sizeView?.text = humanSize(bytes)
            }
        }.start()

        val lp = if (style == STYLE_BOTTOM) {
            // 底部：占屏幕高度 2/5，内容贴在顶部（折叠态），底部留白
            WindowManager.LayoutParams(
                screenWidth() - dp(28),
                (screenHeight() * 2) / 5,
                overlayType(),
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT,
            ).apply {
                gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
                x = 0
                y = dp(24)
            }
        } else {
            // 居中：做小，做成对话框（宽 300dp，高度按内容自适应）
            WindowManager.LayoutParams(
                dp(300),
                WindowManager.LayoutParams.WRAP_CONTENT,
                overlayType(),
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
                PixelFormat.TRANSLUCENT,
            ).apply {
                gravity = Gravity.CENTER
                x = 0
                y = 0
            }
        }

        try {
            wm.addView(container, lp)
            root = container
        } catch (_: Throwable) {
            // 某些 ROM 禁止后台直接添加悬浮窗：退化为通知，绝不再弹 Activity
            notifyBlocked()
            stopSelf()
        }
    }

    private fun overlayType(): Int =
        if (Build.VERSION.SDK_INT >= 26)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE

    private fun runOnUiThreadSafe(block: () -> Unit) {
        android.os.Handler(mainLooper).post { runCatching(block) }
    }

    /** 只发 HEAD 探 Content-Length，不下载内容。 */
    private fun probeSize(url: String): Long {
        return try {
            val conn = URL(url).openConnection() as HttpURLConnection
            conn.requestMethod = "HEAD"
            conn.connectTimeout = 4000
            conn.readTimeout = 4000
            conn.setRequestProperty("User-Agent", "Gopeed")
            val len = conn.contentLengthLong
            conn.disconnect()
            if (len > 0) len else -1L
        } catch (_: Throwable) {
            -1L
        }
    }

    private fun removeOverlay() {
        val v = root ?: return
        try {
            windowManager?.removeView(v)
        } catch (_: Throwable) {
        }
        root = null
        nameView = null
        sizeView = null
    }

    /** 投递任务到本机内核。 */
    private fun postTask(url: String): Boolean {
        val port = RootHelper.modulePort(this)
        if (port <= 0) return false
        return try {
            val conn = URL("http://127.0.0.1:$port/api/v1/tasks").openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.connectTimeout = 2500
            conn.readTimeout = 4000
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            val body = """{"req":{"url":"${url.replace("\"", "\\\"")}"},"opts":{"name":"$currentName"}}"""
            conn.outputStream.use { it.write(body.toByteArray()) }
            val code = conn.responseCode
            conn.disconnect()
            code in 200..299
        } catch (_: Throwable) {
            false
        }
    }

    private fun notifyBlocked() {
        notify("下载待确认", "$currentName\n未授予悬浮窗权限，已改为通知提醒")
    }

    private fun notifyResult(name: String, ok: Boolean) {
        notify(if (ok) "已开始下载" else "下载失败", name)
    }

    private fun notify(title: String, text: String) {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= 26) {
                val ch = NotificationChannel(
                    CHANNEL_ID, "下载浮窗", NotificationManager.IMPORTANCE_DEFAULT
                )
                nm.createNotificationChannel(ch)
            }
            val intent = packageManager.getLaunchIntentForPackage(packageName)
            val pi = if (intent != null && Build.VERSION.SDK_INT >= 23)
                PendingIntent.getActivity(
                    this, 0, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            else null
            val builder = if (Build.VERSION.SDK_INT >= 26)
                Notification.Builder(this, CHANNEL_ID)
            else
                @Suppress("DEPRECATION") Notification.Builder(this)
            builder.setContentTitle(title)
                .setContentText(text)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setAutoCancel(true)
            if (pi != null) builder.setContentIntent(pi)
            nm.notify(NOTIFY_ID, builder.build())
        } catch (_: Throwable) {
        }
    }
}
