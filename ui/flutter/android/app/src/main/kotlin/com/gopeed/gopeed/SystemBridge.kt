package com.gopeed.gopeed

import android.app.Activity
import android.app.ActivityManager
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.DataOutputStream
import java.io.File
import java.io.InputStreamReader

/**
 * 系统能力桥。
 *
 * 设计原则：每个方法都返回真实执行结果，失败时明确回传错误，不做“假成功”。
 * - isSystemApp     读取 ApplicationInfo 标志与 sourceDir，判断是否真的装在 /system
 * - hideFromRecents 通过 ActivityManager.AppTask.setExcludeFromRecents 真正从最近任务移除
 * - moveTaskToBack  退到后台而不结束进程（退出时最小化）
 * - hasRoot         实际执行 su -c id 探测，而不是只看文件是否存在
 * - rootExec        在 root shell 内执行命令并回传 stdout/stderr/exitCode
 * - appInfo         回传包名、版本、安装路径、签名来源等诊断信息
 */
class SystemBridge(private val activity: Activity) {

    companion object {
        const val CHANNEL = "gopeed.com/system"
    }

    fun handle(call: String, args: Map<String, Any?>?, result: MethodChannel.Result) {
        try {
            when (call) {
                "isSystemApp" -> result.success(isSystemApp())
                "hideFromRecents" -> {
                    val hide = args?.get("hide") as? Boolean ?: true
                    result.success(hideFromRecents(hide))
                }
                "moveTaskToBack" -> result.success(moveTaskToBack())
                "hasRoot" -> result.success(hasRoot())
                "rootExec" -> {
                    val cmd = args?.get("cmd") as? String
                    if (cmd.isNullOrBlank()) {
                        result.error("BAD_ARGS", "cmd 不能为空", null)
                        return
                    }
                    result.success(rootExec(cmd))
                }
                "appInfo" -> result.success(appInfo())
                "requestIgnoreBattery" -> result.success(requestIgnoreBattery())

                // ---- 系统级悬浮窗 ----
                "hasOverlayPermission" -> result.success(DownloadOverlayService.canDraw(activity))
                "requestOverlayPermission" -> result.success(requestOverlayPermission())
                "showOverlay" -> {
                    val url = args?.get("url") as? String ?: ""
                    val name = (args?.get("name") as? String)
                        ?: DownloadOverlayService.guessName(url)
                    if (DownloadOverlayService.canDraw(activity)) {
                        DownloadOverlayService.show(activity, url, name)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "hideOverlay" -> {
                    DownloadOverlayService.hide(activity)
                    result.success(true)
                }

                // ---- 静默模式（供 Dart 侧同步给原生入口） ----
                "setSilentMode" -> {
                    val mode = args?.get("mode") as? String ?: "off"
                    RootHelper.prefs(activity).edit()
                        .putString(SilentGateActivity.KEY_MODE, mode)
                        .apply()
                    result.success(true)
                }
                "setOverlayEnabled" -> {
                    val on = args?.get("enabled") as? Boolean ?: true
                    OverlayBridge.setOverlayEnabled(activity, on)
                    result.success(true)
                }
                "setMinimizeOnExit" -> {
                    val on = args?.get("enabled") as? Boolean ?: false
                    RootHelper.prefs(activity).edit()
                        .putBoolean("minimize_on_exit", on).apply()
                    result.success(true)
                }
                "setAutoStart" -> {
                    val on = args?.get("enabled") as? Boolean ?: false
                    RootHelper.prefs(activity).edit()
                        .putBoolean("auto_start", on).apply()
                    // 有 root 时顺带让模块开机自启端口跟随该开关
                    if (RootHelper.ctlPath() != null) {
                        Thread {
                            runCatching {
                                RootHelper.ctl(if (on) "enable" else "disable")
                            }
                        }.start()
                    }
                    result.success(true)
                }
                "readSystemPrefs" -> {
                    val p = RootHelper.prefs(activity)
                    result.success(
                        mapOf(
                            "minimizeOnExit" to p.getBoolean("minimize_on_exit", false),
                            "hideFromRecents" to p.getBoolean("hide_from_recents", false),
                            "autoStart" to p.getBoolean("auto_start", false),
                            "overlayEnabled" to p.getBoolean("overlay_enabled", true),
                        )
                    )
                }
                "setDialogPresentation" -> {
                    val style = (args?.get("style") as? String)?.ifBlank { "center" } ?: "center"
                    RootHelper.prefs(activity).edit()
                        .putString("dialog_presentation", style)
                        .apply()
                    result.success(true)
                }
                "setModulePort" -> {
                    val port = (args?.get("port") as? Number)?.toInt() ?: 0
                    if (port > 0) {
                        RootHelper.prefs(activity).edit()
                            .putInt("module_port", port)
                            .apply()
                    }
                    result.success(port)
                }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            result.error("SYSTEM_BRIDGE", t.message ?: t.toString(), null)
        }
    }

    /** 是否真的作为系统应用安装（/system、/product、/system_ext 或带系统标志）。 */
    private fun isSystemApp(): Boolean {
        return try {
            val ai = activity.packageManager.getApplicationInfo(activity.packageName, 0)
            val systemFlag = (ai.flags and ApplicationInfo.FLAG_SYSTEM) != 0
            val updatedFlag = (ai.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
            val src = ai.sourceDir ?: ""
            systemFlag || updatedFlag ||
                src.startsWith("/system/") ||
                src.startsWith("/product/") ||
                src.startsWith("/system_ext/") ||
                src.startsWith("/vendor/")
        } catch (t: Throwable) {
            false
        }
    }

    /**
     * 从最近任务列表隐藏 / 恢复。
     * iOS 的“从后台卡片里消失”在 Android 对应 excludeFromRecents，需要作用于 AppTask。
     */
    private fun hideFromRecents(hide: Boolean): Boolean {
        // 必须同时落盘：readSystemPrefs 读的是 hide_from_recents，
        // 以前这里只调 AppTask.setExcludeFromRecents 不写偏好，
        // 于是设置页每次重进都读回 false → 显示「关闭」（用户反馈的真实根因）。
        runCatching {
            RootHelper.prefs(activity).edit()
                .putBoolean("hide_from_recents", hide)
                .apply()
        }
        return try {
            val am = activity.getSystemService(Activity.ACTIVITY_SERVICE) as ActivityManager
            val tasks = am.appTasks
            if (tasks.isNullOrEmpty()) {
                // 任务尚未建立（首次启动极早期）：偏好已落盘，
                // 清单里也写了 excludeFromRecents，这里视为成功。
                return true
            }
            for (task in tasks) {
                task.setExcludeFromRecents(hide)
            }
            true
        } catch (t: Throwable) {
            false
        }
    }

    /** 退到后台，进程与下载继续运行。 */
    private fun moveTaskToBack(): Boolean {
        return try {
            activity.moveTaskToBack(true)
        } catch (t: Throwable) {
            false
        }
    }

    /** 真探测 root：执行 su -c id 并检查是否返回 uid=0。 */
    private fun hasRoot(): Boolean {
        val r = rootExec("id")
        val out = (r["stdout"] as? String ?: "") + (r["stderr"] as? String ?: "")
        val ok = (r["exitCode"] as? Int ?: -1) == 0 && out.contains("uid=0")
        return ok
    }

    /** 在 root shell 内执行命令，返回 stdout / stderr / exitCode。 */
    private fun rootExec(cmd: String): Map<String, Any?> {
        var process: Process? = null
        var os: DataOutputStream? = null
        return try {
            process = Runtime.getRuntime().exec("su")
            os = DataOutputStream(process.outputStream)
            os.writeBytes(cmd + "\n")
            os.writeBytes("exit\n")
            os.flush()

            val stdout = BufferedReader(InputStreamReader(process.inputStream)).use { it.readText() }
            val stderr = BufferedReader(InputStreamReader(process.errorStream)).use { it.readText() }
            val code = process.waitFor()
            mapOf<String, Any?>("exitCode" to code, "stdout" to stdout, "stderr" to stderr)
        } catch (t: Throwable) {
            mapOf<String, Any?>(
                "exitCode" to -1,
                "stdout" to "",
                "stderr" to (t.message ?: "su 不可用")
            )
        } finally {
            try { os?.close() } catch (_: Throwable) {}
            try { process?.destroy() } catch (_: Throwable) {}
        }
    }

    /** 诊断信息，设置页“关于”里展示真实状态。 */
    private fun appInfo(): Map<String, Any?> {
        val pm = activity.packageManager
        val pkg = activity.packageName
        return try {
            val ai = pm.getApplicationInfo(pkg, 0)
            val pi = pm.getPackageInfo(pkg, 0)
            mapOf(
                "packageName" to pkg,
                "versionName" to (pi.versionName ?: ""),
                "versionCode" to (if (Build.VERSION.SDK_INT >= 28) pi.longVersionCode else pi.versionCode.toLong()),
                "sourceDir" to (ai.sourceDir ?: ""),
                "dataDir" to (ai.dataDir ?: ""),
                "isSystemApp" to isSystemApp(),
                "isRooted" to hasRoot(),
                "sdkInt" to Build.VERSION.SDK_INT
            )
        } catch (t: Throwable) {
            mapOf<String, Any?>("packageName" to pkg, "isSystemApp" to isSystemApp())
        }
    }

    /**
     * 申请「显示在其他应用上层」权限。
     * 打开系统对应的授权页；真正的结果由上层的 hasOverlayPermission 回读，
     * 这里不假装成功。
     */
    private fun requestOverlayPermission(): Boolean {
        if (DownloadOverlayService.canDraw(activity)) return true
        return try {
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:" + activity.packageName),
            )
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activity.startActivity(intent)
            true
        } catch (t: Throwable) {
            // 部分 ROM 没有该设置页，退回应用详情页
            try {
                val fallback = Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:" + activity.packageName),
                )
                fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                activity.startActivity(fallback)
                true
            } catch (_: Throwable) {
                false
            }
        }
    }

    /** 请求忽略电池优化，避免后台被系统杀掉中断下载。 */
    private fun requestIgnoreBattery(): Boolean {
        return try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            intent.data = Uri.parse("package:" + activity.packageName)
            activity.startActivity(intent)
            true
        } catch (t: Throwable) {
            false
        }
    }
}
