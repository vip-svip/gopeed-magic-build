package com.gopeed.gopeed

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 开机自启。
 *
 * 「开机自动运行」开关之前只写了一个偏好值，没有任何地方读它，
 * 所以开机后端口依然不会起来——这就是用户说的"自动运行不生效"。
 * 这里在系统开机完成后读开关，开启时用 root 把模块内核与端口拉起来。
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }
        val enabled = try {
            RootHelper.prefs(context).getBoolean("auto_start", false)
        } catch (_: Throwable) {
            false
        }
        if (!enabled) return
        if (RootHelper.ctlPath() == null) return
        Thread {
            runCatching {
                RootHelper.ctl("enable")
                RootHelper.ctl("start")
            }
        }.start()
    }
}
