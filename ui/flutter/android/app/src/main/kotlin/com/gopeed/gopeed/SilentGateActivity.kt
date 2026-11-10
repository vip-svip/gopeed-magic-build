package com.gopeed.gopeed

import android.app.Activity
import android.app.DownloadManager
import android.content.Intent
import android.os.Bundle
import java.net.HttpURLConnection
import java.net.URL

/**
 * 外链中转页：真正「无界面」的入口。
 *
 * 以前的做法是先把 MainActivity 拉起来，再从 Flutter 里 moveTaskToBack 退回后台。
 * 界面已经画出第一帧才退出，所以必然「闪一下」，还会留下一个后台 Activity。
 *
 * 现在改成独立入口 + Theme.NoDisplay：onCreate 里不 setContentView，
 * 系统不绘制任何窗口，肉眼看不到任何界面。
 *
 * 模式（由设置页同步到原生偏好）：
 * - off      关闭：直接转交主界面，由 Flutter 弹创建页（默认行为，不静默）
 * - headless 无界面：直接投递任务给本机内核，然后 finish。零界面、零弹窗，只发一条通知。
 * - ask      询问：显示系统级悬浮窗（文件名 + 取消 + 下载）让用户确认，确认后才投递。
 * - jump     跳转：转交主界面，进入任务列表。
 *
 * 关键兜底（修复"下载不了东西"）：
 * 内核端口不可达时**绝不静默丢弃**，一律转交 MainActivity 交给 Flutter 正常建任务，
 * 这样即使没装 root 模块、或端口被关掉，外链下载也一定能走通。
 */
class SilentGateActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val mode = RootHelper.prefs(this).getString(KEY_MODE, MODE_OFF) ?: MODE_OFF
        val url = extractUrl(intent)

        // 非下载类 intent（例如别的 App 里点了"分享"但没带可识别链接）：交给 App 处理
        if (url.isBlank()) {
            forward(url)
            return
        }

        // 关闭静默：用户明确要求"不要静默"，直接进 App 弹创建页，不显示任何悬浮窗
        if (mode == MODE_OFF || mode == MODE_JUMP) {
            forward(url)
            return
        }

        val name = DownloadOverlayService.guessName(url)
        val kernelUp = ensureKernelUp()

        if (mode == MODE_ASK) {
            // 询问：只弹系统级悬浮窗（居中/底部折叠卡片），不打开 App。
            if (DownloadOverlayService.canDraw(this)) {
                DownloadOverlayService.show(this, url, name)
                finish()
                overridePendingTransition(0, 0)
            } else if (kernelUp) {
                DownloadOverlayService.show(this, url, name)
                finish()
                overridePendingTransition(0, 0)
            } else {
                forward(url)
            }
            return
        }

        // headless（无界面）：只下载，绝不打开任何界面。
        // 以前 postTask 失败就 forward 拉主界面 —— 这正是「无界面还是会跳进 App」。
        if (kernelUp && postTask(url)) {
            OverlayBridge.notify(this, "已开始下载", name)
            finish()
            overridePendingTransition(0, 0)
            return
        }
        // 内核不可用：交给系统下载器，仍然零界面，只发系统通知。
        if (enqueueSystemDownload(url, name)) {
            OverlayBridge.notify(this, "已加入系统下载", name)
            finish()
            overridePendingTransition(0, 0)
            return
        }
        // 磁力 / ed2k 只能由内核处理：明确告知，不偷偷把用户拽进 App。
        OverlayBridge.notify(this, "无法无界面下载", "请检查模块是否就绪\n$name")
        finish()
        overridePendingTransition(0, 0)
    }

    /** 确保本机内核在监听；必要时用 root 拉起模块一次。 */
    private fun ensureKernelUp(): Boolean {
        val port = RootHelper.modulePort(this)
        if (RootHelper.kernelReachable(port)) return true
        // 端口没开：尝试用 root 拉一次（没 root 会直接失败，随后走 forward 兜底）
        if (RootHelper.ctlPath() != null) {
            runCatching {
                RootHelper.ctl("start")
                val deadline = System.currentTimeMillis() + 2500
                while (System.currentTimeMillis() < deadline) {
                    if (RootHelper.kernelReachable(RootHelper.modulePort(this))) return true
                    Thread.sleep(200)
                }
            }
        }
        return RootHelper.kernelReachable(RootHelper.modulePort(this))
    }

    private fun forward(url: String) {
        try {
            val next = Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW
                if (url.isNotBlank()) data = android.net.Uri.parse(url) else {
                    action = intent?.action
                    data = intent?.data
                    type = intent?.type
                    if (intent != null) putExtras(intent)
                }
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            startActivity(next)
        } catch (_: Throwable) {
        }
        finish()
        overridePendingTransition(0, 0)
    }

    /** 从 intent 里取出下载地址，兼容 VIEW 与 SEND/TEXT。 */
    private fun extractUrl(src: Intent?): String {
        if (src == null) return ""
        src.data?.let { d ->
            val s = d.toString()
            if (s.startsWith("http://", true) || s.startsWith("https://", true) ||
                s.startsWith("magnet:", true) || s.startsWith("ed2k://", true) ||
                s.startsWith("ftp://", true) || s.startsWith("ftps://", true) ||
                s.startsWith("thunder://", true)
            ) return s
        }
        val text = src.getStringExtra(Intent.EXTRA_TEXT)
            ?: src.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        if (!text.isNullOrBlank()) {
            val first = text.trim().split(Regex("\\s+")).firstOrNull() ?: ""
            if (first.startsWith("http", true) || first.startsWith("magnet:", true) ||
                first.startsWith("ed2k://", true) || first.startsWith("ftp", true) ||
                first.startsWith("thunder://", true)
            ) return first
        }
        return ""
    }

    /**
     * 系统下载器兜底：http/https/ftp 直接交给 DownloadManager。
     * 零界面、零 App 进程，下载完成由系统通知提醒。
     */
    private fun enqueueSystemDownload(url: String, name: String): Boolean {
        val lower = url.lowercase()
        val okScheme = lower.startsWith("http://") || lower.startsWith("https://") ||
            lower.startsWith("ftp://") || lower.startsWith("ftps://")
        if (!okScheme) return false
        return try {
            val dm = getSystemService(DownloadManager::class.java) ?: return false
            val safe = name.ifBlank { "download" }
            val req = DownloadManager.Request(android.net.Uri.parse(url)).apply {
                setTitle(safe)
                setDescription("Gopeed 静默下载")
                setNotificationVisibility(
                    DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED
                )
                setAllowedOverMetered(true)
                setAllowedOverRoaming(true)
                try {
                    setDestinationInExternalPublicDir(
                        android.os.Environment.DIRECTORY_DOWNLOADS, safe
                    )
                } catch (_: Throwable) {
                }
            }
            dm.enqueue(req)
            true
        } catch (_: Throwable) {
            false
        }
    }

    private fun postTask(url: String): Boolean {
        val port = RootHelper.modulePort(this)
        if (port <= 0) return false
        var conn: HttpURLConnection? = null
        return try {
            val escaped = url.replace("\\", "\\\\").replace("\"", "\\\"")
            val body = "{\"req\":{\"url\":\"$escaped\"}}"
            conn = (URL("http://127.0.0.1:$port/api/v1/tasks").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 4000
                readTimeout = 6000
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
            }
            conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            conn.responseCode in 200..299
        } catch (_: Throwable) {
            false
        } finally {
            try { conn?.disconnect() } catch (_: Throwable) {}
        }
    }

    companion object {
        const val KEY_MODE = "silent_mode"
        /** 关闭：不静默，进 App 弹创建页 */
        const val MODE_OFF = "off"
        /** 无界面：只下载，不显示任何界面 */
        const val MODE_HEADLESS = "headless"
        /** 询问：弹系统级悬浮窗确认 */
        const val MODE_ASK = "ask"
        /** 跳转：进入 App 任务列表 */
        const val MODE_JUMP = "jump"
    }
}
