#!/system/bin/sh
# service.sh - late_start service：开机自启下载服务 + 崩溃守护
#
# 关键点：开机阶段 /storage/emulated/0 往往还没挂载好，
# 直接启动会因 HOME 不可写而失败，表现为「开机不自动启动端口」。
# 因此先等 boot_completed + 等外部存储可写，再启动。
MODDIR=${0%/*}
. "$MODDIR/bin/common.sh"

wait_boot_complete
wait_storage
prepare_env
ensure_symlinks 2>/dev/null

# 兜底：应用未注册时尝试安装（多数机型 customize 阶段已完成）
if ! pm list packages 2>/dev/null | grep -qx "package:com.gopeed.gopeed"; then
  if [ -f "$MODDIR/system/priv-app/Gopeed/Gopeed.apk" ] || \
     [ -f "$MODDIR/system/app/Gopeed/Gopeed.apk" ] || \
     [ -f "$MODDIR/app/Gopeed.apk" ]; then
    log "应用未注册，尝试兜底安装"
    sh "$MODDIR/bin/gopeedctl" install-apk --quiet-on-skip &
  fi
fi

# 尊重用户的端口开关：关闭状态开机不拉起
if port_enabled; then
  start_gopeed
  start_watchdog
  log "service 阶段完成（端口已启用）"
else
  log "service 阶段跳过启动（用户已关闭端口）"
fi
