package com.gopeed.gopeed

import android.content.Context
import java.io.BufferedReader
import java.io.DataOutputStream
import java.io.File
import java.io.InputStreamReader
import java.net.InetSocketAddress
import java.net.Socket

/**
 * 无界面场景下的原生辅助：读模块端口、执行 gopeedctl。
 *
 * 这里刻意不依赖 Flutter engine——静默下载时进程里根本没有界面，
 * 必须能只靠原生代码把模块拉起来并投递任务。
 */
object RootHelper {

    private const val PREFS = "gopeed_native"
    private const val KEY_PORT = "module_port"

    val ctlCandidates = listOf(
        "/data/adb/modules/gopeed_ksu/bin/gopeedctl",
        "/data/adb/modules_update/gopeed_ksu/bin/gopeedctl",
    )

    fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /**
     * 模块是否真的装上（决定"高级设置 → 模块"该显示已安装还是未安装）。
     *
     * 与 [modulePort] 不同：这里只看文件是否存在，不猜测端口，
     * 避免把"没装模块"误报成"模块检测失败"。
     */
    fun moduleInstalled(): Boolean {
        for (p in ctlCandidates) {
            try {
                if (File(p).exists()) return true
            } catch (_: Throwable) {
            }
        }
        return try {
            File("/data/adb/modules/gopeed_ksu").exists()
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * 模块端口：优先取设置里同步过来的值，否则读取模块配置。
     *
     * 注意：这里**不再**返回 9999 之类的猜测值。
     * 之前的实现会在没装模块时返回 9999，导致外链下载把任务投递到一个
     * 根本没人监听的端口，必定失败，用户看到的就是"下载不了东西"。
     * 现在没把握就返回 0，让上层走"转交 App 建任务"的兜底路径。
     */
    fun modulePort(ctx: Context): Int {
        val saved = prefs(ctx).getInt(KEY_PORT, 0)
        if (saved > 0) return saved
        for (c in listOf(
            "/data/adb/modules/gopeed_ksu/config/port",
            "/data/adb/modules/gopeed_ksu/state/config.json",
        )) {
            try {
                val f = File(c)
                if (!f.exists()) continue
                val txt = f.readText()
                val m = Regex("\"port\"\\s*:\\s*(\\d+)").find(txt)
                if (m != null) return m.groupValues[1].toInt()
                val only = txt.trim().toIntOrNull()
                if (only != null && only > 0) return only
            } catch (_: Throwable) {
            }
        }
        return 0
    }

    /** 探测本机内核端口是否真的在监听（短超时，不阻塞 UI）。 */
    fun kernelReachable(port: Int): Boolean {
        if (port <= 0) return false
        return try {
            Socket().use { s ->
                s.connect(InetSocketAddress("127.0.0.1", port), 350)
                true
            }
        } catch (_: Throwable) {
            false
        }
    }

    fun ctlPath(): String? {
        for (p in ctlCandidates) {
            try {
                if (File(p).exists()) return p
            } catch (_: Throwable) {
            }
        }
        return null
    }

    /** 在 root shell 里执行 gopeedctl <arg>，返回输出。 */
    fun ctl(arg: String): String {
        val p = ctlPath() ?: return ""
        return exec("sh $p $arg 2>&1")
    }

    fun exec(cmd: String): String {
        var proc: Process? = null
        var os: DataOutputStream? = null
        return try {
            proc = Runtime.getRuntime().exec("su")
            os = DataOutputStream(proc.outputStream)
            os.writeBytes(cmd + "\n")
            os.writeBytes("exit\n")
            os.flush()
            val out = BufferedReader(InputStreamReader(proc.inputStream)).use { it.readText() }
            proc.waitFor()
            out
        } catch (t: Throwable) {
            ""
        } finally {
            try { os?.close() } catch (_: Throwable) {}
            try { proc?.destroy() } catch (_: Throwable) {}
        }
    }
}
